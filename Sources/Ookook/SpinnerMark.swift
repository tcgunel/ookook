import AppKit
import SwiftUI

/// Claude Code's spinner, in Claude's colour.
///
/// The frames are the ones Claude Code itself cycles through while it works, so
/// the sidebar animates in step with what the terminal is showing. At rest it
/// settles on the asterisk the prompt idles with.
struct ClaudeMark: View {
    var isBusy: Bool

    var body: some View {
        SpinnerMark(style: isBusy ? .claudeBusy : .claudeIdle)
            .markFootprint()
    }
}

/// opencode's working mark, in rainbow.
///
/// The glyphs are opencode's own quadrant-orbit spinner frames, so the sidebar
/// animates in the same language as the Mini footer; the colour walks around the
/// wheel while a turn is in flight. "Working" is the one thing a terminal tile
/// cannot show from the outside - opencode paints with cursor positioning and
/// emits almost no newlines - so the mark carries it.
struct OpenCodeMark: View {
    var isBusy: Bool

    /// Reduce Motion turns the animation off but not the signal: a still but
    /// brighter glyph still reads as "working".
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SpinnerMark(style: isBusy ? (reduceMotion ? .opencodeStill : .opencodeBusy)
                                  : .opencodeIdle)
            .markFootprint()
    }
}

private extension View {
    /// The eight-point box the marks used to be laid out in. The drawing is a
    /// couple of points larger than that so a tall glyph is not clipped, and
    /// the negative padding takes the margin back out of the layout.
    func markFootprint() -> some View {
        let margin = (SpinnerMarkImages.canvas.width - 8) / 2
        return frame(width: SpinnerMarkImages.canvas.width,
                     height: SpinnerMarkImages.canvas.height)
            .padding(-margin)
    }
}

/// Which glyphs a mark shows, and how it moves through them.
enum MarkStyle {
    case claudeBusy
    case claudeIdle
    case opencodeBusy
    case opencodeStill
    case opencodeIdle

    var isAnimated: Bool { self == .claudeBusy || self == .opencodeBusy }

    var font: NSFont {
        switch self {
        case .claudeBusy, .claudeIdle:
            return .systemFont(ofSize: 11, weight: .semibold)
        default:
            return .systemFont(ofSize: 10, weight: .bold)
        }
    }

    var interval: TimeInterval {
        switch self {
        case .claudeBusy, .claudeIdle: return 0.12
        default: return 0.16
        }
    }

    /// The frames, in order. A still mark has exactly one.
    var glyphs: [(text: String, color: NSColor)] {
        switch self {
        case .claudeBusy:
            return ["·", "✢", "✳", "∗", "✻", "✽"].map { ($0, Self.claudeOrange) }
        case .claudeIdle:
            return [("✳", Self.claudeOrange)]
        case .opencodeStill:
            return [("▚", .labelColor)]
        case .opencodeIdle:
            return [("▚", .secondaryLabelColor)]
        case .opencodeBusy:
            // The quadrant glyphs step every frame while the hue advances
            // around the wheel once per thirty-two of them, which is the walk
            // the old timeline drew: fast orbit, slow rainbow.
            let frames = ["▖", "▘", "▝", "▗"]
            return (0..<32).map { step in
                (frames[step % frames.count],
                 NSColor(calibratedHue: CGFloat(step) / 32,
                         saturation: 0.8, brightness: 1, alpha: 1))
            }
        }
    }

    static let claudeOrange = NSColor(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
}

/// Hosts a mark whose frames are cycled by Core Animation.
///
/// The marks used to be `TimelineView`s, which re-render their glyph on a timer.
/// That is expensive out of all proportion to the drawing: every SwiftUI update
/// invalidates layout for the whole window - the sidebar and the grid share one
/// hosting view - which was measured at roughly 2ms a tick, or a fifth of a core
/// with eight agents working and nothing else going on. Baking the frames into
/// images once and stepping `contents` in the render server is the same
/// animation with no main-thread work while agents are busy.
struct SpinnerMark: NSViewRepresentable {
    let style: MarkStyle

    func makeNSView(context: Context) -> SpinnerMarkView { SpinnerMarkView() }

    func updateNSView(_ view: SpinnerMarkView, context: Context) {
        view.apply(style: style)
    }
}

final class SpinnerMarkView: NSView {
    private var style: MarkStyle = .claudeIdle
    private var renderedScale: CGFloat = 0
    private static let spinKey = "ookook.spinner"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }

    /// A mark's drawing is only re-rendered when it actually changed, so the
    /// several updates a second that flow through the sidebar cost nothing.
    func apply(style: MarkStyle) {
        guard style != self.style || renderedScale == 0 else { return }
        self.style = style
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    private func render() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        renderedScale = scale
        let frames = SpinnerMarkImages.frames(for: style, scale: scale)
        guard let layer else { return }
        layer.contentsScale = scale
        layer.contents = frames.first
        layer.removeAnimation(forKey: Self.spinKey)
        guard style.isAnimated, frames.count > 1 else { return }

        let spin = CAKeyframeAnimation(keyPath: "contents")
        spin.values = frames
        // Each frame holds until the next, which is how the timeline stepped.
        spin.calculationMode = .discrete
        spin.duration = style.interval * Double(frames.count)
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        layer.add(spin, forKey: Self.spinKey)
    }
}

/// Renders the glyphs into images, once per style and display scale.
///
/// Main-thread only: this is called from `updateNSView`, and the cache is only
/// ever touched there.
enum SpinnerMarkImages {
    /// Larger than the mark's layout box so tall glyphs are not clipped; the
    /// extra margin is transparent and `SpinnerMark` takes it back with
    /// negative padding, leaving the footprint the old fixed frame had.
    static let canvas = CGSize(width: 12, height: 12)

    private static var cache: [String: [CGImage]] = [:]

    static func frames(for style: MarkStyle, scale: CGFloat) -> [CGImage] {
        let key = "\(style)-\(scale)"
        if let cached = cache[key] { return cached }
        let rendered = style.glyphs.compactMap { image($0, font: style.font, scale: scale) }
        cache[key] = rendered
        return rendered
    }

    private static func image(_ glyph: (text: String, color: NSColor),
                              font: NSFont,
                              scale: CGFloat) -> CGImage? {
        let width = Int(canvas.width * scale)
        let height = Int(canvas.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        let text = NSAttributedString(string: glyph.text,
                                      attributes: [.font: font, .foregroundColor: glyph.color])
        let size = text.size()
        // Centred in the canvas, then lifted the single point the SwiftUI marks
        // were offset by - glyphs sit on a text baseline, the dots they replace
        // are centred.
        text.draw(at: CGPoint(x: (canvas.width - size.width) / 2,
                              y: (canvas.height - size.height) / 2 - 1))

        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
