import Foundation
import SwiftTerm

/// A terminal view that tees everything the child writes into a `ProcessLog`.
///
/// `dataReceived` is the one place all child output passes through, which makes
/// it the right tap for both the sidebar's activity line and the MCP log tools.
final class LoggingTerminalView: LocalProcessTerminalView {
    let log = ProcessLog()

    /// Called on the main queue, coalesced, when new output has arrived.
    var onActivity: (() -> Void)?

    private var activityPending = false

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        log.append(slice)

        // Output can arrive in a flood; coalesce UI notifications to one per
        // runloop turn rather than one per read.
        guard !activityPending else { return }
        activityPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activityPending = false
            self.onActivity?()
        }
    }
}
