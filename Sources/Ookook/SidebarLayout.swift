import Combine
import Foundation

/// A user-made sidebar group.
///
/// Membership is stored as process *names* rather than `ProcessRef`s because a
/// group always lives inside one project; repeating the project id on every
/// member would only be one more thing that can drift out of sync.
struct SidebarGroup: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var symbolName: String = "folder"
    var members: [String] = []
}

/// The custom layout of one project's sidebar, as the user arranged it.
///
/// Empty `groups` means "this project has never been rearranged", which is what
/// keeps `ProcessKind` the default grouping instead of a special case.
struct ProjectLayout: Codable, Equatable {
    var groups: [SidebarGroup] = []
    /// Display names the user has given processes, keyed by the name in
    /// `ookook.yml`. The config name stays the identity - it is what
    /// `ProcessRef`, the MCP tools and the layout all key off - so renaming is
    /// a label, not a rename of the thing itself.
    var names: [String: String] = [:]
    /// Processes hidden from the grid. They keep running - this is about
    /// getting something out of your eyeline, not stopping it.
    var hidden: Set<String> = []

    var isCustom: Bool { !groups.isEmpty }

    func groupIndex(containing process: String) -> Int? {
        groups.firstIndex { $0.members.contains(process) }
    }
}

/// One rendered sidebar group, whether it came from `ProcessKind` or from the
/// user's own arrangement. The view layer only ever sees this.
struct SidebarSection: Identifiable {
    /// Set only for user groups; `nil` marks a kind-derived section, which
    /// cannot be renamed or deleted and only accepts drops by converting the
    /// project to a custom layout first.
    let groupID: UUID?
    let title: String
    let symbolName: String
    let controllers: [ProcessController]

    var id: String { groupID?.uuidString ?? title }

    @MainActor
    var runningCount: Int {
        controllers.filter { $0.status.isRunning }.count
    }
}

/// Where the user's grouping lives.
///
/// Deliberately *not* `ookook.yml`: that file is committed and shared, so a
/// drag rewriting it would show up as a diff on a teammate's checkout and
/// conflict on merge. This is per-machine view state, the same category as
/// `viewMode` and the open-project list, so it goes in `UserDefaults` next to
/// them rather than introducing an Application Support directory the app does
/// not otherwise have - a few kilobytes of JSON does not justify a file store
/// with its own IO error paths.
@MainActor
final class SidebarLayoutStore: ObservableObject {
    private static let defaultsKey = "sidebarLayout"

    @Published private var layouts: [String: ProjectLayout] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Reading

    func layout(for projectID: String) -> ProjectLayout {
        layouts[projectID] ?? ProjectLayout()
    }

    func isCustom(projectID: String) -> Bool {
        layout(for: projectID).isCustom
    }

    /// What to show for a process: the user's label, or its config name.
    func displayName(projectID: String, process: String) -> String {
        layout(for: projectID).names[process] ?? process
    }

    func hasCustomName(projectID: String, process: String) -> Bool {
        layout(for: projectID).names[process] != nil
    }

    func isHidden(projectID: String, process: String) -> Bool {
        layout(for: projectID).hidden.contains(process)
    }

    func setHidden(_ hidden: Bool, projectID: String, process: String) {
        update(projectID) { layout in
            if hidden { layout.hidden.insert(process) } else { layout.hidden.remove(process) }
        }
    }

    /// Sections to render for a project.
    ///
    /// Pure: it reconciles against the live controllers without writing, so
    /// calling it from `body` cannot mutate published state mid-render. Names
    /// that vanished from `ookook.yml` simply do not resolve to a controller
    /// and so cannot leave a ghost row; names that appeared since the last drag
    /// land in the first group, which is where a user scanning top-down looks.
    func sections(projectID: String, controllers: [ProcessController]) -> [SidebarSection] {
        let layout = layout(for: projectID)
        guard layout.isCustom else {
            return Self.kindSections(controllers)
        }

        let byName = Dictionary(controllers.map { ($0.spec.name, $0) }, uniquingKeysWith: { first, _ in first })
        var claimed: Set<String> = []
        var sections: [SidebarSection] = []

        for group in layout.groups {
            let members = group.members.compactMap { name -> ProcessController? in
                guard let controller = byName[name] else { return nil }
                claimed.insert(name)
                return controller
            }
            sections.append(SidebarSection(groupID: group.id,
                                           title: group.name.uppercased(),
                                           symbolName: group.symbolName,
                                           controllers: members))
        }

        let unassigned = controllers.filter { !claimed.contains($0.spec.name) }
        guard !unassigned.isEmpty, var first = sections.first else { return sections }
        first = SidebarSection(groupID: first.groupID,
                               title: first.title,
                               symbolName: first.symbolName,
                               controllers: first.controllers + unassigned)
        sections[0] = first
        return sections
    }

    private static func kindSections(_ controllers: [ProcessController]) -> [SidebarSection] {
        ProcessKind.allCases.compactMap { kind in
            let members = controllers.filter { $0.spec.kind == kind }
            guard !members.isEmpty else { return nil }
            return SidebarSection(groupID: nil,
                                  title: kind.sectionTitle,
                                  symbolName: kind.symbolName,
                                  controllers: members)
        }
    }

    // MARK: - Editing

    /// Turns the kind grouping into an equivalent custom layout, so the first
    /// drag starts from what the user is already looking at instead of
    /// collapsing everything into one list.
    func adoptKindLayout(projectID: String, controllers: [ProcessController]) {
        guard !isCustom(projectID: projectID) else { return }
        let groups = ProcessKind.allCases.compactMap { kind -> SidebarGroup? in
            let members = controllers.filter { $0.spec.kind == kind }.map(\.spec.name)
            guard !members.isEmpty else { return nil }
            return SidebarGroup(name: kind.sectionTitle.capitalized,
                                symbolName: kind.symbolName,
                                members: members)
        }
        guard !groups.isEmpty else { return }
        update(projectID) { $0.groups = groups }
    }

    @discardableResult
    func createGroup(projectID: String,
                     named name: String,
                     symbolName: String = "folder",
                     controllers: [ProcessController]) -> UUID {
        adoptKindLayout(projectID: projectID, controllers: controllers)
        let group = SidebarGroup(name: name, symbolName: symbolName)
        update(projectID) { $0.groups.append(group) }
        return group.id
    }

    func renameGroup(projectID: String, id: UUID, to name: String) {
        update(projectID) { layout in
            guard let index = layout.groups.firstIndex(where: { $0.id == id }) else { return }
            layout.groups[index].name = name
        }
    }

    func setSymbol(projectID: String, id: UUID, symbolName: String) {
        update(projectID) { layout in
            guard let index = layout.groups.firstIndex(where: { $0.id == id }) else { return }
            layout.groups[index].symbolName = symbolName
        }
    }

    /// Deleting a group never deletes processes: its members fall back to the
    /// first remaining group, and deleting the last group reverts the project
    /// to kind grouping.
    func deleteGroup(projectID: String, id: UUID) {
        update(projectID) { layout in
            guard let index = layout.groups.firstIndex(where: { $0.id == id }) else { return }
            let orphans = layout.groups.remove(at: index).members
            guard !layout.groups.isEmpty else { return }
            let fallback = min(index, layout.groups.count - 1)
            layout.groups[fallback].members.append(contentsOf: orphans)
        }
    }

    func moveGroups(projectID: String, from source: IndexSet, to destination: Int) {
        update(projectID) { $0.groups.move(fromOffsets: source, toOffset: destination) }
    }

    /// Moves a process into `groupID`, optionally landing it just above
    /// `before`. This only ever rewrites the layout - it never touches
    /// `Project.load()`, which stops and rebuilds every process, so a drag
    /// cannot restart anything.
    func move(_ ref: ProcessRef, toGroup groupID: UUID, before: ProcessRef? = nil) {
        update(ref.project) { layout in
            guard let target = layout.groups.firstIndex(where: { $0.id == groupID }) else { return }
            for index in layout.groups.indices {
                layout.groups[index].members.removeAll { $0 == ref.process }
            }
            var insertion = layout.groups[target].members.count
            if let before, let at = layout.groups[target].members.firstIndex(of: before.process) {
                insertion = at
            }
            layout.groups[target].members.insert(ref.process, at: insertion)
        }
    }

    /// Drops onto a row in a project that is still kind-grouped: adopt the
    /// visible arrangement first so the move has somewhere to land.
    func move(_ ref: ProcessRef,
              toGroup groupID: UUID?,
              before: ProcessRef?,
              in projectID: String,
              controllers: [ProcessController]) {
        guard let groupID else { return }
        // `controllers` belongs to `projectID`. Seeding a *different* project's
        // layout from them would fill its groups with names that resolve to
        // nothing, collapsing that project's sidebar into one mislabelled
        // group - and persisting it. The drop targets reject cross-project
        // drags too; this is the second lock on the same door.
        guard ref.project == projectID else { return }
        adoptKindLayout(projectID: projectID, controllers: controllers)
        move(ref, toGroup: groupID, before: before)
    }

    /// An empty or unchanged name clears the override rather than storing a
    /// duplicate of the config name.
    func rename(projectID: String, process: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(projectID) { layout in
            if trimmed.isEmpty || trimmed == process {
                layout.names.removeValue(forKey: process)
            } else {
                layout.names[process] = trimmed
            }
        }
    }

    func resetLayout(projectID: String) {
        layouts[projectID] = nil
        persist()
    }

    private func update(_ projectID: String, _ body: (inout ProjectLayout) -> Void) {
        var layout = layout(for: projectID)
        body(&layout)
        layouts[projectID] = layout
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(layouts) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// A layout that fails to decode - an older or hand-edited defaults entry -
    /// is dropped rather than surfaced: the sidebar falls back to kind grouping,
    /// which is always correct, just not personalised.
    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: ProjectLayout].self, from: data) else { return }
        layouts = decoded
    }
}
