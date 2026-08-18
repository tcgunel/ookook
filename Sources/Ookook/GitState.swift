import Foundation

/// What a project's checkout looks like right now.
///
/// Every field is optional-by-absence rather than zero: a branch with no
/// upstream has no ahead/behind at all, which is a different thing from being
/// level with one, and the badge renders the two differently.
struct GitState: Equatable {
    /// Branch name, or a short hash when HEAD is detached.
    var branch: String
    var isDetached: Bool
    var isDirty: Bool
    /// Nil when the branch tracks nothing - git emits no `branch.ab` line then.
    var ahead: Int?
    var behind: Int?

    init(branch: String, isDetached: Bool = false, isDirty: Bool = false,
         ahead: Int? = nil, behind: Int? = nil) {
        self.branch = branch
        self.isDetached = isDetached
        self.isDirty = isDirty
        self.ahead = ahead
        self.behind = behind
    }
}

/// Reading of a repository that needs no subprocess: where `.git` actually is,
/// and what HEAD points at.
enum GitPaths {
    /// Resolves the real git directory for a checkout.
    ///
    /// `.git` is a plain directory in the common case, but a file holding
    /// `gitdir: <path>` in worktrees (absolute path) and submodules (relative
    /// to the checkout). Both are load-bearing here because a worktree's HEAD
    /// lives in `.git/worktrees/NAME/HEAD`, not in the main repo's HEAD.
    static func gitDirectory(for root: URL) -> URL? {
        let dotGit = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return dotGit }

        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
        guard let line = contents
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
    }

    /// Branch name from `HEAD`, without spawning git.
    ///
    /// A symbolic HEAD is `ref: refs/heads/NAME`; anything else is a raw
    /// 40-hex object id, i.e. a detached checkout, which we show shortened.
    static func head(in gitDirectory: URL) -> (branch: String, isDetached: Bool)? {
        let headURL = gitDirectory.appendingPathComponent("HEAD")
        guard let raw = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
            let name = ref.hasPrefix("refs/heads/")
                ? String(ref.dropFirst("refs/heads/".count))
                : ref
            return name.isEmpty ? nil : (name, false)
        }
        return (String(line.prefix(7)), true)
    }
}
