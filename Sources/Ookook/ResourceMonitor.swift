import Combine
import Darwin
import Foundation

/// Samples memory use for each supervised process and the workspace as a whole.
///
/// A process's footprint is its whole subtree, not just the shell we launched:
/// `npm run dev` is a shell that spawns node, and reporting the shell alone
/// would show ~2MB and be useless. Sampling runs off the main thread because it
/// walks every process on the machine.
@MainActor
final class ResourceMonitor: ObservableObject {
    /// Resident bytes per process id (the controller's `id`, not a pid).
    @Published private(set) var memoryByProcess: [String: UInt64] = [:]
    @Published private(set) var totalMemory: UInt64 = 0

    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.tolga.ookook.resources", qos: .utility)

    /// Supplies the pids to sample, re-read on every tick so restarts are picked up.
    var pidProvider: (() -> [(id: String, pid: pid_t)])?

    func start(interval: TimeInterval = 2) {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard let targets = pidProvider?(), !targets.isEmpty else {
            memoryByProcess = [:]
            totalMemory = 0
            return
        }
        queue.async {
            let children = ProcessTree.childrenByParent()
            var results: [String: UInt64] = [:]
            for target in targets {
                results[target.id] = Self.residentBytesOfTree(rootedAt: target.pid, children: children)
            }
            let total = results.values.reduce(0, +)
            Task { @MainActor [weak self] in
                self?.memoryByProcess = results
                self?.totalMemory = total
            }
        }
    }

    // MARK: - Sampling primitives

    private static func residentBytesOfTree(rootedAt root: pid_t,
                                            children: [pid_t: [pid_t]]) -> UInt64 {
        ProcessTree.descendants(of: root, children: children)
            .reduce(UInt64(0)) { $0 + residentBytes(of: $1) }
    }

    private static func residentBytes(of pid: pid_t) -> UInt64 {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))
        // A process that exited between the table snapshot and now simply reads 0.
        guard read == Int32(size) else { return 0 }
        return info.pti_resident_size
    }
}

extension UInt64 {
    /// Compact size for the sidebar: "412 KB", "14 MB", "1.2 GB".
    var formattedBytes: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(self))
    }
}
