import Foundation
import AppKit
import Combine

// MARK: - Data model

struct KeyShortcut: Codable, Equatable {
    let keyCode:  UInt16
    let modifiers: UInt   // NSEvent.ModifierFlags masked rawValue

    func matches(_ event: NSEvent) -> Bool {
        let relevant = event.modifierFlags
            .intersection([.command, .option, .control, .shift])
        return event.keyCode == keyCode && relevant.rawValue == modifiers
    }

    var displayString: String {
        var s = ""
        let mods = NSEvent.ModifierFlags(rawValue: modifiers)
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option)  { s += "⌥" }
        if mods.contains(.shift)   { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s
    }

    static func keyName(for code: UInt16) -> String {
        switch code {
        case 36: return "↩"
        case 53: return "⎋"
        case 51: return "⌫"
        case 49: return "Space"
        case 48: return "⇥"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let map: [UInt16: String] = [
                0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",
                8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",
                16:"Y",17:"T",31:"O",32:"U",34:"I",35:"P",37:"L",
                38:"J",40:"K",45:"N",46:"M",
                18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",
                25:"9",26:"7",28:"8",29:"0"
            ]
            return map[code] ?? "(\(code))"
        }
    }
}

// MARK: - Store

class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    @Published var approve: KeyShortcut?
    @Published var deny:    KeyShortcut?
    @Published var hide:    KeyShortcut?

    private enum UDKey {
        static let approve = "shortcut.approve"
        static let deny    = "shortcut.deny"
        static let hide    = "shortcut.hide"
    }

    init() {
        load()
        // 기본값: 권한 허락 = Cmd+Return (기존 동작 유지)
        if approve == nil {
            approve = KeyShortcut(keyCode: 36,
                                  modifiers: NSEvent.ModifierFlags.command.rawValue)
        }
    }

    func save() {
        let enc = JSONEncoder()
        UserDefaults.standard.set(try? enc.encode(approve), forKey: UDKey.approve)
        UserDefaults.standard.set(try? enc.encode(deny),    forKey: UDKey.deny)
        UserDefaults.standard.set(try? enc.encode(hide),    forKey: UDKey.hide)
    }

    private func load() {
        let dec = JSONDecoder()
        approve = (UserDefaults.standard.data(forKey: UDKey.approve))
            .flatMap { try? dec.decode(KeyShortcut.self, from: $0) }
        deny    = (UserDefaults.standard.data(forKey: UDKey.deny))
            .flatMap { try? dec.decode(KeyShortcut.self, from: $0) }
        hide    = (UserDefaults.standard.data(forKey: UDKey.hide))
            .flatMap { try? dec.decode(KeyShortcut.self, from: $0) }
    }
}
