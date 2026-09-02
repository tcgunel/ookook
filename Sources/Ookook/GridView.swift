import AppKit
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
    /// Row height, dragged by the grip on any tile's bottom edge. One height for
    /// the whole grid rather than per tile: rows in a grid share a baseline, so
    /// a taller tile would only stretch its neighbours to match and the extra
    /// setting would buy nothing.
    @Binding var tileHeight: Double
    /// Height while a drag is in flight.
    ///
    /// The committed value is only written when the drag ends: `tileHeight` is
    /// backed by `@AppStorage`, and writing UserDefaults on every mouse-move
    /// event is both wasteful and a source of visible stutter.
    @State private var draftHeight: Double?
    /// The area the grid actually has, reported up so the Fit button can use it.
    @Binding var measuredSize: CGSize
    /// Where tile order lives. A grid drag writes the same layout a sidebar
    /// drag does, so the two views can never disagree about the order.
    @ObservedObject var layout: SidebarLayoutStore
    /// Controllers per project, needed to seed a layout on the first drag.
    let controllersByProject: [String: [ProcessController]]
    /// Cross-project drops reorder the projects instead.
    let onMoveProject: (String, String) -> Void
    /// Removing a process is only offered for ones added from the UI.
    /// Recent conversations per project, for the Resume submenu.
    @ObservedObject var agentSessions: AgentSessionStore
    let canRemove: (ProcessRef) -> Bool
    /// Whether the process was added from the UI, so the menu can say when
    /// removing one will edit ookook.yml instead.
    let isLocal: (ProcessRef) -> Bool
    let onRemove: (ProcessRef) -> Void

    /// The tile whose name is being edited. The sheet lives here rather than on
    /// the tile so it survives the grid reflowing underneath it.
    @State private var renaming: RenameTarget?

    static let minTileHeight: Double = 140
    static let maxTileHeight: Double = 1400
    static let spacing: Double = 10
    static let padding: Double = 10
    /// Narrowest a tile is allowed to get before the adaptive grid drops a
    /// column. Mirrors the `.adaptive(minimum:)` below - they must agree or a
    /// fit would be computed for a column count the grid does not use.
    static let minTileWidth: Double = 320

    /// The height that makes every tile fit without scrolling.
    ///
    /// Static and pure so the toolbar can ask for it without owning any of the
    /// grid's layout state.
    static func fittingHeight(tiles: Int, columns: Int, in size: CGSize) -> Double {
        guard tiles > 0 else { return 300 }
        let perRow = max(1, columns > 0
            ? columns
            : Int((size.width - padding * 2 + spacing) / (minTileWidth + spacing)))
        let rows = Double((tiles + perRow - 1) / perRow)
        let available = size.height - padding * 2 - spacing * (rows - 1)
        return min(max(available / rows, minTileHeight), maxTileHeight)
    }

    /// How many columns the grid is laid out in right now.
    ///
    /// The adaptive case mirrors `fittingHeight`'s arithmetic rather than
    /// letting `LazyVGrid` decide, because a tile may now span more than one
    /// column and rows have to be packed by hand for that to work at all.
    private func columns(for width: Double) -> Int {
        Self.columnCount(for: width, preferred: columnCount)
    }

    /// The same arithmetic, reachable without a grid to ask.
    ///
    /// ⌘↑/⌘↓ move a row rather than a tile, and a row is only as wide as the
    /// grid happens to be laid out right now - so the keyboard shortcut needs
    /// the same answer the layout uses, from outside the view.
    static func columnCount(for width: Double, preferred: Int) -> Int {
        if preferred > 0 { return preferred }
        guard width > 0 else { return 1 }
        return max(1, Int((width - padding * 2 + spacing) / (minTileWidth + spacing)))
    }

    /// Width of one column, and so of a tile spanning one.
    private func cellWidth(for width: Double, columns: Int) -> Double {
        let available = width - Self.padding * 2 - Self.spacing * Double(columns - 1)
        return max(Self.minTileWidth / 2, available / Double(columns))
    }

    /// Packs the tiles into rows, filling each row until the next tile's span
    /// no longer fits. A tile wider than the grid is simply capped at full
    /// width, which is what `span(…columns:)` already guarantees.
    private func rows(columns: Int) -> [[ProcessController]] {
        var rows: [[ProcessController]] = []
        var current: [ProcessController] = []
        var used = 0
        for controller in controllers {
            let span = self.span(controller, columns: columns)
            if used + span > columns, !current.isEmpty {
                rows.append(current)
                current = []
                used = 0
            }
            current.append(controller)
            used += span
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    private func span(_ controller: ProcessController, columns: Int) -> Int {
        layout.span(projectID: controller.projectID,
                    process: controller.spec.name,
                    columns: columns)
    }

    var body: some View {
        GeometryReader { proxy in
            content
                .onAppear { measuredSize = proxy.size }
                .onChange(of: proxy.size) { measuredSize = proxy.size }
        }
    }

    private var content: some View {
        let columns = columns(for: measuredSize.width)
        let cell = cellWidth(for: measuredSize.width, columns: columns)
        return ScrollView {
            VStack(spacing: Self.spacing) {
                ForEach(Array(rows(columns: columns).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: Self.spacing) {
                        ForEach(row) { controller in
                            tile(controller, columns: columns, cell: cell)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(Self.padding)
        }
        .sheet(item: $renaming) { target in
            RenameSheet(target: target) { newName in
                if case .process(let projectID, let process, _) = target {
                    layout.rename(projectID: projectID, process: process, to: newName)
                }
            }
        }
    }

    private func tile(_ controller: ProcessController, columns: Int, cell: Double) -> some View {
        let span = self.span(controller, columns: columns)
        return GridTile(controller: controller,
                             projectName: projectNames.count > 1 ? projectNames[controller.projectID] : nil,
                             isSelected: controller.ref == selection,
                             onSelect: { selection = controller.ref },
                             onFocus: { onFocus(controller.ref) },
                             onDrop: { dragged in drop(dragged, before: controller.ref) },
                             height: draftHeight ?? tileHeight,
                             onResize: { draftHeight = $0 },
                             onResizeEnd: {
                                 if let draftHeight { tileHeight = draftHeight }
                                 draftHeight = nil
                             },
                             sessions: controller.spec.kind == .agent
                                 ? agentSessions.sessions(for: controller.projectID,
                                                          provider: controller.spec.agentProvider)
                                 : [],
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
                                 : nil,
                             removeEditsConfig: !isLocal(controller.ref),
                             span: span,
                             columns: columns,
                             cellWidth: cell,
                             onSpan: { newSpan in
                                 guard newSpan != span else { return }
                                 layout.setSpan(newSpan,
                                                projectID: controller.projectID,
                                                process: controller.spec.name)
                             })
            .frame(width: cell * Double(span) + Self.spacing * Double(span - 1))
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
    let height: Double
    let onResize: (Double) -> Void
    let onResizeEnd: () -> Void
    let sessions: [AgentSessionSummary]
    let label: String
    let isHidden: Bool
    let onToggleHidden: () -> Void
    let onRename: () -> Void
    let onResetName: (() -> Void)?
    let onRemove: (() -> Void)?
    /// True when removing edits ookook.yml rather than this Mac's own list.
    var removeEditsConfig: Bool = false
    /// How many grid columns this tile currently takes, and how many there are
    /// to take. One tile can be worth more of the window than its neighbours -
    /// the agent you are reading wants room; the four you are only watching for
    /// a status dot do not.
    let span: Int
    let columns: Int
    /// Width of a single column, so the side grip can turn a drag into a span.
    let cellWidth: Double
    let onSpan: (Int) -> Void

    @State private var isTargeted = false
    @State private var isHoveringGrip = false
    @State private var isHoveringWidthGrip = false
    /// Height when the current drag began; nil when not dragging.
    @State private var dragStartHeight: Double?

    var body: some View {
        VStack(spacing: 0) {
            header
            ResumeOfferBar(controller: controller, sessions: sessions)
            TerminalPane(controller: controller, onFocus: onSelect)
                .frame(minHeight: 60)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, lineWidth: isTargeted || isSelected ? 2 : 1)
        )
        .frame(height: height)
        .overlay(alignment: .bottom) { resizeGrip }
        .overlay(alignment: .trailing) { widthGrip }
        // No tap gesture spans the tile. One covering the terminal eats the
        // click before SwiftTerm sees it, which leaves the terminal unable to
        // take keyboard focus - the tile looks alive but will not accept
        // typing - and turns a double-click on a word into a view-mode switch.
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
            // A wedged terminal is indistinguishable from a healthy one - it
            // still prints, it still scrolls - so the only way to know is to
            // be told. Without this the failure reads as "the app has stopped
            // accepting my keyboard", which is where the hunt starts wrong.
            if controller.isInputWedged {
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("Input path lost - typing is discarded. Restart to recover; the conversation is kept.")
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
        .onTapGesture(count: 2) {
            onFocus()
            controller.focusTerminal()
        }
        .onTapGesture {
            onSelect()
            controller.focusTerminal()
        }
        .processDraggable(controller.ref)
        .contextMenu { actions }
        .help("Click to select, double-click to open full size, drag to reorder")
    }

    /// The same idea as the bottom grip, along the right edge: dragging it
    /// snaps the tile to whole columns, because a grid whose tiles are all
    /// slightly different widths reads as broken rather than as arranged.
    private var widthGrip: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                isHoveringWidthGrip = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let unit = cellWidth + GridView.spacing
                        guard unit > 0 else { return }
                        let width = cellWidth * Double(span) + GridView.spacing * Double(span - 1)
                        let dragged = width + (value.location.x - value.startLocation.x)
                        let wanted = Int(((dragged + GridView.spacing) / unit).rounded())
                        onSpan(min(max(1, wanted), columns))
                    })
            .overlay {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(isHoveringWidthGrip ? 0.5 : 0))
                    .frame(width: 3, height: 28)
            }
            .onTapGesture(count: 2) { onSpan(1) }
            .help("Drag to widen this tile across columns")
    }

    /// A grab strip along the bottom edge. Sized generously (8pt) because a
    /// 1pt hairline is a target you have to aim at, and the cursor changes on
    /// hover so it is discoverable without a tooltip.
    private var resizeGrip: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                isHoveringGrip = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            // The gesture must measure in a coordinate space that does not move
            // with what it is resizing. In the grip's own space, growing the
            // tile drags the grip out from under the cursor, so the next event
            // measures from a new origin: the tile races away from the pointer
            // and flickers as the two fight.
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight ?? height
                        if dragStartHeight == nil { dragStartHeight = start }
                        let delta = value.location.y - value.startLocation.y
                        onResize(min(max(start + delta,
                                         GridView.minTileHeight), GridView.maxTileHeight))
                    }
                    .onEnded { _ in
                        dragStartHeight = nil
                        onResizeEnd()
                    })
            .overlay {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(isHoveringGrip ? 0.5 : 0))
                    .frame(width: 28, height: 3)
            }
            // Double-click the grip to go back to the default height, the same
            // way a window divider resets.
            .onTapGesture(count: 2) {
                onResize(300)
                onResizeEnd()
            }
    }

    @ViewBuilder
    private var actions: some View {
        if columns > 1 {
            Menu("Width") {
                ForEach(1...columns, id: \.self) { count in
                    Button {
                        onSpan(count)
                    } label: {
                        if count == span {
                            Label(widthLabel(count), systemImage: "checkmark")
                        } else {
                            Text(widthLabel(count))
                        }
                    }
                }
            }
            Divider()
        }
        ProcessActionItems(controller: controller,
                           isHidden: isHidden,
                           onToggleHidden: onToggleHidden,
                           onRename: onRename,
                           onResetName: onResetName,
                           onRemove: onRemove,
                           removeEditsConfig: removeEditsConfig,
                           sessions: sessions,
                           onResume: { controller.resume($0) },
                           onClearResume: { controller.clearResume() },
                           isResuming: controller.commandOverride != nil)
    }

    private func widthLabel(_ count: Int) -> String {
        count == columns ? "Full width" : "\(count) of \(columns) columns"
    }

    private var borderColor: Color {
        if isTargeted { return .accentColor }
        return isSelected ? .accentColor : .secondary.opacity(0.25)
    }
}
