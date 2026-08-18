import SwiftUI

/// Shows every process at once in an adaptive grid, so a wall of running agents
/// can be watched without clicking through them one at a time.
///
/// Each tile hosts the controller's own long-lived terminal view - the same one
/// the single-pane mode uses - so switching modes never loses scrollback.
struct GridView: View {
    let controllers: [ProcessController]
    @Binding var selectedID: String?
    /// Called when a tile is double-clicked, to drop back into single-pane focus.
    let onFocus: (String) -> Void

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 320, maximum: 720), spacing: 10)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(controllers) { controller in
                    GridTile(controller: controller,
                             isSelected: controller.id == selectedID,
                             onSelect: { selectedID = controller.id },
                             onFocus: { onFocus(controller.id) })
                }
            }
            .padding(10)
        }
    }
}

private struct GridTile: View {
    @ObservedObject var controller: ProcessController
    let isSelected: Bool
    let onSelect: () -> Void
    let onFocus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            TerminalPane(controller: controller)
                .frame(minHeight: 200)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                              lineWidth: isSelected ? 2 : 1)
        )
        .frame(height: 300)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onFocus)
        .onTapGesture(perform: onSelect)
    }

    private var header: some View {
        HStack(spacing: 6) {
            StatusDot(status: controller.status)
            Text(controller.spec.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                controller.status.isRunning ? controller.stop() : controller.start()
            } label: {
                Image(systemName: controller.status.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            Button { controller.restart() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
