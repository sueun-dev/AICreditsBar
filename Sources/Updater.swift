import AppKit
import Security

// MARK: - Updates (GitHub Releases)

/// A published release worth installing.
struct ReleaseInfo: Equatable {
    let version: String
    let zipURL: String
}

/// "v2.1" → [2, 1]; nil unless the text is dot-separated whole numbers.
func versionParts(_ text: String) -> [Int]? {
    let pieces = text.hasPrefix("v") ? text.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
                                     : text.split(separator: ".", omittingEmptySubsequences: false)
    let numbers = pieces.compactMap { Int($0) }
    return !pieces.isEmpty && numbers.count == pieces.count ? numbers : nil
}

func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    guard var new = versionParts(candidate), var old = versionParts(current) else { return false }
    while new.count < old.count { new.append(0) }
    while old.count < new.count { old.append(0) }
    return old.lexicographicallyPrecedes(new)
}

/// The `releases/latest` JSON → the version and the AICreditsBar.zip it ships.
func parseRelease(_ data: Data?) -> ReleaseInfo? {
    guard let json = jsonObject(data), let tag = json["tag_name"] as? String, versionParts(tag) != nil,
          let assets = json["assets"] as? [[String: Any]],
          let zip = assets.first(where: { $0["name"] as? String == "AICreditsBar.zip" }),
          let url = zip["browser_download_url"] as? String else { return nil }
    return ReleaseInfo(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, zipURL: url)
}

/// True when the app is AICreditsBar signed by the developer's Apple team. Only the
/// holder of that certificate can pass, so a tampered download is never installed.
func isSignedByPublisher(_ app: URL, team: String = Updater.publisherTeam) -> Bool {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    let text = "identifier \"com.sueun.aicreditsbar\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code = code,
          SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
          let requirement = requirement else { return false }
    let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate))
    return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
}

/// Asks GitHub once a day for the latest release. When it is newer, the menu offers
/// "Update"; choosing it downloads the release, checks its signature, swaps the app
/// bundle in place and relaunches. Nothing is installed without that choice.
final class Updater {
    static let publisherTeam = "2383475YY8"
    private static let label = "com.sueun.aicreditsbar"

    private(set) var available: ReleaseInfo?
    private(set) var installing = false
    var onFailure: (String) -> Void = { _ in }

    private let feed = ProcessInfo.processInfo.environment["AICB_UPDATE_FEED"]
        ?? "https://api.github.com/repos/sueun-dev/AICreditsBar/releases/latest"
    private let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    private var timer: Timer?
    private let client: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Only a packaged app can replace itself; a bare test binary has no version.
    private var canUpdate: Bool { current != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func start() {
        stop()
        guard canUpdate else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in self?.check() }
        timer?.tolerance = 600
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func check() {
        guard let current = current, !installing else { return }
        let feed = self.feed
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let headers = ["Accept": "application/vnd.github+json", "User-Agent": userAgent]
            let reply = try? httpGet(feed, headers: headers, using: self?.client)
            let release = reply?.status == 200 ? parseRelease(reply?.body) : nil
            DispatchQueue.main.async {
                guard let self = self, !self.installing else { return }
                self.available = release.flatMap { isNewerVersion($0.version, than: current) ? $0 : nil }
            }
        }
    }

    func install() {
        guard let release = available, !installing else { return }
        installing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let staged = try self?.download(release)
                DispatchQueue.main.async { if let staged = staged { self?.replaceAndRelaunch(with: staged) } }
            } catch {
                DispatchQueue.main.async {
                    self?.installing = false
                    self?.onFailure((error as? UsageError)?.message ?? error.localizedDescription)
                }
            }
        }
    }

    /// Downloads and unpacks the release; returns the verified app inside a temp folder.
    private func download(_ release: ReleaseInfo) throws -> URL {
        let reply = try httpGet(release.zipURL, headers: ["User-Agent": userAgent], using: client, timeout: 120)
        guard reply.status == 200, reply.body.count < 50_000_000 else { throw UsageError("Download failed (HTTP \(reply.status))") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aicb-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let zip = folder.appendingPathComponent("AICreditsBar.zip")
            try reply.body.write(to: zip)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, folder.path]
            try unzip.run()
            unzip.waitUntilExit()
            let app = folder.appendingPathComponent("AICreditsBar.app")
            let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            guard unzip.terminationStatus == 0, version == release.version else { throw UsageError("The download is not AICreditsBar \(release.version)") }
            guard isSignedByPublisher(app) else { throw UsageError("The download is not signed by the developer, so it was not installed") }
            return app
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private func replaceAndRelaunch(with staged: URL) {
        let installed = Bundle.main.bundleURL
        let folder = staged.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            _ = try FileManager.default.replaceItemAt(installed, withItemAt: staged)
        } catch {
            installing = false
            onFailure("Couldn't replace the app at \(installed.path): \(error.localizedDescription)")
            return
        }
        // A login item runs under launchd, which restarts a job that exits with a failure
        // — from the replaced bundle. A hand-launched copy starts itself once this one is gone.
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == Updater.label { exit(1) }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open -n \"$1\"",
                            "sh", installed.path]
        try? helper.run()
        NSApp.terminate(nil)
    }
}
