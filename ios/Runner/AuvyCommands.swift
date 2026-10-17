import AppIntents
import Flutter
import UIKit

/// The iOS side of `com.auvy.app/commands` (see app_commands.dart).
///
/// Commands arrive from Siri and the Shortcuts app (AuvyIntents.swift), the
/// widgets' and Control Center's buttons (AuvyPlaybackIntents.swift), the icon's
/// long-press menu and `auvy://` links. Each is a name and arguments. One that
/// arrives before Dart is listening is held until Dart says "ready", and dropped
/// if that takes more than a minute and a half, so a Siri request the user gave
/// up on can't start music the next time Auvy opens.
///
/// Registered as a scene plugin, so links and quick actions reach it alongside
/// the other plugins (Google sign-in reads its own links the same way).
final class AuvyCommands: NSObject, FlutterSceneLifeCycleDelegate {

    static let shared = AuvyCommands()

    /// The user's playlist names, kept for Siri's playlist picker, which can be
    /// asked with Auvy closed.
    static let playlistsKey = "auvy.commands.playlists"

    private var channel: FlutterMethodChannel?
    private var dartReady = false
    private var pending: [(id: UUID, command: String, args: [String: Any], at: Date)] = []
    private var readyWaiters: [() -> Void] = []
    private static let pendingLifetime: TimeInterval = 90

    /// When Dart said ready, and the last command an intent delivered: iOS can
    /// deliver ONE widget tap twice around a cold start (seen on the phone,
    /// 2026-10-16, after the held copy was already dropped on timeout: two
    /// "togglePlay from widget" 0.67 s apart, so it played and paused at once).
    /// The same command again within two seconds, in the first seconds after
    /// start-up, is that repeat.
    private var readyAt: Date?
    private var lastIntent: (key: String, at: Date)?

    private static func intentKey(_ command: String, _ args: [String: Any]) -> String {
        command + "|" + args.keys.sorted().map { "\($0)=\(args[$0] ?? "")" }.joined(separator: "&")
    }

    /// Whether [key] repeats what an intent just delivered, around start-up.
    /// Records it otherwise.
    private func isLaunchRepeat(_ key: String, now: Date = Date()) -> Bool {
        if let ready = readyAt, now.timeIntervalSince(ready) < 6,
           let last = lastIntent, last.key == key, now.timeIntervalSince(last.at) < 2 {
            return true
        }
        lastIntent = (key, now)
        return false
    }

    func attach(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "com.auvy.app/commands", binaryMessenger: messenger)
        ch.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = ch
        dartReady = false
        AuvyIntentRouter.run = { command, args in
            await AuvyCommands.shared.runFromIntent(command, args)
        }
        AuvyIntentRouter.openAppError = { intent in
            if #available(iOS 17.0, *), let continuable = intent as? any ForegroundContinuableIntent {
                return continuable.needsToContinueInForegroundError("Auvy needs to open to do that.")
            }
            return AuvyIntentError.openAuvy
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "ready":
            dartReady = true
            readyAt = Date()
            let fresh = pending.filter { Date().timeIntervalSince($0.at) < Self.pendingLifetime }
            pending.removeAll()
            var out: [[String: Any]] = []
            var seen: [String: Date] = [:]
            for entry in fresh {
                // One tap held twice (see readyAt) runs once.
                let key = Self.intentKey(entry.command, entry.args)
                if let earlier = seen[key], entry.at.timeIntervalSince(earlier) < 2 { continue }
                seen[key] = entry.at
                lastIntent = (key, Date())
                var args = entry.args
                args["held"] = true
                out.append(["command": entry.command, "args": args])
            }
            result(out)
            let waiters = readyWaiters
            readyWaiters.removeAll()
            waiters.forEach { $0() }
        case "setPlaylists":
            let names = args["names"] as? [String] ?? []
            UserDefaults.standard.set(names, forKey: Self.playlistsKey)
            if #available(iOS 17.0, *) {
                AuvyShortcuts.updateAppShortcutParameters()
            }
            result(nil)
        case "clipboardHint":
            // Whether something that looks like a web link was copied, WITHOUT
            // reading it: detectPatterns doesn't show iOS's paste prompt. The
            // change count says whether it's still the copy already offered.
            let board = UIPasteboard.general
            let changeCount = board.changeCount
            guard board.hasStrings || board.hasURLs else {
                result(["changeCount": changeCount, "hasURL": false])
                return
            }
            board.detectPatterns(for: [.probableWebURL]) { found in
                let hasURL = (try? found.get())?.contains(.probableWebURL) ?? false
                DispatchQueue.main.async {
                    result(["changeCount": changeCount, "hasURL": hasURL])
                }
            }
        case "pinPlaylist", "openLinkSettings":
            // Android's: home-screen playlist shortcuts and "Open by default". On
            // iPhone, Siri and the Shortcuts app do these jobs.
            result(false)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Sends a command now, or holds it until Dart is ready. For links and quick
    /// actions, which need no answer.
    func run(_ command: String, _ args: [String: Any]) {
        DispatchQueue.main.async {
            if let ch = self.channel, self.dartReady {
                ch.invokeMethod("run", arguments: ["command": command, "args": args])
            } else {
                self.pending.append((UUID(), command, args, Date()))
            }
        }
    }

    /// For an App Intent: delivers the command and waits for Dart's answer, so
    /// Siri can say what happened. When Auvy isn't running, iOS starts the
    /// process for the intent but not the screen, and with no screen there is no
    /// Flutter engine; after a short wait the intent asks to open Auvy, and iOS
    /// runs the intent again once it has (the held copy is dropped, so the
    /// command runs once).
    func runFromIntent(_ command: String, _ args: [String: Any]) async -> AuvyIntentOutcome {
        let repeated = await MainActor.run { () -> Bool in
            guard self.dartReady else { return false }
            return self.isLaunchRepeat(Self.intentKey(command, args))
        }
        if repeated { return .done(nil) }
        switch await waitForDart(seconds: 3, queueing: (command, args)) {
        case .timedOut:
            return .needsApp
        case .tookQueued:
            // Dart came up during the wait and ran it from the held list.
            return .done(nil)
        case .ready:
            break
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                guard let ch = self.channel else {
                    continuation.resume(returning: .needsApp)
                    return
                }
                var answered = false
                let finish: (String?) -> Void = { message in
                    guard !answered else { return }
                    answered = true
                    continuation.resume(returning: .done(message))
                }
                ch.invokeMethod("run", arguments: ["command": command, "args": args]) { reply in
                    finish(reply as? String)
                }
                // A long link can take a while to match; Siri gets an answer anyway.
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { finish(nil) }
            }
        }
    }

    private enum DartWait { case ready, tookQueued, timedOut }

    /// Whether Dart is listening. If not, [queueing] is held for it: Dart takes
    /// it on "ready" if that comes within the wait. If the wait runs out it is
    /// dropped: the intent then asks iOS to open Auvy, and iOS runs it again.
    private func waitForDart(seconds: Double, queueing: (String, [String: Any])) async -> DartWait {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                if self.channel != nil && self.dartReady {
                    continuation.resume(returning: .ready)
                    return
                }
                let entry = UUID()
                self.pending.append((entry, queueing.0, queueing.1, Date()))
                var done = false
                self.readyWaiters.append {
                    guard !done else { return }
                    done = true
                    continuation.resume(returning: .tookQueued)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    guard !done else { return }
                    done = true
                    // The intent now asks iOS to open Auvy, and iOS runs the intent
                    // AGAIN once it has. The held copy goes, or the command runs
                    // twice: seen on the phone (2026-10-16), one widget tap on a
                    // closed app played then paused at once.
                    self.pending.removeAll { $0.id == entry }
                    continuation.resume(returning: .timedOut)
                }
            }
        }
    }

    // MARK: - auvy:// links

    /// `auvy://open?url=<link>`, `auvy://play`, `auvy://pause`, `auvy://toggle`,
    /// `auvy://next`, `auvy://previous`, `auvy://search?q=<words>`,
    /// `auvy://collection/liked?shuffle=1`, `auvy://playlist?name=<name>`.
    /// For Shortcuts automations and other apps.
    @discardableResult
    func handle(url: URL) -> Bool {
        // Any app or web page can open an auvy:// link, so it carries only
        // short values: a link, search words or a list name, never more.
        guard url.scheme?.lowercased() == "auvy", url.absoluteString.count <= 4096 else { return false }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") }
                .filter { $0.1.count <= 2048 },
            uniquingKeysWith: { first, _ in first })
        let truthy: (String?) -> Bool = { ["1", "true", "yes"].contains(($0 ?? "").lowercased()) }
        switch url.host?.lowercased() ?? "" {
        case "open", "link":
            guard let link = query["url"], !link.isEmpty,
                  let scheme = URL(string: link)?.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else { return false }
            run("openLink", ["url": link, "from": "link"])
        case "play", "resume":
            run("play", ["from": "link"])
        case "pause":
            run("pause", ["from": "link"])
        case "toggle":
            run("togglePlay", ["from": "link"])
        case "nowplaying":
            // The widget's song: where it's playing from (see the main layout).
            run("openNowPlaying", ["from": "widget"])
        case "next":
            run("next", ["from": "link"])
        case "previous":
            run("previous", ["from": "link"])
        case "search":
            if let q = query["q"], !q.isEmpty, q.count <= 200 {
                run("searchPlay", ["query": q, "from": "link"])
            } else {
                run("openSearch", ["from": "link"])
            }
        case "collection":
            let id = url.pathComponents.dropFirst().first ?? query["id"] ?? ""
            guard !id.isEmpty, id.count <= 64 else { return false }
            run("playCollection", ["id": id, "shuffle": truthy(query["shuffle"]), "from": "link"])
        case "playlist":
            guard let name = query["name"], !name.isEmpty, name.count <= 200 else { return false }
            run("playPlaylist", ["name": name, "shuffle": truthy(query["shuffle"]), "from": "link"])
        default:
            return false
        }
        return true
    }

    // MARK: - The icon's long-press menu

    static func installQuickActions() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(
                type: "auvy.liked", localizedTitle: "Liked Songs", localizedSubtitle: "Shuffle",
                icon: UIApplicationShortcutIcon(systemImageName: "heart.fill")),
            UIApplicationShortcutItem(
                type: "auvy.weekly", localizedTitle: "Weekly Discovery", localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "sparkles")),
            UIApplicationShortcutItem(
                type: "auvy.top50", localizedTitle: "My Top 50", localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "chart.bar.fill")),
            UIApplicationShortcutItem(
                type: "auvy.search", localizedTitle: "Search", localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "magnifyingglass")),
        ]
    }

    @discardableResult
    func handle(shortcut: UIApplicationShortcutItem) -> Bool {
        switch shortcut.type {
        case "auvy.liked": run("playCollection", ["id": "liked", "shuffle": true, "from": "shortcut"])
        case "auvy.weekly": run("playCollection", ["id": "weekly", "from": "shortcut"])
        case "auvy.top50": run("playCollection", ["id": "top50", "from": "shortcut"])
        case "auvy.search": run("openSearch", ["from": "shortcut"])
        default: return false
        }
        return true
    }

    // MARK: - FlutterSceneLifeCycleDelegate

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions?) -> Bool {
        guard let options = connectionOptions else { return false }
        var handled = false
        if let shortcut = options.shortcutItem { handled = handle(shortcut: shortcut) || handled }
        for context in options.urlContexts where context.url.scheme?.lowercased() == "auvy" {
            handled = handle(url: context.url) || handled
        }
        return handled
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
        var handled = false
        for context in URLContexts where context.url.scheme?.lowercased() == "auvy" {
            handled = handle(url: context.url) || handled
        }
        return handled
    }

    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) -> Bool {
        let handled = handle(shortcut: shortcutItem)
        if handled { completionHandler(true) }
        return handled
    }
}
