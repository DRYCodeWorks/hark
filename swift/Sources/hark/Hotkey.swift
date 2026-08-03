import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Global hold-to-talk hotkey (Ctrl+Alt+Space) for the agent.
///
/// PHASE 0 IS DECIDED: Carbon `RegisterEventHotKey`, not a keyboard
/// `CGEventTap`. The design left this to a hardware spike; the spike has now
/// been run, and the tap loses on correctness rather than on taste.
///
/// WHY THE TAP FAILED
///
/// A tap sees raw key events, so a chord must be reconstructed from the
/// keycode plus the modifier flags carried on that event — and those flags
/// describe the instant the event was generated. Releasing Ctrl+Alt+Space
/// almost always lifts a modifier at or before the space bar, so the space
/// key-UP arrives with the modifier bits already clear. A chord test applied
/// to both edges therefore matches the press and misses the release.
///
/// Measured with a bare session tap over 45 s of ordinary use:
///
///     DOWN events: 303      (auto-repeat while held)
///     UP events:     1
///
/// One release out of dozens. In the agent that meant a capture that never
/// ended, and because `beginCapture()` guards on `state == .idle`, every
/// subsequent press was ignored — presenting as "the hotkey stopped working"
/// rather than as a missed key-up.
///
/// The fix is NOT to loosen the key-up test. Tracking "a capture is open, so
/// end it on any space key-up" re-implements, badly, something the OS already
/// does correctly: `RegisterEventHotKey` delivers `kEventHotKeyPressed` and
/// `kEventHotKeyReleased` as distinct events, and the release is not
/// conditional on the modifiers still being held.
///
/// Two further advantages, both resolving open questions in the design:
///
///   - It CONSUMES the chord, so Ctrl+Alt+Space does not also reach whatever
///     app has focus. A global tap that passes events through cannot.
///   - It needs no permission of its own, settling the Phase 0 question of
///     whether a keyboard tap would additionally require Input Monitoring.
///     Accessibility is still required — for synthesising the ⌘V paste — so
///     the agent asks for exactly one grant either way.
///
/// It is also what `hs.hotkey` used underneath, making it the mechanism
/// already proven against this exact chord and hold pattern.
public final class Hotkey {
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// The Carbon handler is a C function pointer and can capture nothing, so
    /// the live instance is reached through this. Only one hotkey is ever
    /// registered; a second `register()` replaces the first.
    fileprivate static weak var current: Hotkey?

    /// Returns false if the hotkey could not be bound — most likely because
    /// something else already owns Ctrl+Alt+Space.
    @discardableResult
    public func register() -> Bool {
        unregister()
        Hotkey.current = self

        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let installed = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyEventHandler, specs.count, &specs, nil, &handlerRef)
        guard installed == noErr else { return false }

        // 'HARK' as an OSType — the conventional four-char signature.
        let id = EventHotKeyID(signature: OSType(0x4841_524B), id: 1)

        // Ctrl+Alt+Space, NOT Cmd+Alt+Space: the latter is macOS's Finder
        // search shortcut and the system wins that fight.
        let registered = RegisterEventHotKey(
            UInt32(kVK_Space), UInt32(controlKey | optionKey),
            id, GetApplicationEventTarget(), 0, &hotKeyRef)
        return registered == noErr
    }

    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        if Hotkey.current === self { Hotkey.current = nil }
    }

    /// True when the chord is actually bound — used by the heartbeat, which
    /// previously reported a hardcoded "registered" whether or not anything
    /// had been bound.
    public var isRegistered: Bool { hotKeyRef != nil }

    fileprivate func handle(kind: Int) {
        switch kind {
        case kEventHotKeyPressed: onPress?()
        case kEventHotKeyReleased: onRelease?()
        default: break
        }
    }
}

/// Carbon dispatches on the main thread, which is where the agent's state
/// machine lives, so no queue hop is needed.
private let hotKeyEventHandler: EventHandlerUPP = { _, event, _ -> OSStatus in
    guard let event, let hotkey = Hotkey.current else { return OSStatus(eventNotHandledErr) }
    let kind = Int(GetEventKind(event))
    guard kind == kEventHotKeyPressed || kind == kEventHotKeyReleased else {
        return OSStatus(eventNotHandledErr)
    }
    hotkey.handle(kind: kind)
    return noErr
}
