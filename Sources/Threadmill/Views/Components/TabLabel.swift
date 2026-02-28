import SwiftUI

struct TabLabel: View {
    let title: String
    let icon: String?

    var body: some View {
        HStack(spacing: 6) {
            if let icon, !icon.isEmpty {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
