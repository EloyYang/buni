import Foundation
import AppKit
import CryptoKit

/// 앱 안에서 새 버전을 내려받아 설치하고 다시 시작한다.
/// GitHub 릴리스의 macOS zip을 받아 → 무결성(sha256)·번들 ID·버전을 확인하고 → 앱이 종료된 뒤
/// 보조 스크립트가 지금 앱을 새 앱으로 바꿔 다시 연다. 어느 단계든 실패하면 지금 앱은 그대로 둔다.
final class SelfUpdater: NSObject, URLSessionDownloadDelegate {
    static let shared = SelfUpdater()

    private static let apiURL = "https://api.github.com/repos/EloyYang/buni/releases/latest"

    struct Release {
        let version: String
        let zipURL: URL
        let sha256: String?
    }

    enum Failure: LocalizedError {
        case noAsset, download(String), checksum, badBundle(String), notReplaceable, script(String)
        var errorDescription: String? {
            switch self {
            case .noAsset:        return L.t("릴리스에서 내려받을 파일을 찾지 못했어요.", "Couldn't find a download in the release.")
            case .download(let m): return L.t("내려받지 못했어요: ", "Download failed: ") + m
            case .checksum:       return L.t("내려받은 파일이 올바르지 않아요(체크섬 불일치).", "The downloaded file is corrupted (checksum mismatch).")
            case .badBundle(let m): return L.t("받은 앱을 확인하지 못했어요: ", "Couldn't verify the downloaded app: ") + m
            case .notReplaceable: return L.t("이 위치의 앱은 바꿀 수 없어요. 직접 설치해 주세요.", "This copy of the app can't be replaced automatically.")
            case .script(let m):  return L.t("설치를 시작하지 못했어요: ", "Couldn't start the install: ") + m
            }
        }
    }

    private var session: URLSession!
    private var release: Release?
    private var workDir: URL?
    private var progress: ((String) -> Void)?
    private var completion: ((Failure?) -> Void)?
    private(set) var isRunning = false

    private override init() {
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
    }

    // MARK: - 시작

    /// progress: 메뉴에 보일 진행 문구. completion: 실패하면 이유 (성공하면 앱이 곧 종료·재시작된다)
    func start(expectedVersion: String, progress: @escaping (String) -> Void, completion: @escaping (Failure?) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        self.progress = progress
        self.completion = completion
        progress(L.t("⬇ 업데이트 준비 중…", "⬇ Preparing update…"))

        guard Self.canReplaceRunningApp else { return finish(.notReplaceable) }

        var req = URLRequest(url: URL(string: Self.apiURL)!, cachePolicy: .reloadIgnoringLocalCacheData)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        session.dataTask(with: req) { [weak self] data, _, error in
            guard let self else { return }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                return self.finish(.download(error?.localizedDescription ?? "release info"))
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard version == expectedVersion || version.compare(expectedVersion, options: .numeric) == .orderedDescending else {
                return self.finish(.download("version"))
            }
            let assets = json["assets"] as? [[String: Any]] ?? []
            guard let asset = assets.first(where: {
                      let n = ($0["name"] as? String ?? "").lowercased(); return n.hasSuffix(".zip") && n.contains("macos") }),
                  let urlStr = asset["browser_download_url"] as? String, let url = URL(string: urlStr),
                  url.scheme == "https" else { return self.finish(.noAsset) }
            var sha: String? = nil
            if let d = asset["digest"] as? String, d.hasPrefix("sha256:") { sha = String(d.dropFirst(7)).lowercased() }
            self.release = Release(version: version, zipURL: url, sha256: sha)
            self.session.downloadTask(with: url).resume()
        }.resume()
    }

    /// 지금 실행 중인 앱을 같은 자리에서 바꿀 수 있는지 (AppTranslocation 격리 경로·읽기 전용 위치는 불가)
    static var canReplaceRunningApp: Bool {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app", !url.path.contains("/AppTranslocation/") else { return false }
        return FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    // MARK: - 내려받기

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        guard total > 0 else { return }
        let pct = Int(Double(written) / Double(total) * 100)
        progress?(L.t("⬇ 업데이트 내려받는 중… \(pct)%", "⬇ Downloading update… \(pct)%"))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 이 콜백이 끝나면 임시 파일이 지워지므로 여기서 바로 옮겨 둔다
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buni-update-\(UUID().uuidString)")
        let zip = dir.appendingPathComponent("Buni.zip")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: zip)
        } catch { return finish(.download(error.localizedDescription)) }
        workDir = dir
        progress?(L.t("⚙ 확인하고 설치하는 중…", "⚙ Verifying and installing…"))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.verifyAndInstall(zip: zip, dir: dir) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, task is URLSessionDownloadTask { finish(.download(error.localizedDescription)) }
    }

    // MARK: - 확인 · 설치

    private func verifyAndInstall(zip: URL, dir: URL) {
        do {
            if let want = release?.sha256, try Self.sha256(of: zip) != want { throw Failure.checksum }

            let out = dir.appendingPathComponent("unzipped")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path]) == 0 else { throw Failure.badBundle("unzip") }
            let app = out.appendingPathComponent("Buni.app")
            guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
                throw Failure.badBundle("Info.plist")
            }
            guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw Failure.badBundle("bundle id") }
            if let v = release?.version, info["CFBundleShortVersionString"] as? String != v { throw Failure.badBundle("version") }
            guard Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else { throw Failure.badBundle("signature") }

            // 앱이 종료된 뒤에 바꿔치기하는 보조 스크립트
            let script = dir.appendingPathComponent("apply.sh")
            try Self.applyScript.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), app.path, Bundle.main.bundlePath, dir.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { throw Failure.script(error.localizedDescription) }

            DispatchQueue.main.async { [weak self] in
                self?.finish(nil)
                NSApp.terminate(nil)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in self?.finish((error as? Failure) ?? .badBundle(error.localizedDescription)) }
        }
    }

    private func finish(_ failure: Failure?) {
        isRunning = false
        if failure != nil, let dir = workDir { try? FileManager.default.removeItem(at: dir) }
        workDir = nil
        let done = completion
        completion = nil; progress = nil
        DispatchQueue.main.async { done?(failure) }
    }

    // MARK: - 도우미

    private static func sha256(of url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    /// $1 = 지금 앱의 pid, $2 = 새 앱, $3 = 지금 앱 자리, $4 = 임시 폴더
    private static let applyScript = """
    #!/bin/bash
    PID="$1"; SRC="$2"; DST="$3"; WORK="$4"
    for i in $(seq 1 80); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
    BAK="${DST}.old-$$"
    if mv "$DST" "$BAK"; then
      if /usr/bin/ditto "$SRC" "$DST"; then
        /usr/bin/xattr -dr com.apple.quarantine "$DST" 2>/dev/null
        rm -rf "$BAK"
      else
        rm -rf "$DST"; mv "$BAK" "$DST"
      fi
    fi
    /usr/bin/open "$DST"
    rm -rf "$WORK"
    """
}
