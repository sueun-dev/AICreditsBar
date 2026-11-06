import Foundation

// Drives the updater's checks on real files for Tests/updater/run.sh.
//   verify <app> [team]     exit 0 when the app is AICreditsBar signed by the team
//   stage <zip> <version>   prints "ok" or the reason the download is refused

let args = CommandLine.arguments
switch (args.count > 1 ? args[1] : "", args.count) {
case ("verify", 3...4):
    let app = URL(fileURLWithPath: args[2])
    exit(isSignedByPublisher(app, team: args.count == 4 ? args[3] : Updater.publisherTeam) ? 0 : 1)
case ("stage", 4):
    do {
        let body = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let app = try stageDownload((200, body), version: args[3])
        try FileManager.default.removeItem(at: app.deletingLastPathComponent())
        print("ok")
    } catch {
        print((error as? UsageError)?.message ?? "\(error)")
        exit(1)
    }
default:
    fputs("usage: updater-check verify <app> [team] | stage <zip> <version>\n", stderr)
    exit(2)
}
