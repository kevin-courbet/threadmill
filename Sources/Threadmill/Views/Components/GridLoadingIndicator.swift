import SwiftUI

struct GridLoadingIndicator: View {
    let status: AgentStatus?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsePhase = false

    private let gridSize: CGFloat = 16
    private let cellSize: CGFloat = 4
    private let cellSpacing: CGFloat = 2
    private let staggerStep: Double = 0.1

    private var mode: Mode {
        switch status {
        case .busy:
            return .busy
        case .stalled:
            return .stalled
        case .idle, .none:
            return .idle
        }
    }

    private var workerCount: Int {
        switch status {
        case .busy(let count), .stalled(let count):
            return max(count, 0)
        case .idle, .none:
            return 0
        }
    }

    private var isAnimated: Bool {
        mode != .idle && !reduceMotion
    }

    private var loopDuration: Double {
        mode == .stalled ? 3.0 : 1.2
    }

    private var activeColor: Color {
        mode == .stalled ? .yellow : .accentColor
    }

    var body: some View {
        HStack(spacing: 6) {
            grid
                .frame(width: gridSize, height: gridSize)

            if workerCount > 1 {
                workerCountBadge
            }
        }
        .onAppear(perform: restartAnimation)
        .onChange(of: mode) { _, _ in
            restartAnimation()
        }
        .onChange(of: reduceMotion) { _, _ in
            restartAnimation()
        }
    }

    private var grid: some View {
        VStack(spacing: cellSpacing) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: cellSpacing) {
                    ForEach(0..<3, id: \.self) { column in
                        let index = (row * 3) + column
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(activeColor)
                            .frame(width: cellSize, height: cellSize)
                            .opacity(cellOpacity(for: index))
                            .scaleEffect(cellScale(for: index))
                            .animation(cellAnimation(for: index), value: pulsePhase)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private var workerCountBadge: some View {
        Text("\(workerCount)")
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.18))
            )
            .accessibilityLabel("\(workerCount) workers")
    }

    private func cellOpacity(for index: Int) -> Double {
        guard mode != .idle else { return 0 }
        guard isAnimated else { return mode == .stalled ? 0.9 : 0.95 }
        return pulsePhase ? 1.0 : 0.3
    }

    private func cellScale(for index: Int) -> CGFloat {
        guard mode != .idle else { return 1 }
        guard isAnimated else { return 1 }
        return pulsePhase ? 1.0 : 0.7
    }

    private func cellAnimation(for index: Int) -> Animation? {
        guard isAnimated else { return nil }
        let halfLoop = loopDuration / 2
        return .easeInOut(duration: halfLoop)
            .repeatForever(autoreverses: true)
            .delay(Double(index) * staggerStep)
    }

    private func restartAnimation() {
        pulsePhase = false
        guard isAnimated else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: loopDuration / 2).repeatForever(autoreverses: true)) {
                pulsePhase = true
            }
        }
    }
}

private extension GridLoadingIndicator {
    enum Mode {
        case idle
        case busy
        case stalled
    }
}

#Preview("Grid Loading Indicator") {
    HStack(spacing: 18) {
        GridLoadingIndicator(status: nil)
        GridLoadingIndicator(status: .busy(workerCount: 1))
        GridLoadingIndicator(status: .busy(workerCount: 3))
        GridLoadingIndicator(status: .stalled(workerCount: 2))
    }
    .padding(20)
    .background(Color.black)
}
