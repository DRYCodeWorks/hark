import ApplicationServices
import CoreGraphics
import Foundation

/// Global hold-to-talk hotkey (Ctrl+Alt+Space) for the agent.
///
/// ⚠️ PHASE 0 OPEN QUESTION (per the native-client design, §Phase 0): the exact
/// mechanism — a keyboard `CGEventTap` (this implementation) versus Carbon
/// `RegisterEventHotKey` — is meant to be decided by a hardware spike, because
/// it decides whether one TCC grant (Accessibility) is enough or a keyboard
/// event tap also needs an Input Monitoring grant. This file implements the
/// tap variant as a working default; Phase 0 must validate which grant set the
/// final signed bundle actually needs before release.
public final class Hotkey {
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private static let keySpace: Int64 = 49 // kVK_Space

    /// Register the global tap. Returns false if Accessibility is not granted
    /// (the tap cannot be created), so the controller can surface it.
    @discardableResult
    public func register() -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<Hotkey>.fromOpaque(refcon).takeUnretainedValue()
                me.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func unregister() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // Ignore auto-repeat (the key is held) — nothing happens on repeat.
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let isChord = keycode == Self.keySpace
            && flags.contains(.maskControl)
            && flags.contains(.maskAlternate)
        guard isChord, !isRepeat else { return }

        if type == .keyDown {
            onPress?()
        } else if type == .keyUp {
            onRelease?()
        }
    }
}
