import SwiftUI

struct ChatSessionView: View {
    @State var viewModel: ChatSessionViewModel

    var body: some View {
        VStack(spacing: 0) {
            ChatMessageList(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ChatInputBar(viewModel: viewModel)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
