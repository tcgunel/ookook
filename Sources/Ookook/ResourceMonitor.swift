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
    /// CPU per process, as a percentage of one core - so a process saturating
    /// four cores reads 400%, the same convention `top` uses. Absent until two
    /// samples exist, because it is a rate, not a reading.
    @Published private(set) var cpuByProcess: [String: Double] = [:]
    @Published private(set) var totalCPU: Double = 0

    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.tolga.ookook.resources", qos: .utility)
    /// Previous CPU totals, touched only on `queue`.
    private let cpuState = CPUState()

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
            cpuByProcess = [:]
            totalCPU = 0
            return
        }
        queue.async {
            let children = ProcessTree.childrenByParent()
            var results: [String: UInt64] = [:]
            var cpuNanos: [String: UInt64] = [:]
            for target in targets {
                let tree = ProcessTree.descendants(of: target.pid, children: children)
                results[target.id] = tree.reduce(UInt64(0)) { $0 + Self.residentBytes(of: $1) }
                cpuNanos[target.id] = tree.reduce(UInt64(0)) { $0 + Self.cpuNanos(of: $1) }
            }
            let total = results.values.reduce(0, +)
            let cpu = self.cpuState.percentages(nanos: cpuNanos, at: Date())
            let totalCPU = cpu.values.reduce(0, +)
            Task { @MainActor [weak self] in
                self?.memoryByProcess = results
                self?.totalMemory = total
                self?.cpuByProcess = cpu
                self?.totalCPU = totalCPU
            }
        }
    }

    // MARK: - Sampling primitives

    private static func residentBytesOfTree(rootedAt root: pid_t,
                                            children: [pid_t: [pid_t]]) -> UInt64 {
        ProcessTree.descendants(of: root, children: children)
            .reduce(UInt64(0)) { $0 + residentBytes(of: $1) }
    }

    /// User + system CPU time consumed since the process started, in ns.
    private static func cpuNanos(of pid: pid_t) -> UInt64 {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size)) == Int32(size) else { return 0 }
        return info.pti_total_user + info.pti_total_system
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

/// CPU is a rate, so it needs the previous sample to mean anything. Confined
/// to the monitor's sampling queue; nothing else ever touches it.
private final class CPUState: @unchecked Sendable {
    private var previous: [String: UInt64] = [:]
    private var lastSample: Date?

    func percentages(nanos: [String: UInt64], at now: Date) -> [String: Double] {
        defer {
            previous = nanos
            lastSample = now
        }
        guard let lastSample else { return [:] }
        let elapsed = now.timeIntervalSince(lastSample)
        // A clock that did not advance (or went backwards over a sleep/wake)
        // would divide by ~0 and report a nonsense spike.
        guard elapsed > 0.05 else { return [:] }
        var result: [String: Double] = [:]
        for (id, total) in nanos {
            guard let before = previous[id] else { continue }
            // A restarted process has a smaller total than last time; report
            // nothing for that tick rather than a negative or huge number.
            guard total >= before else { continue }
            let used = Double(total - before) / 1_000_000_000
            result[id] = used / elapsed * 100
        }
        return result
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

extension Double {
    /// "12%" / "140%" - whole numbers, because the sample interval makes any
    /// decimal place noise rather than precision.
    var formattedCPU: String {
        "\(Int(rounded()))%"
    }
}
