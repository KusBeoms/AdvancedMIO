import AppKit
import MIOCore
import SwiftUI

/// Checks GitHub Releases for a newer build, downloads it in the background and, when the user agrees,
/// swaps the app bundle in place and relaunches. Only works for a real `.app` in a writable folder.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "KusBeoms/AdvancedMIO"
    private static let enabledKey = "autoUpdate"
    private static let checkInterval: TimeInterval = 6 * 3600

    enum State: Equatable {
        case idle, checking, upToDate
        case downloading(String)
        case ready(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var enabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true

    private var staged: URL?
    private var loop: Task<Void, Never>?

    let currentVersion = AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? AppVersion("0")!
    var isSupported: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Starts the periodic background check (first check shortly after launch).
    func start() {
        guard isSupported, enabled, loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                guard let self else { return }
                await self.check(manual: false)
                try? await Task.sleep(for: .seconds(Self.checkInterval))
            }
        }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else { loop?.cancel(); loop = nil }
    }

    func checkNow() { Task { await check(manual: true) } }

    private func check(manual: Bool) async {
        guard isSupported else {
            if manual { state = .failed("빌드한 AdvancedMIO.app으로 실행할 때만 업데이트할 수 있습니다.") }
            return
        }
        switch state {
        case .checking, .downloading, .ready: return
        default: break
        }
        state = .checking
        do {
            guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UpdateError.message("응답을 확인하지 못했습니다.") }
            if http.statusCode == 404 {
                state = manual ? .upToDate : .idle      // no published release yet (or private repo)
                return
            }
            guard http.statusCode == 200 else { throw UpdateError.message("서버 응답 오류 (\(http.statusCode))") }
            guard let release = ReleaseFeed.parse(data), release.version > currentVersion else {
                state = manual ? .upToDate : .idle
                return
            }
            try await stage(release)
        } catch {
            state = manual ? .failed("업데이트 확인 실패: \(Self.describe(error))") : .idle
        }
    }

    private func stage(_ release: ReleaseInfo) async throws {
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError.message("앱이 있는 폴더에 쓸 수 없습니다. 쓰기 가능한 위치(예: /Applications)로 옮겨 주세요.")
        }
        state = .downloading(release.version.description)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("AdvancedMIO-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let (file, response) = try await URLSession.shared.download(from: release.assetURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("다운로드에 실패했습니다.") }
        let zip = work.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: file, to: zip)

        let unpacked = work.appendingPathComponent("unpacked")
        try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let app = unpacked.appendingPathComponent("AdvancedMIO.app")
        try Self.validate(app, newerThan: currentVersion)
        try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])

        staged = app
        state = .ready(release.version.description)
    }

    /// The staged bundle must be this app (same identifier and executable) and actually newer.
    private static func validate(_ app: URL, newerThan current: AppVersion) throws {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let exe = bundle.executableURL, FileManager.default.isExecutableFile(atPath: exe.path),
              let text = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let version = AppVersion(text), version > current else {
            throw UpdateError.message("내려받은 파일이 올바른 AdvancedMIO 업데이트가 아닙니다.")
        }
    }

    /// Quits, replaces the bundle and reopens it. A helper shell script outlives this process to do the swap.
    func installAndRelaunch() {
        guard case .ready = state, let staged else { return }
        let target = Bundle.main.bundleURL.path
        let script = """
        #!/bin/sh
        PID="$1"; TARGET="$2"; NEW="$3"
        i=0; while kill -0 "$PID" 2>/dev/null && [ $i -lt 60 ]; do sleep 0.5; i=$((i+1)); done
        BACKUP="$TARGET.old.$$"
        if mv "$TARGET" "$BACKUP" && /usr/bin/ditto "$NEW" "$TARGET"; then
            rm -rf "$BACKUP"
        else
            rm -rf "$TARGET"; mv "$BACKUP" "$TARGET"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        /usr/bin/open "$TARGET"
        rm -rf "$(dirname "$(dirname "$NEW")")"
        rm -f "$0"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("amio-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), target, staged.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
        } catch {
            state = .failed("업데이트를 시작하지 못했습니다: \(Self.describe(error))")
            return
        }
        NSApp.terminate(nil)
    }

    private enum UpdateError: Error { case message(String) }
    private static func describe(_ error: Error) -> String {
        if case UpdateError.message(let m) = error { return m }
        return error.localizedDescription
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw UpdateError.message("업데이트 파일 검증에 실패했습니다.") }
        }.value
    }
}

/// Shared by the main window's settings menu and the menu bar.
struct UpdateMenuItems: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Toggle("업데이트 자동 확인·다운로드", isOn: Binding(get: { updater.enabled }, set: { updater.setEnabled($0) }))
        switch updater.state {
        case .ready(let version):
            Button("v\(version)으로 업데이트하고 다시 시작") { updater.installAndRelaunch() }
        case .downloading(let version):
            Text("v\(version) 내려받는 중…")
        case .checking:
            Text("업데이트 확인 중…")
        case .upToDate:
            Button("최신 버전입니다 (v\(updater.currentVersion.description)) · 다시 확인") { updater.checkNow() }
        case .failed(let message):
            Text(message)
            Button("다시 확인") { updater.checkNow() }
        case .idle:
            Button("업데이트 확인 (v\(updater.currentVersion.description))") { updater.checkNow() }
        }
    }
}
