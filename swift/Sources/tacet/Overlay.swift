import AppKit
import Foundation

/// On-screen presentation for the agent: the recording indicator and every
/// user-facing message.
///
/// This exists because the agent had no presentation layer at all. `alert()`
/// posted an `NSWorkspace` notification named "TacetAlert" that nothing
/// anywhere observed, and `brief()` was `{ _ = message }` — so the entire
/// diagnostic surface, 401/415/400/503, transport failures, "heard nothing",
/// "paste withheld (focus moved)", was silently discarded. The menu bar title
/// flipping to "●" was the only feedback of any kind, and it is easy to miss
/// on a crowded menu bar.
///
/// A silent failure is the worst outcome here. If dictation does nothing the
/// instinct is to try again, and a second silent failure reads as "the mic is
/// broken" when the real cause might be a stale key or a downed tailnet link.
final class Overlay {
    static let shared = Overlay()

    private var panel: NSPanel?
    private var dismissTimer: Timer?

    /// `duration: nil` pins the panel until `hide()` — used by the recording
    /// indicator, which is cleared when capture actually ends rather than on a
    /// timer.
    func show(_ text: String, duration: TimeInterval?) {
        precondition(Thread.isMainThread)
        hide()

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.preferredMaxLayoutWidth = 520

        let size = label.sizeThatFits(NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude))
        let padding: CGFloat = 22
        let frame = NSRect(x: 0, y: 0,
                           width: size.width + padding * 2,
                           height: size.height + padding * 2)

        // .nonactivatingPanel is load-bearing: without it, showing the panel
        // pulls keyboard focus away from whatever the user is dictating into,
        // which is the one thing this tool must never do.
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = NSVisualEffectView(frame: frame)
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true

        label.frame = NSRect(x: padding, y: padding, width: size.width, height: size.height)
        container.addSubview(label)
        panel.contentView = container

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                                         y: visible.minY + visible.height * 0.18))
        }

        panel.orderFrontRegardless()
        self.panel = panel

        if let duration {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
                DispatchQueue.main.async { Overlay.shared.hide() }
            }
        }
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// "Basso" is a built-in macOS alert sound, chosen because it reads as a
    /// failure tone rather than routine feedback.
    static func beep() {
        NSSound(named: NSSound.Name("Basso"))?.play()
    }
}
