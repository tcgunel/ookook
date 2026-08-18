import Foundation

/// Identifies one process within one project.
///
/// Process names are only unique inside a project (`ProjectConfig.validate`
/// enforces that), so once several projects are open the sidebar selection has
/// to be qualified or two projects with a `dev` process collide.
struct ProcessRef: Hashable, Codable, Identifiable {
    let project: String
    let process: String

    var id: String { "\(project)\u{1F}\(process)" }
}
