import Foundation

/// A sidebar group: every process of one kind, plus how many are running.
struct ProcessSection_Model: Identifiable {
    let kind: ProcessKind
    let controllers: [ProcessController]

    var id: String { kind.rawValue }

    @MainActor
    var runningCount: Int {
        controllers.filter { $0.status.isRunning }.count
    }
}
