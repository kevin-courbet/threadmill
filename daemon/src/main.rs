use tokio::sync::oneshot;
use tracing::info;

#[tokio::main]
async fn main() -> Result<(), threadmill_daemon::DaemonError> {
    threadmill_daemon::init_tracing();

    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            let _ = shutdown_tx.send(());
        }
    });

    info!(address = threadmill_daemon::DEFAULT_ADDR, "starting daemon");
    threadmill_daemon::serve(threadmill_daemon::DEFAULT_ADDR, shutdown_rx).await
}
