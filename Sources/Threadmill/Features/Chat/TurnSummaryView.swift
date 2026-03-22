import SwiftUI

struct TurnSummaryView: View {
    let summary: TurnSummary

    var body: some View {
        HStack(spacing: 8) {
            divider
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.green)
            Text("\(summary.toolCount) tool calls · \(summary.durationSeconds)s")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(summary.modifiedFiles.prefix(3), id: \.self) { file in
                Text(URL(fileURLWithPath: file).lastPathComponent)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            if summary.modifiedFiles.count > 3 {
                Text("+\(summary.modifiedFiles.count - 3)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            divider
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.22))
            .frame(height: 1)
    }
}
