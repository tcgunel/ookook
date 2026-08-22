import SwiftUI

/// "This terminal was in conversation X last time - want it back?"
///
/// Shown per terminal rather than acted on automatically: which conversations
/// are worth continuing is a judgement only the user can make, and resuming
/// one is not free - the first message re-uploads the whole context.
struct ResumeOfferBar: View {
    @ObservedObject var controller: ProcessController
    /// Recent conversations for this project, used to put a human label on the
    /// remembered id. Absent labels are not a problem; the id still resumes.
    let sessions: [ClaudeSessionSummary]

    var body: some View {
        if let offer = controller.resumeOffer {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text(label(for: offer))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Resume") {
                    controller.resume(sessionID: offer.sessionID, model: offer.model)
                }
                .controlSize(.small)
                Button {
                    controller.dismissResumeOffer()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Keep this a fresh session")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6))
        }
    }

    private func label(for offer: LastSessionStore.Entry) -> String {
        if let match = sessions.first(where: { $0.id == offer.sessionID }) {
            return "Last session: \(match.label)"
        }
        return "Last session: \(offer.sessionID.prefix(8))… · \(Self.formatter.string(from: offer.endedAt))"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
