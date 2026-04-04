import SwiftUI

struct PermissionBannerView: View {
    let pendingPermissions: [PendingPermissionRequest]
    let currentSessionID: String?
    let onNavigate: (String) -> Void
    let onApprove: (PendingPermissionRequest, String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false

    private var crossSessionRequest: PendingPermissionRequest? {
        // Can't determine "cross-session" without knowing which session is current
        guard let currentSessionID else { return nil }
        return pendingPermissions
            .filter { $0.sessionID != currentSessionID }
            .sorted { $0.timestamp < $1.timestamp }
            .first
    }

    private var strokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
    }

    var body: some View {
        Group {
            if let request = crossSessionRequest {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        onNavigate(request.sessionID)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            pulseIndicator

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Pending permission in another session")
                                    .font(.system(size: ChatTokens.captionFontSize, weight: .semibold))
                                    .foregroundStyle(ChatTokens.textStrong)

                                Text(summaryText(for: request))
                                    .font(.system(size: ChatTokens.metaFontSize))
                                    .foregroundStyle(ChatTokens.textMuted)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                            }

                            Spacer(minLength: 0)

                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(ChatTokens.textSubtle)
                        }
                    }
                    .buttonStyle(.plain)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(request.options, id: \.id) { option in
                                PermissionOptionButton(
                                    option: option,
                                    kind: option.id,
                                    style: .inline
                                ) {
                                    onApprove(request, option.id)
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: 420, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: request.id)
                .onAppear {
                    pulse = true
                }
            }
        }
    }

    private var pulseIndicator: some View {
        ZStack {
            Circle()
                .fill(ChatTokens.statusWarning)
                .frame(width: 8, height: 8)

            Circle()
                .stroke(ChatTokens.statusWarning.opacity(0.55), lineWidth: 1)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 1.5 : 1.0)
                .opacity(pulse ? 0 : 1)
                .animation(
                    .easeOut(duration: ChatTokens.durNormal * 6)
                        .repeatForever(autoreverses: false),
                    value: pulse
                )
        }
    }

    private func summaryText(for request: PendingPermissionRequest) -> String {
        if !request.title.isEmpty {
            return request.title
        }
        if !request.message.isEmpty {
            return request.message
        }
        return "Choose an option"
    }
}
