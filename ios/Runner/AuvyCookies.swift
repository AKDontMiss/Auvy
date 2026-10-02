import Flutter
import Foundation
import UIKit
import WebKit

/// The iOS side of `com.auvy.app/cookies`: signing in, and the cookies that
/// prove it.
///
/// The counterpart of `LoginActivity.kt` plus MainActivity's cookie handlers.
/// The Dart side (`session_auth_service.dart`) needs three things:
///
///   openLogin      -> Bool    did a session get established
///   getCookies     -> String  "k=v; k=v" for a url, INCLUDING HttpOnly cookies
///   lastLoginEmail -> String? the account picked, for the admin roster only
///
/// `SID`, `__Secure-1PSID` and `__Secure-3PSID` are HttpOnly, so
/// `document.cookie` can't see them; `WKHTTPCookieStore` can.
///
/// Unlike Android's WebView, WKWebView presents as Safari, so Google accepts
/// the sign-in without a user-agent fallback.
final class AuvyCookies: NSObject {

    static let channelName = "com.auvy.app/cookies"

    /// Hands the flow back to `music.youtube.com` once Google is done with it.
    private static let continueParam =
        "continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue"
        + "%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F"
    private static let loginURL =
        "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&passive=true&"
        + continueParam

    /// The cookie names that mean a session really exists.
    ///
    /// Matched EXACTLY, never as a substring: a test for "SID" would also match
    /// `SAPISID` and `SSID`, which are present before the real session is.
    private static let authCookieNames: Set<String> = ["SID", "__Secure-1PSID", "__Secure-3PSID"]

    private let channel: FlutterMethodChannel
    private var loginController: AuvyLoginController?

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: AuvyCookies.channelName, binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "getCookies":
            readCookies(urlString: args["url"] as? String ?? "", result: result)

        case "openLogin":
            presentLogin(result: result)

        case "lastLoginEmail":
            // Android reads the account the system chooser returned. iOS has no
            // equivalent an app may query, and the value is cosmetic — the Worker
            // derives identity from the cookies it verifies itself.
            result(nil)

        case "clearCookies":
            clearCookies(result: result)

        case "isIgnoringBatteryOptimizations":
            // Android's Doze exemption has no iOS counterpart to ask about. The
            // `audio` background mode is what keeps playback alive here, and it is
            // declared in Info.plist rather than granted by the user — so there is
            // nothing outstanding, and true is the answer that stops Dart prompting
            // for a permission that does not exist.
            result(true)

        case "requestIgnoreBatteryOptimizations":
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: Reading

    /// Every cookie the store holds for `urlString`, as the "k=v; k=v" string Dart parses.
    private func readCookies(urlString: String, result: @escaping FlutterResult) {
        guard let url = URL(string: urlString), let host = url.host else {
            result(""); return
        }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let matching = cookies.filter { AuvyCookies.cookie($0, appliesTo: host) }
            let joined = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            result(joined)
        }
    }

    /// Standard cookie-domain matching: an exact host, or a `.example.com` domain
    /// cookie that the host sits under. `.youtube.com` cookies must be returned for
    /// `music.youtube.com`, and those are the ones that carry the session.
    private static func cookie(_ cookie: HTTPCookie, appliesTo host: String) -> Bool {
        let domain = cookie.domain.lowercased()
        let host = host.lowercased()
        if domain.hasPrefix(".") {
            return host == String(domain.dropFirst()) || host.hasSuffix(domain)
        }
        return host == domain
    }

    private func clearCookies(result: @escaping FlutterResult) {
        let store = WKWebsiteDataStore.default()
        store.httpCookieStore.getAllCookies { cookies in
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                store.httpCookieStore.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) { result(true) }
        }
    }

    // MARK: Signing in

    private func presentLogin(result: @escaping FlutterResult) {
        guard let host = AuvyCookies.topViewController() else {
            result(false); return
        }
        let controller = AuvyLoginController(
            url: AuvyCookies.loginURL,
            isComplete: { cookies in
                // Only the youtube hosts count: Google sets plenty of cookies on
                // accounts.google.com long before a YouTube session exists.
                cookies.contains { AuvyCookies.authCookieNames.contains($0.name) }
            },
            completion: { [weak self] signedIn in
                self?.loginController = nil
                result(signedIn)
            })
        loginController = controller
        let nav = UINavigationController(rootViewController: controller)
        nav.modalPresentationStyle = .fullScreen
        host.present(nav, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// The sign-in screen: a plain WKWebView that watches for the session to appear.
final class AuvyLoginController: UIViewController, WKNavigationDelegate {

    private let startURL: String
    private let isComplete: ([HTTPCookie]) -> Bool
    private var completion: ((Bool) -> Void)?
    private var webView: WKWebView!
    /// Guards the single-shot result: the checks below fire on several navigation
    /// callbacks, and Dart must be answered exactly once.
    private var finished = false
    private var polls = 0

    /// The names that mean a real session — matched exactly, never as substrings.
    static let sessionCookieNames: Set<String> = ["SID", "__Secure-1PSID", "__Secure-3PSID"]

    init(url: String, isComplete: @escaping ([HTTPCookie]) -> Bool,
         completion: @escaping (Bool) -> Void) {
        self.startURL = url
        self.isComplete = isComplete
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sign in"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))

        let config = WKWebViewConfiguration()
        // The DEFAULT store, not a non-persistent one: the cookies this flow
        // establishes have to still be there when Dart reads them afterwards.
        config.websiteDataStore = WKWebsiteDataStore.default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        prepareJarThenLoad()
    }

    /// Clear Google's cookies before a new attempt: a rejected attempt (e.g. a
    /// wrong password) leaves flagged state in cookies that would block later
    /// sign-ins. Same as LoginActivity.clearJar() on Android.
    ///
    /// A surviving session is kept, so the account chooser can finish sign-in in
    /// one tap; the durable session lives in Auvy's encrypted store anyway.
    private func prepareJarThenLoad() {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            let googleSession = cookies.contains {
                $0.domain.lowercased().hasSuffix("google.com")
                    && AuvyLoginController.sessionCookieNames.contains($0.name)
            }
            if googleSession {
                self.load()
                return
            }
            // Only the sign-in origins, so an unrelated site's login survives.
            let stale = cookies.filter { cookie in
                let d = cookie.domain.lowercased()
                return d.hasSuffix("google.com") || d.hasSuffix("youtube.com")
                    || d.hasSuffix("googleusercontent.com")
            }
            let group = DispatchGroup()
            for cookie in stale {
                group.enter()
                store.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) { self.load() }
        }
    }

    private func load() {
        if let url = URL(string: startURL) {
            webView.load(URLRequest(url: url))
        }
        schedulePoll()
    }

    /// Navigation callbacks alone are not enough to see the session arrive.
    ///
    /// Cookies reach WKHTTPCookieStore asynchronously, so the check at didFinish
    /// can run before they land; and some flows park on a youtube page and never
    /// navigate again, so no later callback comes to re-check. Polling costs
    /// nothing for the seconds this screen is open and closes both gaps.
    private func schedulePoll() {
        guard !finished, polls < 600 else { return }
        polls += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, !self.finished else { return }
            self.checkForSession(self.webView.url)
            self.schedulePoll()
        }
    }

    @objc private func cancel() { finish(false) }

    // Checked on both callbacks, because some flows park on a youtube page and
    // never navigate again — waiting only for a navigation would hang there.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        checkForSession(webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkForSession(webView.url)
    }

    private func checkForSession(_ url: URL?) {
        guard !finished, let host = url?.host else { return }
        guard host.hasSuffix("youtube.com") else { return }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self, !self.finished else { return }
            let relevant = cookies.filter { $0.domain.lowercased().hasSuffix("youtube.com") }
            if self.isComplete(relevant) { self.finish(true) }
        }
    }

    private func finish(_ signedIn: Bool) {
        guard !finished else { return }
        finished = true
        let done = completion
        completion = nil
        dismiss(animated: true) { done?(signedIn) }
    }
}
