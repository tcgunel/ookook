import SwiftUI

/// A compact bar showing how full an agent's context window is.
///
/// It fills toward warning colours as the window fills, because the useful
/// signal is "this session is about to compact", not the exact number.
struct ContextGauge: View {
    let fraction: Double
    let summary: String

    private var tint: Color {
        switch fraction {
        case ..<0.6: return .green
        case ..<0.85: return .yellow
        default: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(2, geometry.size.width * fraction))
                }
            }
            .frame(height: 3)

            Text(summary)
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .help("Context window in use: \(summary)")
    }
}
