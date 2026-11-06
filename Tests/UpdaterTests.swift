import AppKit

// Updates, one section at a time, without the network or a signed build.
// Tests/updater/run.sh covers the parts that need the developer's certificate.

private func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try! process.run()
    process.waitUntilExit()
}

/// An unsigned folder shaped like AICreditsBar.app, zipped the way scripts/release.sh zips.
private func fakeReleaseZip(in folder: URL, version: String) -> Data {
    let contents = folder.appendingPathComponent("AICreditsBar.app/Contents")
    try! FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: NSDictionary = ["CFBundleIdentifier": "com.sueun.aicreditsbar", "CFBundleShortVersionString": version]
    info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
    let zip = folder.appendingPathComponent("AICreditsBar.zip")
    run("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.appendingPathComponent("AICreditsBar.app").path, zip.path])
    return try! Data(contentsOf: zip)
}

private func stagingError(_ reply: (status: Int, body: Data), version: String) -> String? {
    do { _ = try stageDownload(reply, version: version); return nil } catch { return (error as? UsageError)?.message ?? "\(error)" }
}

private func stagedFolders() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter { $0.hasPrefix("aicb-update-") }
}

func runUpdaterTests() {
    // ① Version order.
    check(isNewerVersion("v2.1", than: "2.0"), "2.1 is newer than 2.0")
    check(isNewerVersion("2.10", than: "2.9"), "versions compare as numbers, not text")
    check(isNewerVersion("3", than: "2.9.9"), "a shorter version is padded with zeros")
    check(!isNewerVersion("2.0", than: "2.0.0"), "2.0 equals 2.0.0")
    check(!isNewerVersion("1.9", than: "2.0"), "an older release is never offered")
    check(!isNewerVersion("beta", than: "2.0") && !isNewerVersion("2.1", than: ""), "non-numeric versions are ignored")

    // ② The release feed.
    let feed = Data(#"{"tag_name":"v2.1","assets":[{"name":"notes.txt","browser_download_url":"https://x/notes"},{"name":"AICreditsBar.zip","browser_download_url":"https://x/app.zip"}]}"#.utf8)
    let release = ReleaseInfo(version: "2.1", zipURL: "https://x/app.zip")
    eq(parseRelease(feed), release, "the release feed gives the version and zip")
    check(parseRelease(Data(#"{"tag_name":"v2.1","assets":[]}"#.utf8)) == nil, "a release without the zip is ignored")
    check(parseRelease(Data(#"{"tag_name":"nightly","assets":[]}"#.utf8)) == nil && parseRelease(nil) == nil, "bad feeds are ignored")

    // ③ What a check reports.
    eq(checkOutcome((200, feed), current: "2.0"), .available(release), "a newer release is offered")
    eq(checkOutcome((200, feed), current: "2.1"), .upToDate, "the same version is up to date")
    eq(checkOutcome((200, feed), current: "2.2"), .upToDate, "a newer installed build is up to date")
    eq(checkOutcome(nil, current: "2.0"), .failed("Couldn't reach GitHub."), "no reply")
    eq(checkOutcome((404, Data()), current: "2.0"), .failed("No release has been published yet."), "a repository without releases")
    eq(checkOutcome((403, Data()), current: "2.0"), .failed("GitHub answered HTTP 403. Try again later."), "GitHub's rate limit is not 'no release'")
    eq(checkOutcome((200, Data("<html>".utf8)), current: "2.0"), .failed("The latest release has no AICreditsBar.zip."), "an unreadable feed")

    // ③ When the background check runs: a day apart by the wall clock.
    let checkedAt = Date(timeIntervalSince1970: now)
    check(isCheckDue(last: nil, now: checkedAt), "never asked: due at launch")
    check(!isCheckDue(last: checkedAt, now: checkedAt.addingTimeInterval(23 * 3600)), "23 hours later: not yet")
    check(isCheckDue(last: checkedAt, now: checkedAt.addingTimeInterval(86400)), "a day later: due, however long the Mac slept")
    check(isCheckDue(last: checkedAt, now: checkedAt.addingTimeInterval(-60)), "a clock moved backwards does not stop checks")

    // ④ Only the developer's signature installs (the accepted case needs the certificate: Tests/updater/run.sh).
    check(!isSignedByPublisher(URL(fileURLWithPath: "/System/Applications/Calculator.app")), "another publisher's app is not installable")
    check(!isSignedByPublisher(URL(fileURLWithPath: "/nonexistent.app")), "a missing app is not installable")

    // ⑤ The Settings button: check, then install what the check found.
    let settings = SettingsWindow()
    let png = NSTemporaryDirectory() + "aicb-updates-\(UUID().uuidString).png"
    try? settings.renderToPNG(png)   // builds the window offscreen
    try? FileManager.default.removeItem(atPath: png)
    var checks = 0, installs = 0
    settings.onCheckUpdates = { checks += 1 }
    settings.onInstallUpdate = { installs += 1 }
    eq(settings.updateButton.title, "Check for Updates", "the button starts as a check")
    settings.updateButton.performClick(nil)
    eq([checks, installs], [1, 0], "clicking it checks")
    settings.showUpdate(nil)
    eq(settings.updateStatus.stringValue, "Checking…", "a check in progress says so")
    check(!settings.updateButton.isEnabled, "the button waits for the check to finish")
    settings.showUpdate(.available(release))
    eq(settings.updateStatus.stringValue, "Version 2.1 is available.", "a found version is named")
    eq(settings.updateButton.title, "Update to 2.1 and Restart", "the button offers the found version")
    check(settings.updateButton.isEnabled, "the found version can be installed")
    settings.updateButton.performClick(nil)
    eq([checks, installs], [1, 1], "clicking it now installs instead of checking")
    settings.showUpdate(.failed("Couldn't reach GitHub."))
    eq(settings.updateStatus.stringValue, "Couldn't reach GitHub.", "a failure says why")
    eq(settings.updateButton.title, "Check for Updates", "after a failure the button checks again")
    settings.showUpdate(.upToDate)
    eq(settings.updateStatus.stringValue, "You have the latest version.", "up to date")
    settings.updateButton.performClick(nil)
    eq([checks, installs], [2, 1], "up to date: clicking checks again")

    // ⑦ Download → unpacked app: every rejection leaves no temp folder behind.
    let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aicb-updater-test-\(UUID().uuidString)")
    let before = stagedFolders()
    let unsigned = fakeReleaseZip(in: work.appendingPathComponent("zip"), version: "9.9")
    eq(stagingError((404, unsigned), version: "9.9"), "Download failed (HTTP 404)", "an HTTP error is not unpacked")
    eq(stagingError((200, Data(count: 50_000_000)), version: "9.9"), "The download is too large to be AICreditsBar", "an oversized download is refused")
    eq(stagingError((200, Data("not a zip".utf8)), version: "9.9"), "The download is not AICreditsBar 9.9", "a corrupt zip is refused")
    eq(stagingError((200, unsigned), version: "9.8"), "The download is not AICreditsBar 9.8", "a zip holding another version is refused")
    eq(stagingError((200, unsigned), version: "9.9"), "The download is not signed by the developer, so it was not installed",
       "an unsigned app is refused")
    eq(stagedFolders(), before, "refused downloads leave no temp folder")

    // ⑧ Swapping the bundle in place.
    func fakeApp(_ folder: URL, _ marker: String) -> URL {
        let app = folder.appendingPathComponent("AICreditsBar.app")
        try! FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try! Data(marker.utf8).write(to: app.appendingPathComponent("marker"))
        return app
    }
    func marker(_ app: URL) -> String? { try? String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8) }
    let installed = fakeApp(work.appendingPathComponent("install"), "old")
    var staged = fakeApp(work.appendingPathComponent("staged-1"), "new")
    do { try replaceApp(at: installed, with: staged) } catch { check(false, "replacing the app: \(error)") }
    eq(marker(installed), "new", "the installed app is the new one")
    check(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path), "the staged folder is removed")

    // Through a symlinked folder (this checkout lives behind one).
    let link = work.appendingPathComponent("linked")
    try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: work.appendingPathComponent("install"))
    staged = fakeApp(work.appendingPathComponent("staged-2"), "newer")
    do { try replaceApp(at: link.appendingPathComponent("AICreditsBar.app"), with: staged) } catch { check(false, "replacing through a symlink: \(error)") }
    eq(marker(installed), "newer", "a symlinked install folder is updated in place")
    check((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil, "the symlink itself is kept")

    // A folder the app can't write to: the update fails and the installed app is untouched.
    let locked = installed.deletingLastPathComponent()
    staged = fakeApp(work.appendingPathComponent("staged-3"), "blocked")
    try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    var failed = false
    do { try replaceApp(at: installed, with: staged) } catch { failed = true }
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    check(failed, "an unwritable install folder is reported")
    eq(marker(installed), "newer", "a failed update leaves the installed app as it was")
    check(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path), "a failed update still removes its download")

    try? FileManager.default.removeItem(at: work)
}
