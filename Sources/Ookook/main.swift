import AppKit
import SwiftUI

// AppKit owns the entry point rather than the SwiftUI `App` lifecycle: a
// SwiftPM-built bundle never materialises a `Window` scene outside Xcode, so the
// window is created explicitly in the delegate and SwiftUI renders into it via
// NSHostingView.
//
// `delegate` is a global so it stays alive - NSApplication holds its delegate weakly.
let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
