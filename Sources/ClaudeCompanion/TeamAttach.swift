import SwiftUI
import AppKit
import UniformTypeIdentifiers

// 스쿼드 채팅 첨부 — 입력창 옆 📎 · 보내기 전 칩(× 로 빼기) · 말풍선의 파일 이름/이미지 썸네일 · 누르면 크게 보기.
// 상한·점검·문구는 엔진(windows/buni_team.py 의 attach_check · store_attachments)과 같다. 실제 복사·프롬프트 연결은 엔진이 한다.

/// 채팅 기록(chat.jsonl)의 첨부 한 건 — path 는 작업 폴더(jobs/<id>/) 기준 상대경로 `attachments/이름`
struct TeamAttachment: Equatable, Hashable {
    var name: String
    var path: String
    var kind: String          // image / file
    var size: Int
}

struct TeamAttachError: Error { let message: String }

enum TeamAttach {
    static let maxFiles = 5                               // 메시지 하나에 붙일 수 있는 개수
    static let maxBytes = 20 * 1024 * 1024                // 파일 하나의 크기 (20MB)
    static let imageExt: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic"]
    static let fileExt: Set<String> = [
        "txt", "md", "markdown", "json", "csv", "tsv", "log", "pdf", "html", "htm", "css", "js", "ts", "tsx", "jsx", "py", "swift",
        "java", "kt", "go", "rs", "c", "h", "cpp", "cs", "rb", "php", "sh", "bat", "ps1", "sql", "xml", "yaml", "yml", "toml",
        "ini", "cfg", "conf", "plist", "rtf", "docx", "xlsx", "pptx", "svg", "zip"]
    static let blockedExt: Set<String> = ["exe", "dll", "msi", "app", "dmg", "pkg", "com", "scr", "jar", "apk", "so", "dylib"]
    private static let secretRegex = try! NSRegularExpression(
        pattern: #"(^\.env($|\.)|\.pem$|\.key$|\.p12$|\.pfx$|\.keystore$|^id_(rsa|dsa|ecdsa|ed25519)|credentials|secret|password|passwd|private[-_ ]?key|\.kdbx$)"#,
        options: [.caseInsensitive])
    static var tooMany: String { "한 번에 최대 \(maxFiles)개까지 첨부할 수 있어요" }

    static func isSecretName(_ name: String) -> Bool {
        secretRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    static func isImage(_ url: URL) -> Bool { imageExt.contains(url.pathExtension.lowercased()) }

    struct Checked { var kind: String; var size: Int; var warn: String }

    /// 보내기 전에 파일 하나를 점검한다 — 안 되는 파일이면 이유를 담아 던진다 (엔진 `attach_check` 와 같은 순서·문구)
    static func check(_ url: URL) throws -> Checked {
        let name = url.lastPathComponent
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw TeamAttachError(message: "'\(name)' 파일을 찾지 못했어요")
        }
        if isDir.boolValue { throw TeamAttachError(message: "'\(name)' 은(는) 폴더라서 첨부할 수 없어요 (파일만 가능해요)") }
        let ext = url.pathExtension.lowercased()
        if blockedExt.contains(ext) { throw TeamAttachError(message: "'\(name)' 은(는) 실행 파일이라 첨부할 수 없어요") }
        let secret = isSecretName(name)                    // .env · 개인키 같은 이름은 막지 않고 경고만 한다
        if !secret && !imageExt.contains(ext) && !fileExt.contains(ext) {
            throw TeamAttachError(message: "'\(name)' 은(는) 지원하지 않는 종류예요 (이미지·문서·코드·텍스트 파일만 가능해요)")
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
        if size > maxBytes {
            throw TeamAttachError(message: "'\(name)' 은(는) \(String(format: "%.1f", Double(size) / 1048576))MB 라서 너무 커요 (파일당 최대 \(maxBytes / 1048576)MB)")
        }
        let warn = secret ? "'\(name)' 은(는) 비밀값(키·비밀번호)이 들어 있을 수 있는 파일 이름이에요 — 보내도 되는지 확인하세요" : ""
        return Checked(kind: imageExt.contains(ext) ? "image" : "file", size: size, warn: warn)
    }

    /// 새로 고른 파일들을 보내기 전 목록에 합친다 — 통과한 것만 올리고, 안 되는 이유·경고는 note 로 돌려준다
    static func merge(_ new: [URL], into files: [URL]) -> (files: [URL], note: String?) {
        var out = files, notes: [String] = []
        for u in new {
            if out.contains(u) { continue }
            if out.count >= maxFiles { notes.append(tooMany); break }
            do {
                let c = try check(u)
                if !c.warn.isEmpty { notes.append(c.warn) }
                out.append(u)
            } catch let e as TeamAttachError { notes.append(e.message) } catch {}
        }
        return (out, notes.isEmpty ? nil : notes.joined(separator: "\n"))
    }

    /// 기록의 상대경로를 실제 파일로 — 첨부 폴더 밖이거나 없으면 nil (엔진 `attachment_path` 와 같다)
    static func absolutePath(jobId: String, rel: String) -> URL? {
        let r = rel.replacingOccurrences(of: "\\", with: "/")
        guard r.hasPrefix("attachments/"), !r.split(separator: "/").contains("..") else { return nil }
        let dir = TeamStore.jobsDir.appendingPathComponent(jobId, isDirectory: true)
        let base = dir.appendingPathComponent("attachments", isDirectory: true).resolvingSymlinksInPath()
        let full = dir.appendingPathComponent(r).resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard full.path.hasPrefix(base.path + "/"), FileManager.default.fileExists(atPath: full.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return full
    }

    static func sizeText(_ n: Int) -> String {
        n >= 1048576 ? String(format: "%.1fMB", Double(n) / 1048576) : "\(max(1, Int((Double(n) / 1024).rounded())))KB"
    }

    static var hint: String {
        L.t(" · 📎 파일·이미지 첨부 (최대 \(maxFiles)개, 파일당 \(maxBytes / 1048576)MB)",
            " · 📎 attach files/images (up to \(maxFiles), \(maxBytes / 1048576)MB each)")
    }

    // MARK: 고르기 · 끌어다 놓기 · 붙여넣기

    @MainActor
    static func pick() -> [URL] {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.message = L.t("첨부할 파일 선택", "Choose files to attach")
        return p.runModal() == .OK ? p.urls : []
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock(); var urls: [URL] = []
        func add(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
    }

    /// 끌어다 놓은 항목에서 파일 주소를 읽는다
    static func loadURLs(_ providers: [NSItemProvider], done: @escaping ([URL]) -> Void) {
        let box = Box(), group = DispatchGroup()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { box.add(u) }
                else if let u = item as? URL { box.add(u) }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(box.urls) }
    }

    /// 클립보드에 복사한 파일이나 이미지(스크린샷 등)가 있으면 첨부할 파일 주소로 — 글만 있으면 빈 배열
    static func pasteboardFiles() -> [URL] {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls
        }
        guard pb.string(forType: .string) == nil, let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return [] }
        let f = DateFormatter(); f.dateFormat = "HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("붙여넣은-이미지-\(f.string(from: Date())).png")
        return (try? png.write(to: url)) != nil ? [url] : []
    }
}

/// 보내기 전 첨부 목록 — 메모리에만 둔다 (방·화면을 옮겨 다녀도 남고, 입력 중 디스크를 건드리지 않는다)
final class TeamAttachPending {
    static let shared = TeamAttachPending()
    private var items: [String: [URL]] = [:]
    func get(_ key: String) -> [URL] { items[key] ?? [] }
    func set(_ key: String, _ urls: [URL]) { items[key] = urls.isEmpty ? nil : urls }
}

// MARK: - 이미지 썸네일 · 크게 보기

enum AttachThumb {
    private static let cache = NSCache<NSString, NSImage>()

    /// 한 변이 maxPx 이하인 썸네일 (한 번 만들어 두고 다시 쓴다 — 말풍선이 다시 그려져도 파일을 다시 읽지 않는다)
    static func image(_ url: URL, maxPx: Int) -> NSImage? {
        let key = "\(url.path)|\(maxPx)" as NSString
        if let c = cache.object(forKey: key) { return c }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPx * 2,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        cache.setObject(img, forKey: key)
        return img
    }
}

@MainActor
enum ImagePreview {
    private static var windows: [NSWindow] = []

    /// 이미지를 화면에 맞춰 크게 보여 준다 (못 읽는 형식이면 기본 앱으로 연다)
    static func show(_ url: URL) {
        guard let img = NSImage(contentsOf: url), img.size.width > 0 else { NSWorkspace.shared.open(url); return }
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let scale = min(1, screen.width * 0.8 / img.size.width, screen.height * 0.8 / img.size.height)
        let size = NSSize(width: max(240, img.size.width * scale), height: max(160, img.size.height * scale))
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = url.lastPathComponent
        win.isReleasedWhenClosed = false
        let v = NSImageView(frame: NSRect(origin: .zero, size: size))
        v.image = img
        v.imageScaling = .scaleProportionallyUpOrDown
        v.autoresizingMask = [.width, .height]
        win.contentView = v
        win.center()
        windows.append(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 화면 조각

/// 입력창 위의 칩 줄 — 보내기 전 첨부를 보여 주고 × 로 뺀다. 안 되는 파일의 이유·경고는 아래에 빨갛게.
struct AttachChips: View {
    @Binding var files: [URL]
    @Binding var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(files, id: \.self) { u in chip(u) }
                    }
                }
            }
            if let note {
                Text("⚠️ " + note).font(.system(size: 10.5)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { self.note = nil }
            }
        }
    }

    private func chip(_ u: URL) -> some View {
        let warn = TeamAttach.isSecretName(u.lastPathComponent)
        let name = u.lastPathComponent.count > 24 ? String(u.lastPathComponent.prefix(23)) + "…" : u.lastPathComponent
        return HStack(spacing: 4) {
            Text((warn ? "⚠️ " : "") + (TeamAttach.isImage(u) ? "🖼 " : "📎 ") + name)
                .font(.system(size: 11)).foregroundColor(warn ? .orange : .primary)
            Button { files.removeAll { $0 == u } } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundColor(.buniDim)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: BuniTheme.rSm).fill(Color.buniRaised))
        .overlay(RoundedRectangle(cornerRadius: BuniTheme.rSm).stroke(warn ? Color.orange : Color.buniLine, lineWidth: 1))
    }
}

/// 📎 버튼 — 파일 선택 창을 열어 고른 것을 보내기 전 목록에 합친다
struct AttachPickButton: View {
    @Binding var files: [URL]
    @Binding var note: String?

    var body: some View {
        Button {
            let r = TeamAttach.merge(TeamAttach.pick(), into: files)
            files = r.files; note = r.note
        } label: {
            Image(systemName: "paperclip").font(.system(size: 13, weight: .semibold)).foregroundColor(.buniDim)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(L.t("파일·이미지 첨부", "Attach files or images"))
        .padding(.bottom, 3)
    }
}

/// 말풍선 아래 첨부 — 이미지는 썸네일(누르면 크게), 파일은 이름·크기(누르면 열기)
struct AttachmentStrip: View {
    let jobId: String
    let items: [TeamAttachment]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.prefix(TeamAttach.maxFiles), id: \.self) { a in one(a) }
            }
            .padding(.top, 3)
        }
    }

    @ViewBuilder
    private func one(_ a: TeamAttachment) -> some View {
        if let url = TeamAttach.absolutePath(jobId: jobId, rel: a.path) {
            if a.kind == "image", let img = AttachThumb.image(url, maxPx: 160) {
                Button { ImagePreview.show(url) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 160, maxHeight: 120)
                            .clipShape(RoundedRectangle(cornerRadius: BuniTheme.rSm))
                            .overlay(RoundedRectangle(cornerRadius: BuniTheme.rSm).stroke(Color.buniLine, lineWidth: 1))
                        Text("🖼 \(a.name) · \(TeamAttach.sizeText(a.size))").font(.system(size: 10.5)).foregroundColor(.buniInfo)
                    }
                }.buttonStyle(.plain)
            } else {
                Button { NSWorkspace.shared.open(url) } label: {
                    Text("📎 \(a.name) · \(TeamAttach.sizeText(a.size))").font(.system(size: 11.5, weight: .semibold)).foregroundColor(.buniInfo)
                }.buttonStyle(.plain)
            }
        } else {
            Text("📎 \(a.name) " + L.t("(파일을 찾을 수 없어요)", "(file not found)")).font(.system(size: 10.5)).foregroundColor(.buniDim)
        }
    }
}
