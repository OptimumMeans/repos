// githubnotify — posts a macOS notification via Apple's UserNotifications
// framework so it shows THIS app's icon (the GitHub mark). Unlike an osacompile
// applet, a real signed .app that calls UNUserNotificationCenter registers as a
// notification client, so macOS 11+ actually delivers it.
//
// Usage (must run as the bundled executable, not a loose binary):
//   GitHub Repos.app/Contents/MacOS/GitHubNotify <title> <subtitle> <body>
// Exit 0 on delivery, 1 if unauthorized/failed (callers fall back to osascript).
import Cocoa
import UserNotifications

let args = CommandLine.arguments
let title    = args.count > 1 ? args[1] : "GitHub Repos"
let subtitle = args.count > 2 ? args[2] : ""
let body     = args.count > 3 ? args[3] : ""

// UNUserNotificationCenter needs a bundle identity; refuse to run unbundled.
guard Bundle.main.bundleIdentifier != nil else {
    FileHandle.standardError.write(Data("error: must run inside the .app bundle\n".utf8))
    exit(1)
}

final class Delegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Watchdog: never hang the caller (e.g. user ignores the first-run prompt).
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(1) }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                FileHandle.standardError.write(Data("error: notifications not authorized\n".utf8))
                exit(1)
            }
            let content = UNMutableNotificationContent()
            content.title = title
            if !subtitle.isEmpty { content.subtitle = subtitle }
            content.body = body
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(req) { err in
                if err != nil { exit(1) }
                // Brief grace period so the daemon enqueues it before we exit.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            }
        }
    }
    // Present the banner even on the off chance we're frontmost.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .sound])
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon
let delegate = Delegate()
app.delegate = delegate
app.run()
