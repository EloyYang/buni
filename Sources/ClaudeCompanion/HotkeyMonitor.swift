import Carbon.HIToolbox
import AppKit

/// Carbon RegisterEventHotKey 기반 전역 단축키 — Input Monitoring 권한 불필요
final class HotkeyMonitor {

    var onApprove:       (() -> Void)?
    var onDeny:          (() -> Void)?
    var onHide:          (() -> Void)?
    var onAlwaysApprove: (() -> Void)?

    private enum Slot: UInt32 { case approve = 1, deny = 2, hide = 3, alwaysApprove = 4 }

    private var refs:       [Slot: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    private var currentApprove:       KeyShortcut?
    private var currentDeny:          KeyShortcut?
    private var currentHide:          KeyShortcut?
    private var currentAlwaysApprove: KeyShortcut?
    private var inPermissionState = false

    init() { installHandler() }

    deinit {
        refs.values.forEach { UnregisterEventHotKey($0) }
        if let h = handlerRef { RemoveEventHandler(h) }
    }

    // MARK: - Public

    func updateShortcuts(approve: KeyShortcut?, deny: KeyShortcut?, hide: KeyShortcut?,
                         alwaysApprove: KeyShortcut? = nil) {
        currentApprove       = approve
        currentDeny          = deny
        currentHide          = hide
        currentAlwaysApprove = alwaysApprove
        sync()
    }

    /// 권한 버블이 떠있을 때만 approve/deny 단축키를 등록
    func updatePermissionState(_ isPermission: Bool) {
        guard isPermission != inPermissionState else { return }
        inPermissionState = isPermission
        sync()
    }

    // MARK: - Registration

    private func sync() {
        // hide: 항상 활성
        register(slot: .hide, shortcut: currentHide)
        // approve/deny/alwaysApprove: 권한 버블이 보일 때만 활성
        register(slot: .approve,       shortcut: inPermissionState ? currentApprove       : nil)
        register(slot: .deny,          shortcut: inPermissionState ? currentDeny          : nil)
        register(slot: .alwaysApprove, shortcut: inPermissionState ? currentAlwaysApprove : nil)
    }

    private func register(slot: Slot, shortcut: KeyShortcut?) {
        if let existing = refs[slot] {
            UnregisterEventHotKey(existing)
            refs.removeValue(forKey: slot)
        }
        guard let sc = shortcut else { return }

        var ref: EventHotKeyRef?
        var hkID = EventHotKeyID()
        hkID.signature = 0x434C4459  // 'CLDY'
        hkID.id = slot.rawValue

        let err = RegisterEventHotKey(
            UInt32(sc.keyCode),
            carbonModifiers(from: sc.modifiers),
            hkID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if err == noErr, let ref { refs[slot] = ref }
    }

    // MARK: - Carbon event handler

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let ptr = userData else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(ptr).takeUnretainedValue()
                var hkID = EventHotKeyID()
                GetEventParameter(event,
                                  EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID),
                                  nil,
                                  MemoryLayout<EventHotKeyID>.size,
                                  nil,
                                  &hkID)
                monitor.fire(id: hkID.id)
                return noErr
            },
            1, &spec, selfPtr, &handlerRef
        )
    }

    private func fire(id: UInt32) {
        DispatchQueue.main.async {
            switch Slot(rawValue: id) {
            case .approve:       self.onApprove?()
            case .deny:          self.onDeny?()
            case .hide:          self.onHide?()
            case .alwaysApprove: self.onAlwaysApprove?()
            case nil:            break
            }
        }
    }

    // MARK: - Modifier conversion

    private func carbonModifiers(from nsModifiers: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: nsModifiers)
        var c: UInt32 = 0
        if flags.contains(.command) { c |= UInt32(cmdKey) }
        if flags.contains(.option)  { c |= UInt32(optionKey) }
        if flags.contains(.control) { c |= UInt32(controlKey) }
        if flags.contains(.shift)   { c |= UInt32(shiftKey) }
        return c
    }
}
