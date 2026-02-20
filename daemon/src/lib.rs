use std::{
    collections::HashMap,
    io::{Read, Write},
    net::SocketAddr,
    sync::{
        atomic::{AtomicU16, Ordering},
        Arc,
    },
};

use futures_util::{SinkExt, StreamExt};
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::{
    net::{TcpListener, TcpStream},
    process::Command,
    sync::{broadcast, mpsc, oneshot, Mutex, Semaphore},
    task::JoinHandle,
};
use tokio_tungstenite::{accept_async, tungstenite::Message};
use tracing::{debug, error, info, warn};
use uuid::Uuid;

pub const DEFAULT_ADDR: &str = "127.0.0.1:19990";
const MAX_IN_FLIGHT_REQUESTS: usize = 32;
const DEFAULT_COLS: u16 = 120;
const DEFAULT_ROWS: u16 = 40;

#[derive(Clone)]
pub struct AppState {
    events_tx: broadcast::Sender<ServerEvent>,
    next_channel_id: Arc<AtomicU16>,
}

#[derive(Clone, Debug)]
struct ServerEvent {
    method: String,
    params: Value,
}

impl AppState {
    pub fn new() -> Self {
        let (events_tx, _) = broadcast::channel(256);
        Self {
            events_tx,
            next_channel_id: Arc::new(AtomicU16::new(1)),
        }
    }

    fn alloc_channel_id(&self) -> u16 {
        self.next_channel_id.fetch_add(1, Ordering::Relaxed)
    }

    fn emit_event(&self, method: impl Into<String>, params: Value) {
        let _ = self.events_tx.send(ServerEvent {
            method: method.into(),
            params,
        });
    }
}

impl Default for AppState {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug)]
pub enum DaemonError {
    Io(std::io::Error),
}

impl std::fmt::Display for DaemonError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(err) => write!(f, "io error: {err}"),
        }
    }
}

impl std::error::Error for DaemonError {}

impl From<std::io::Error> for DaemonError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

pub async fn serve(addr: &str, shutdown_rx: oneshot::Receiver<()>) -> Result<(), DaemonError> {
    let listener = TcpListener::bind(addr).await?;
    serve_listener(listener, shutdown_rx).await;
    Ok(())
}

pub async fn serve_listener(listener: TcpListener, mut shutdown_rx: oneshot::Receiver<()>) {
    let state = Arc::new(AppState::new());
    let local_addr = match listener.local_addr() {
        Ok(addr) => addr,
        Err(err) => {
            error!(error = %err, "failed to get listener address");
            return;
        }
    };

    info!(%local_addr, "threadmill daemon listening");

    loop {
        tokio::select! {
            _ = &mut shutdown_rx => {
                info!("shutdown signal received");
                break;
            }
            accept_res = listener.accept() => {
                match accept_res {
                    Ok((stream, peer_addr)) => {
                        let state = Arc::clone(&state);
                        tokio::spawn(async move {
                            if let Err(err) = handle_connection(stream, peer_addr, state).await {
                                warn!(%peer_addr, error = %err, "connection failed");
                            }
                        });
                    }
                    Err(err) => warn!(error = %err, "accept failed"),
                }
            }
        }
    }
}

pub fn init_tracing() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_target(false)
        .try_init();
}

#[derive(Debug)]
enum ConnectionError {
    WebSocket(tokio_tungstenite::tungstenite::Error),
}

impl std::fmt::Display for ConnectionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::WebSocket(err) => write!(f, "websocket error: {err}"),
        }
    }
}

impl std::error::Error for ConnectionError {}

impl From<tokio_tungstenite::tungstenite::Error> for ConnectionError {
    fn from(value: tokio_tungstenite::tungstenite::Error) -> Self {
        Self::WebSocket(value)
    }
}

#[derive(Default)]
struct ConnectionState {
    by_channel: HashMap<u16, Attachment>,
    by_target: HashMap<String, u16>,
}

struct Attachment {
    target: String,
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn Child + Send + Sync>,
    input_tx: Option<mpsc::UnboundedSender<Vec<u8>>>,
    input_task: JoinHandle<()>,
    output_task: JoinHandle<()>,
}

#[derive(Deserialize)]
struct JsonRpcRequest {
    jsonrpc: String,
    #[serde(default)]
    id: Option<Value>,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Deserialize)]
struct TerminalTargetParams {
    session: String,
    window: u32,
    pane: u32,
}

#[derive(Deserialize)]
struct TerminalResizeParams {
    session: String,
    window: u32,
    pane: u32,
    cols: u16,
    rows: u16,
}

async fn handle_connection(
    stream: TcpStream,
    peer_addr: SocketAddr,
    state: Arc<AppState>,
) -> Result<(), ConnectionError> {
    let ws_stream = accept_async(stream).await?;
    let connection_id = Uuid::new_v4();
    let (mut ws_writer, mut ws_reader) = ws_stream.split();
    let (outbound_tx, mut outbound_rx) = mpsc::unbounded_channel::<Message>();
    let connection_state = Arc::new(Mutex::new(ConnectionState::default()));
    let semaphore = Arc::new(Semaphore::new(MAX_IN_FLIGHT_REQUESTS));

    let writer_task = tokio::spawn(async move {
        while let Some(msg) = outbound_rx.recv().await {
            if ws_writer.send(msg).await.is_err() {
                break;
            }
        }
    });

    let events_task = {
        let outbound_tx = outbound_tx.clone();
        let mut events_rx = state.events_tx.subscribe();
        tokio::spawn(async move {
            loop {
                match events_rx.recv().await {
                    Ok(event) => {
                        let message = Message::Text(
                            json!({
                                "jsonrpc": "2.0",
                                "method": event.method,
                                "params": event.params,
                            })
                            .to_string(),
                        );
                        if outbound_tx.send(message).is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        warn!(skipped, "event subscriber lagged");
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        })
    };

    info!(%connection_id, %peer_addr, "client connected");

    while let Some(frame_res) = ws_reader.next().await {
        match frame_res {
            Ok(Message::Text(text)) => {
                let permit = match Arc::clone(&semaphore).acquire_owned().await {
                    Ok(permit) => permit,
                    Err(_) => break,
                };

                let outbound_tx = outbound_tx.clone();
                let connection_state = Arc::clone(&connection_state);
                let state = Arc::clone(&state);
                tokio::spawn(async move {
                    let _permit = permit;
                    if let Some(response) =
                        handle_text_message(text.to_string(), state, connection_state, outbound_tx.clone()).await
                    {
                        let _ = outbound_tx.send(response);
                    }
                });
            }
            Ok(Message::Binary(data)) => {
                if let Err(err) = handle_binary_message(data.to_vec(), Arc::clone(&connection_state)).await {
                    warn!(%connection_id, error = %err, "failed to route binary frame");
                }
            }
            Ok(Message::Ping(payload)) => {
                let _ = outbound_tx.send(Message::Pong(payload));
            }
            Ok(Message::Pong(_)) => {}
            Ok(Message::Close(_)) => break,
            Ok(Message::Frame(_)) => {}
            Err(err) => {
                warn!(%connection_id, error = %err, "read loop failed");
                break;
            }
        }
    }

    cleanup_connection(Arc::clone(&connection_state)).await;
    events_task.abort();
    writer_task.abort();
    let _ = events_task.await;
    let _ = writer_task.await;
    info!(%connection_id, "client disconnected");
    Ok(())
}

async fn handle_text_message(
    text: String,
    state: Arc<AppState>,
    connection_state: Arc<Mutex<ConnectionState>>,
    outbound_tx: mpsc::UnboundedSender<Message>,
) -> Option<Message> {
    let request: JsonRpcRequest = match serde_json::from_str(&text) {
        Ok(request) => request,
        Err(err) => {
            return Some(error_response(None, -1, format!("invalid JSON: {err}")));
        }
    };

    if request.jsonrpc != "2.0" {
        return Some(error_response(request.id, -1, "jsonrpc must be '2.0'"));
    }

    let id = request.id.clone();
    let result = dispatch_request(request, state, connection_state, outbound_tx).await;
    match (id, result) {
        (Some(id), Ok(result)) => Some(success_response(id, result)),
        (Some(id), Err(message)) => Some(error_response(Some(id), -1, message)),
        (None, Ok(_)) => None,
        (None, Err(message)) => {
            warn!(error = %message, "notification failed");
            None
        }
    }
}

async fn dispatch_request(
    request: JsonRpcRequest,
    state: Arc<AppState>,
    connection_state: Arc<Mutex<ConnectionState>>,
    outbound_tx: mpsc::UnboundedSender<Message>,
) -> Result<Value, String> {
    match request.method.as_str() {
        "ping" => Ok(json!("pong")),
        "project.list" => Ok(json!([])),
        "thread.list" => Ok(json!([])),
        "terminal.attach" => {
            let params: TerminalTargetParams = serde_json::from_value(request.params)
                .map_err(|err| format!("invalid terminal.attach params: {err}"))?;
            terminal_attach(params, state, connection_state, outbound_tx).await
        }
        "terminal.detach" => {
            let params: TerminalTargetParams = serde_json::from_value(request.params)
                .map_err(|err| format!("invalid terminal.detach params: {err}"))?;
            terminal_detach(params, state, connection_state).await
        }
        "terminal.resize" => {
            let params: TerminalResizeParams = serde_json::from_value(request.params)
                .map_err(|err| format!("invalid terminal.resize params: {err}"))?;
            terminal_resize(params, connection_state).await
        }
        _ => Err(format!("unknown method '{}'", request.method)),
    }
}

async fn handle_binary_message(
    data: Vec<u8>,
    connection_state: Arc<Mutex<ConnectionState>>,
) -> Result<(), String> {
    if data.len() < 2 {
        return Err("binary frame too short".to_string());
    }

    let channel_id = u16::from_be_bytes([data[0], data[1]]);
    let payload = data[2..].to_vec();

    let guard = connection_state.lock().await;
    let Some(attachment) = guard.by_channel.get(&channel_id) else {
        return Err(format!("unknown channel {channel_id}"));
    };

    let Some(input_tx) = &attachment.input_tx else {
        return Err(format!("channel {channel_id} is closed"));
    };

    input_tx
        .send(payload)
        .map_err(|_| format!("channel {channel_id} is closed"))
}

async fn terminal_attach(
    params: TerminalTargetParams,
    state: Arc<AppState>,
    connection_state: Arc<Mutex<ConnectionState>>,
    outbound_tx: mpsc::UnboundedSender<Message>,
) -> Result<Value, String> {
    let target = tmux_target(&params.session, params.window, params.pane);
    {
        let guard = connection_state.lock().await;
        if let Some(channel_id) = guard.by_target.get(&target) {
            return Ok(json!({ "channel_id": channel_id }));
        }
    }

    let channel_id = state.alloc_channel_id();
    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            rows: DEFAULT_ROWS,
            cols: DEFAULT_COLS,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|err| format!("failed to open pty: {err}"))?;

    let mut command = CommandBuilder::new("tmux");
    command.env("TERM", "xterm-256color");
    command.args(["attach-session", "-t", &target]);
    let child = pair
        .slave
        .spawn_command(command)
        .map_err(|err| format!("failed to spawn tmux attach-session: {err}"))?;
    drop(pair.slave);

    let mut reader = pair
        .master
        .try_clone_reader()
        .map_err(|err| format!("failed to clone pty reader: {err}"))?;
    let mut writer = pair
        .master
        .take_writer()
        .map_err(|err| format!("failed to take pty writer: {err}"))?;

    let (input_tx, mut input_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let input_task = tokio::task::spawn_blocking(move || {
        while let Some(chunk) = input_rx.blocking_recv() {
            if writer.write_all(&chunk).is_err() {
                break;
            }
            if writer.flush().is_err() {
                break;
            }
        }
    });

    let output_tx = outbound_tx.clone();
    let output_task = tokio::task::spawn_blocking(move || {
        let mut buf = [0_u8; 8192];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(read_len) => {
                    let mut payload = Vec::with_capacity(read_len + 2);
                    payload.extend_from_slice(&channel_id.to_be_bytes());
                    payload.extend_from_slice(&buf[..read_len]);
                    if output_tx.send(Message::Binary(payload)).is_err() {
                        break;
                    }
                }
                Err(err) if err.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
    });

    let attachment = Attachment {
        target: target.clone(),
        master: pair.master,
        child,
        input_tx: Some(input_tx),
        input_task,
        output_task,
    };

    {
        let mut guard = connection_state.lock().await;
        guard.by_target.insert(target.clone(), channel_id);
        guard.by_channel.insert(channel_id, attachment);
    }

    state.emit_event(
        "thread.status_changed",
        json!({
            "target": target,
            "status": "terminal_attached",
            "channel_id": channel_id,
        }),
    );

    Ok(json!({ "channel_id": channel_id }))
}

async fn terminal_detach(
    params: TerminalTargetParams,
    state: Arc<AppState>,
    connection_state: Arc<Mutex<ConnectionState>>,
) -> Result<Value, String> {
    let target = tmux_target(&params.session, params.window, params.pane);
    let detached = detach_by_target(&target, connection_state).await?;

    if detached {
        state.emit_event(
            "thread.status_changed",
            json!({
                "target": target,
                "status": "terminal_detached",
            }),
        );
    }

    Ok(json!({ "detached": detached }))
}

async fn terminal_resize(
    params: TerminalResizeParams,
    connection_state: Arc<Mutex<ConnectionState>>,
) -> Result<Value, String> {
    let target = tmux_target(&params.session, params.window, params.pane);
    let channel_id = {
        let guard = connection_state.lock().await;
        *guard
            .by_target
            .get(&target)
            .ok_or_else(|| format!("target {target} is not attached"))?
    };

    {
        let guard = connection_state.lock().await;
        let attachment = guard
            .by_channel
            .get(&channel_id)
            .ok_or_else(|| format!("channel {channel_id} not found"))?;
        attachment
            .master
            .resize(PtySize {
                rows: params.rows,
                cols: params.cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|err| format!("failed to resize pty: {err}"))?;
    }

    let output = Command::new("tmux")
        .args([
            "resize-pane",
            "-t",
            &target,
            "-x",
            &params.cols.to_string(),
            "-y",
            &params.rows.to_string(),
        ])
        .output()
        .await
        .map_err(|err| format!("failed to run tmux resize-pane: {err}"))?;

    if !output.status.success() {
        return Err(format!(
            "tmux resize-pane failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(json!({ "resized": true }))
}

async fn detach_by_target(
    target: &str,
    connection_state: Arc<Mutex<ConnectionState>>,
) -> Result<bool, String> {
    let maybe_attachment = {
        let mut guard = connection_state.lock().await;
        let Some(channel_id) = guard.by_target.remove(target) else {
            return Ok(false);
        };
        guard.by_channel.remove(&channel_id)
    };

    if let Some(mut attachment) = maybe_attachment {
        cleanup_attachment(&mut attachment).await;
    }

    Ok(true)
}

async fn cleanup_connection(connection_state: Arc<Mutex<ConnectionState>>) {
    let attachments = {
        let mut guard = connection_state.lock().await;
        guard.by_target.clear();
        std::mem::take(&mut guard.by_channel)
    };

    for (_, mut attachment) in attachments {
        cleanup_attachment(&mut attachment).await;
    }
}

async fn cleanup_attachment(attachment: &mut Attachment) {
    debug!(target = %attachment.target, "cleaning attachment");
    if let Some(input_tx) = attachment.input_tx.take() {
        drop(input_tx);
    }
    let _ = attachment.child.kill();
    let _ = attachment.child.wait();
    attachment.input_task.abort();
    attachment.output_task.abort();
}

fn tmux_target(session: &str, window: u32, pane: u32) -> String {
    format!("{session}:{window}.{pane}")
}

fn success_response(id: Value, result: Value) -> Message {
    Message::Text(
        json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        })
        .to_string(),
    )
}

fn error_response(id: Option<Value>, code: i64, message: impl Into<String>) -> Message {
    Message::Text(
        json!({
            "jsonrpc": "2.0",
            "id": id.unwrap_or(Value::Null),
            "error": {
                "code": code,
                "message": message.into(),
            }
        })
        .to_string(),
    )
}
