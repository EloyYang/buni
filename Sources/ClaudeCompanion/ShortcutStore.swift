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

    @Published var approve:       KeyShortcut?
    @Published var deny:          KeyShortcut?
    @Published var hide:          KeyShortcut?
    @Published var alwaysApprove: KeyShortcut?
    @Published var chat:          KeyShortcut?          // 채팅 입력창 열기 (채팅방에 있을 때)
    @Published var squad:         KeyShortcut?          // 부니 스쿼드 창 열기/닫기

    private enum UDKey {
        static let approve       = "shortcut.approve"
        static let deny          = "shortcut.deny"
        static let hide          = "shortcut.hide"
        static let alwaysApprove = "shortcut.alwaysApprove"
        static let chat          = "shortcut.chat"
        static let chatDefaultApplied = "shortcut.chat.defaultApplied"
        static let squad         = "shortcut.squad"
        static let squadDefaultApplied = "shortcut.squad.defaultApplied"
    }

    init() {
        load()
        // 기본값: 권한 허락 = Cmd+Return (기존 동작 유지)
        if approve == nil {
            approve = KeyShortcut(keyCode: 36,
                                  modifiers: NSEvent.ModifierFlags.command.rawValue)
        }
        // 채팅 입력 기본값: Control+Option+C — 처음 한 번만 넣고, 사용자가 지우면 그대로 비워 둔다
        if !UserDefaults.standard.bool(forKey: UDKey.chatDefaultApplied) {
            if chat == nil {
                chat = KeyShortcut(keyCode: 8,
                                   modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)
            }
            UserDefaults.standard.set(true, forKey: UDKey.chatDefaultApplied)
            save()
        }
        // 스쿼드 기본값: Control+Option+S — 처음 한 번만 넣고, 사용자가 지우면 그대로 비워 둔다
        if !UserDefaults.standard.bool(forKey: UDKey.squadDefaultApplied) {
            if squad == nil {
                squad = KeyShortcut(keyCode: 1,
                                    modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)
            }
            UserDefaults.standard.set(true, forKey: UDKey.squadDefaultApplied)
            save()
        }
    }

    func save() {
        let enc = JSONEncoder()
        UserDefaults.standard.set(try? enc.encode(approve),       forKey: UDKey.approve)
        UserDefaults.standard.set(try? enc.encode(deny),          forKey: UDKey.deny)
        UserDefaults.standard.set(try? enc.encode(hide),          forKey: UDKey.hide)
        UserDefaults.standard.set(try? enc.encode(alwaysApprove), forKey: UDKey.alwaysApprove)
        UserDefaults.standard.set(try? enc.encode(chat),          forKey: UDKey.chat)
        UserDefaults.standard.set(try? enc.encode(squad),         forKey: UDKey.squad)
    }

    private func load() {
        let dec = JSONDecoder()
        approve       = (UserDefaults.standard.data(forKey: UDKey.approve))
            .flatMap { try? dec.decode(KeyShortcut.self, from: $0) }
        deny          = (UserDefaults.standard.data(forKey: UDKey.deny))
            .flatMap { try? dec.decode(KeyShortcut.self, from: $0) }
        hide          = (UserDefaults.standard.data(forKey: UDKey.hide))
            .flatMap { try? dec.decode(KeyShortcut.self, from: $0) }
        alwaysApprove = (UserDefaults.standard.data(forKey: UDKey.alwaysApprove))
            .flatMap { try? dec.decode(KeyShortcut.self, from: $0) }
        chat          = (UserDefaults.standard.data(forKey: UDKey.chat))
            .flatMap { try? dec.decode(KeyShortcut.self, from: $0) }
        squad         = (UserDefaults.standard.data(forKey: UDKey.squad))
            .flatMap { try? dec.decode(KeyShortcut.self, from: $0) }
    }
}
