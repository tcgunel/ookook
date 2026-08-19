import SwiftUI

/// Shows every process at once in an adaptive grid, so a wall of running agents
/// can be watched without clicking through them one at a time.
///
/// Each tile hosts the controller's own long-lived terminal view - the same one
/// the single-pane mode uses - so switching modes never loses scrollback.
struct GridView: View {
    let controllers: [ProcessController]
    /// Project names are shown on tiles only when more than one is open, so a
    /// single-project workspace stays uncluttered.
    let projectNames: [String: String]
    @Binding var selection: ProcessRef?
    /// Called when a tile is double-clicked, to drop back into single-pane focus.
    let onFocus: (ProcessRef) -> Void

    /// 0 means "fit as many as the window allows"; otherwise a fixed count.
    let columnCount: Int
    /// Where tile order lives. A grid drag writes the same layout a sidebar
    /// drag does, so the two views can never disagree about the order.
    @ObservedObject var layout: SidebarLayoutStore
    /// Controllers per project, needed to seed a layout on the first drag.
    let controllersByProject: [String: [ProcessController]]
    /// Cross-project drops reorder the projects instead.
    let onMoveProject: (String, String) -> Void
    /// Removing a process is only offered for ones added from the UI.
    let canRemove: (ProcessRef) -> Bool
    let onRemove: (ProcessRef) -> Void

    /// The tile whose name is being edited. The sheet lives here rather than on
    /// the tile so it survives the grid reflowing underneath it.
    @State private var renaming: RenameTarget?

    private var columns: [GridItem] {
        if columnCount > 0 {
            return Array(repeating: GridItem(.flexible(), spacing: 10), count: columnCount)
        }
        return [GridItem(.adaptive(minimum: 320, maximum: 720), spacing: 10)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(controllers) { controller in
                    GridTile(controller: controller,
                             projectName: projectNames.count > 1 ? projectNames[controller.projectID] : nil,
                             isSelected: controller.ref == selection,
                             onSelect: { selection = controller.ref },
                             onFocus: { onFocus(controller.ref) },
                             onDrop: { dragged in drop(dragged, before: controller.ref) },
                             label: layout.displayName(projectID: controller.projectID,
                                                       process: controller.spec.name),
                             isHidden: layout.isHidden(projectID: controller.projectID,
                                                       process: controller.spec.name),
                             onToggleHidden: {
                                 layout.setHidden(!layout.isHidden(projectID: controller.projectID,
                                                                   process: controller.spec.name),
                                                  projectID: controller.projectID,
                                                  process: controller.spec.name)
                             },
                             onRename: {
                                 renaming = .process(project: controller.projectID,
                                                     process: controller.spec.name,
                                                     current: layout.displayName(
                                                         projectID: controller.projectID,
                                                         process: controller.spec.name))
                             },
                             onResetName: layout.hasCustomName(projectID: controller.projectID,
                                                               process: controller.spec.name)
                                 ? { layout.rename(projectID: controller.projectID,
                                                   process: controller.spec.name, to: "") }
                                 : nil,
                             onRemove: canRemove(controller.ref)
                                 ? { onRemove(controller.ref) }
                                 : nil)
                }
            }
            .padding(10)
        }
        .sheet(item: $renaming) { target in
            RenameSheet(target: target) { newName in
                if case .process(let projectID, let process, _) = target {
                    layout.rename(projectID: projectID, process: process, to: newName)
                }
            }
        }
    }

    private func drop(_ dragged: ProcessRef, before target: ProcessRef) {
        guard dragged != target else { return }
        guard dragged.project == target.project else {
            onMoveProject(dragged.project, target.project)
            return
        }
        let project = target.project
        let controllers = controllersByProject[project] ?? []
        layout.adoptKindLayout(projectID: project, controllers: controllers)
        let groups = layout.layout(for: project).groups
        // Land it in whichever group the tile it was dropped on lives in;
        // across groups this is a move, within one it is a reorder.
        guard let groupID = groups.first(where: { $0.members.contains(target.process) })?.id
        else { return }
        layout.move(dragged, toGroup: groupID, before: target)
    }
}

private struct GridTile: View {
    @ObservedObject var controller: ProcessController
    let projectName: String?
    let isSelected: Bool
    let onSelect: () -> Void
    let onFocus: () -> Void
    let onDrop: (ProcessRef) -> Void
    let label: String
    let isHidden: Bool
    let onToggleHidden: () -> Void
    let onRename: () -> Void
    let onResetName: (() -> Void)?
    let onRemove: (() -> Void)?

    @State private var isTargeted = false

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
                .strokeBorder(borderColor, lineWidth: isTargeted || isSelected ? 2 : 1)
        )
        .frame(height: 300)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onFocus)
        .onTapGesture(perform: onSelect)
        // The whole tile accepts a drop, but only the header starts a drag:
        // dragging from the terminal body would fight text selection in it.
        .dropDestination(for: DraggedProcess.self) { items, _ in
            guard let dragged = items.first else { return false }
            onDrop(dragged.ref)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var header: some View {
        HStack(spacing: 6) {
            StatusDot(status: controller.status)
            if let projectName {
                Text(projectName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("/")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            if isHidden {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("Hidden from the grid; still running")
            }
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
            // Everything the sidebar row offers, without having to go find the
            // row: in a grid of a dozen tiles, the tile is what you are looking
            // at when you decide to rename or hide it.
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 9))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 16)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .underPageBackgroundColor))
        .contentShape(Rectangle())
        .processDraggable(controller.ref)
        .contextMenu { actions }
        .help("Drag to reorder")
    }

    @ViewBuilder
    private var actions: some View {
        ProcessActionItems(controller: controller,
                           isHidden: isHidden,
                           onToggleHidden: onToggleHidden,
                           onRename: onRename,
                           onResetName: onResetName,
                           onRemove: onRemove)
    }

    private var borderColor: Color {
        if isTargeted { return .accentColor }
        return isSelected ? .accentColor : .secondary.opacity(0.25)
    }
}
