import SwiftUI

/// Branch, dirtiness and divergence in the width of a sidebar header row.
///
/// Ahead/behind counts appear only when the branch tracks something and the
/// number is non-zero, because "in sync" is the boring case and shouldn't cost
/// any pixels.
struct GitBadge: View {
    let state: GitState

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: state.isDetached ? "point.3.connected.trianglepath.dotted" : "arrow.triangle.branch")
                .font(.system(size: 8))
            Text(state.branch)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
            if state.isDirty {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 4, height: 4)
            }
            if let ahead = state.ahead, ahead > 0 {
                Text("↑\(ahead)")
                    .font(.system(size: 9))
                    .monospacedDigit()
            }
            if let behind = state.behind, behind > 0 {
                Text("↓\(behind)")
                    .font(.system(size: 9))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .help(description)
    }

    private var description: String {
        var parts = [state.isDetached ? "Detached at \(state.branch)" : "On branch \(state.branch)"]
        parts.append(state.isDirty ? "uncommitted changes" : "clean")
        if let ahead = state.ahead, let behind = state.behind, ahead > 0 || behind > 0 {
            parts.append("\(ahead) ahead, \(behind) behind upstream")
        } else if state.ahead == nil {
            parts.append("no upstream")
        }
        return parts.joined(separator: " - ")
    }
}
