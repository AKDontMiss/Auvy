import AVFoundation
import AVKit
import BackgroundTasks
import ImageIO
import libwebp
import Flutter
import Foundation
import UIKit
import UniformTypeIdentifiers
import UserNotifications
#if canImport(AlarmKit)
import ActivityKit
import AlarmKit
import SwiftUI
#endif

/// The small platform channels, the iOS side of what `MainActivity.kt`
/// registers besides the player.
///
/// Several are Android concepts with no iOS counterpart. Those still answer,
/// with the value that makes Dart degrade correctly (e.g. hide a control)
/// rather than one that pretends the feature worked. Each is noted at the call.
final class AuvySystemChannels: NSObject {
    /// The route kinds Dart understands, mirroring Android's currentAudioRoute.
    /// nil for anything else (AirPlay, car audio), which Dart treats as unknown.
    static func routeKind(_ port: AVAudioSession.Port?) -> String? {
        switch port {
        case .bluetoothA2DP?, .bluetoothLE?, .bluetoothHFP?: return "bluetooth"
        case .headphones?: return "headphones"
        case .usbAudio?: return "usb"
        case .HDMI?: return "hdmi"
        case .builtInSpeaker?, .builtInReceiver?: return "speaker"
        default: return nil
        }
    }


    private var channels: [FlutterMethodChannel] = []
    private var routeObserver: NSObjectProtocol?
    private var outputChannel: FlutterMethodChannel?
    private var backgroundObserver: NSObjectProtocol?
    /// The earlier of the two icon-swap moments. See observeBackgroundForIconSwap.
    private var resignObserver: NSObjectProtocol?
    /// Held here because the notification center keeps its delegate weakly.
    private let notificationDelegate = AuvyNotificationDelegate()
    /// What's New: the channel and its notifications (see AuvyWhatsNew).
    private var whatsNew: AuvyWhatsNew?

    deinit {
        if let observer = routeObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) }
        // Removed too. Adding the second observer without this is the exact leak
        // the codebase sweeps for — a listener outliving the object that made it.
        if let observer = resignObserver { NotificationCenter.default.removeObserver(observer) }
    }

    init(messenger: FlutterBinaryMessenger) {
        super.init()
        register("com.auvy.app/haptics", messenger, handler: haptics)
        register("com.auvy.app/toast", messenger, handler: toast)
        register("com.auvy.app/region", messenger, handler: region)
        register("com.auvy.app/window", messenger, handler: window)
        register("com.auvy.app/icon", messenger, handler: icon)
        register("com.auvy.app/backup", messenger, handler: backup)
        register("com.auvy.app/folder", messenger, handler: folder)
        register("com.auvy.app/widget", messenger, handler: widget)
        register("com.auvy.app/audiocapture", messenger, handler: audioCapture)
        register("com.auvy.app/alarm", messenger, handler: alarm)
        register("com.auvy.app/signing", messenger, handler: signing)
        register("com.auvy.app/image", messenger, handler: image)
        let output = register("com.auvy.app/output", messenger, handler: self.output)
        outputChannel = output
        observeBackgroundForIconSwap()
        // The reminders are delivered by iOS whether Auvy is running or not;
        // this also shows them while Auvy is open, which iOS otherwise doesn't.
        notificationDelegate.previous = UNUserNotificationCenter.current().delegate
        UNUserNotificationCenter.current().delegate = notificationDelegate
        whatsNew = AuvyWhatsNew(messenger: messenger)
    }

    @discardableResult
    private func register(_ name: String, _ messenger: FlutterBinaryMessenger,
                          handler: @escaping (FlutterMethodCall, @escaping FlutterResult) -> Void)
        -> FlutterMethodChannel {
        let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in handler(call, result) }
        channels.append(channel)
        return channel
    }

    // MARK: Haptics

    private func haptics(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard call.method == "vibrate" else { result(FlutterMethodNotImplemented); return }
        let type = (call.arguments as? [String: Any])?["type"] as? String ?? "light"
        switch type {
        case "selection":
            UISelectionFeedbackGenerator().selectionChanged()
        case "medium":
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "heavy":
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        default:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        result(nil)
    }

    // MARK: Toast

    /// Android's Toast has no iOS equivalent, so this draws the same thing: a short
    /// message over the UI that takes no input and dismisses itself.
    private func toast(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard call.method == "show" else { result(FlutterMethodNotImplemented); return }
        let args = call.arguments as? [String: Any] ?? [:]
        let message = args["message"] as? String ?? ""
        let long = args["long"] as? Bool ?? false
        guard !message.isEmpty, let host = AuvySystemChannels.keyWindow() else {
            result(nil); return
        }

        let label = PaddedLabel()
        label.text = message
        label.numberOfLines = 0
        label.textColor = .white
        label.font = .systemFont(ofSize: 14)
        label.textAlignment = .center
        label.backgroundColor = UIColor(white: 0.1, alpha: 0.92)
        label.layer.cornerRadius = 14
        label.clipsToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -64),
            label.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, multiplier: 0.86),
        ])

        UIView.animate(withDuration: 0.18) { label.alpha = 1 }
        let visible: TimeInterval = long ? 3.5 : 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + visible) {
            UIView.animate(withDuration: 0.25, animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
        }
        result(nil)
    }

    // MARK: Region

    private func region(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard call.method == "deviceRegion" else { result(FlutterMethodNotImplemented); return }
        // Dart wants a two-letter ISO code and ignores anything else.
        if #available(iOS 16.0, *) {
            result(Locale.current.region?.identifier)
        } else {
            result((Locale.current as NSLocale).object(forKey: .countryCode) as? String)
        }
    }

    // MARK: Window

    private func window(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        let enabled = args["enabled"] as? Bool ?? false
        switch call.method {
        case "keepScreenOn":
            UIApplication.shared.isIdleTimerDisabled = enabled
            result(nil)
        case "setSecure":
            // iOS has NO equivalent of FLAG_SECURE. An app cannot block the system
            // screenshot or the app-switcher snapshot, and the workarounds that
            // circulate (a secure UITextField layer) do not cover screen recording.
            // Answering false lets the setting be shown as unavailable rather than
            // appearing to protect something it does not.
            result(false)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: Alternate icon

    /// The variants that exist as declared alternates. Anything else is the stock
    /// icon — an accent with no icon of its own (the cyan default, or an
    /// artwork-derived colour) resolves to `""` in Dart and lands here as nil.
    private static let iconVariants: Set<String> = ["green", "orange", "pink", "purple", "red"]

    /// Where the WANTED variant is remembered between the accent changing and the
    /// app next leaving the foreground. UserDefaults rather than a field, so a
    /// colour picked and then followed by a force-quit is still applied on the way
    /// out — and on the next background after a cold start.
    private static let pendingIconKey = "auvy_pending_app_icon"

    private func icon(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let variant = (call.arguments as? [String: Any])?["variant"] as? String ?? ""
        switch call.method {
        case "setIcon":
            // The explicit picker: the user asked for THIS icon and is looking at
            // the screen, so it applies now and iOS shows its confirmation alert.
            applyIcon(variant) { ok in result(ok) }

        case "syncIcon":
            // Make the home-screen icon follow the accent. The swap is deferred to when
            // the app leaves the foreground: setAlternateIconName shows a system alert in
            // the foreground, and the accent picker previews live, so it would alert on
            // every change.
            let wanted = AuvySystemChannels.iconVariants.contains(variant) ? variant : ""
            UserDefaults.standard.set(wanted, forKey: AuvySystemChannels.pendingIconKey)
            result(UIApplication.shared.supportsAlternateIcons)

        case "currentIcon":
            let name = UIApplication.shared.alternateIconName ?? ""
            result(name.hasPrefix("AppIcon-") ? String(name.dropFirst("AppIcon-".count)) : "")

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Apply [variant] now, or report why it could not be.
    private func applyIcon(_ variant: String,
                           _ done: @escaping (Bool) -> Void) {
        guard UIApplication.shared.supportsAlternateIcons else { done(false); return }
        // Alternate icons must be DECLARED in Info.plist (CFBundleIcons) and shipped
        // as loose files at the bundle root; an undeclared name fails rather than
        // reporting success, so an unknown variant is normalised to the stock icon.
        let wanted = AuvySystemChannels.iconVariants.contains(variant) ? variant : ""
        let name: String? = wanted.isEmpty ? nil : "AppIcon-\(wanted)"
        // UIKit shows its alert even when the icon wouldn't change, so skip the call
        // when it's already correct.
        guard name != UIApplication.shared.alternateIconName else { done(true); return }
        UIApplication.shared.setAlternateIconName(name) { error in
            DispatchQueue.main.async {
                if let error = error {
                    AuvyPlayer.log("icon: could not set \(name ?? "primary") — \(error.localizedDescription)")
                }
                done(error == nil)
            }
        }
    }

    /// Apply whatever the accent last asked for, on the way out of the foreground.
    ///
    /// Uses willResignActive rather than didEnterBackground: by
    /// didEnterBackground UIKit cancels icon changes ("The operation was
    /// cancelled"). willResignActive is still early enough to be accepted and late
    /// enough that no alert is shown. Both are observed, so the later one is a
    /// second chance if the first is refused.
    private func observeBackgroundForIconSwap() {
        for name in [UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification] {
            let obs = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { _ in
                    AuvySystemChannels.applyPendingIcon()
                    // Leaving the app is when iOS wants the next background
                    // check asked for (a no-op unless alerts are on).
                    if name == UIApplication.didEnterBackgroundNotification {
                        AuvyWhatsNewBackground.schedule()
                    }
            }
            if name == UIApplication.didEnterBackgroundNotification {
                backgroundObserver = obs
            } else {
                resignObserver = obs
            }
        }
    }

    /// The pending accent icon, applied if UIKit will take it.
    ///
    /// Static and idempotent so both lifecycle notifications can call it: the
    /// first one to succeed clears the request, and the second then finds
    /// nothing to do.
    private static func applyPendingIcon() {
        let defaults = UserDefaults.standard
        guard let wanted = defaults.string(forKey: AuvySystemChannels.pendingIconKey)
        else { return }
        let current = UIApplication.shared.alternateIconName
        let name: String? = wanted.isEmpty ? nil : "AppIcon-\(wanted)"
        guard name != current else {
            // Already wearing it — drop the request so a later background
            // does not keep re-asking.
            defaults.removeObject(forKey: AuvySystemChannels.pendingIconKey)
            return
        }
        guard UIApplication.shared.supportsAlternateIcons else { return }
        UIApplication.shared.setAlternateIconName(name) { error in
            if error == nil {
                defaults.removeObject(forKey: AuvySystemChannels.pendingIconKey)
                AuvyPlayer.log("icon: switched to \(name ?? "primary")")
            } else {
                // Keep the request: iOS refuses the swap in some states, and it will be
                // retried next time the app leaves the foreground.
                AuvyPlayer.log("icon: swap refused — \(error!.localizedDescription)")
            }
        }
    }

    // MARK: Backup / export

    private func backup(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "saveToDownloads":
            let args = call.arguments as? [String: Any] ?? [:]
            let name = args["name"] as? String ?? "auvy-export"
            guard let data = (args["bytes"] as? FlutterStandardTypedData)?.data else {
                result(nil); return
            }
            // There is no shared Downloads collection on iOS. The app's Documents
            // directory is the closest real equivalent: with UIFileSharingEnabled it
            // is browsable in Files under "On My iPhone → Auvy", so the export is a
            // visible file the user can reach, which is what the Android path buys.
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let target = dir.appendingPathComponent(name)
            do {
                try data.write(to: target, options: .atomic)
                result(target.path)
            } catch {
                result(nil)
            }

        case "pickFile":
            AuvyDocumentPicker.shared.pick { picked in
                guard let picked = picked else { result(nil); return }
                result(["path": picked.path, "name": picked.lastPathComponent])
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: Folder

    private func folder(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "listAudioIn":
            // Android reads a shared folder of the user's own music. iOS has no
            // such folder an app may enumerate — everything outside the sandbox
            // requires an explicit per-file grant — so there is nothing to list.
            result([])
        case "open":
            // Open the app's own folder in Files, which is the only location that
            // exists here. `shareddocuments://` is what Files registers.
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            var comps = URLComponents(url: dir, resolvingAgainstBaseURL: false)
            comps?.scheme = "shareddocuments"
            if let url = comps?.url, UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                result(true)
            } else {
                result(false)
            }
        case "scanMedia":
            // MediaStore is Android's. iOS has no index to notify: a file in the
            // app's container is visible the moment it is written.
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: Widget

    private func widget(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        // A home-screen widget on iOS is WidgetKit + App Intents in a separate
        // extension target — a rewrite rather than a port, and not built yet.
        // Answering rather than throwing keeps the update calls (which fire on
        // every track change) from surfacing as unhandled errors.
        result(nil)
    }

    // MARK: Audio capture

    private func audioCapture(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "capture":
            // Screen-audio capture doesn't exist on iOS. `NO_AUDIO` maps to
            // CaptureFailure.noAudio in Dart, whose response is to fall back to the
            // microphone (fully supported here), whereas `UNSUPPORTED` would stop the
            // flow entirely.
            result(FlutterError(code: "NO_AUDIO",
                                message: "System audio capture is not available on iOS",
                                details: nil))

        case "consumeFoundTap":
            result(nil)
        default:
            result(nil)
        }
    }

    // MARK: Alarm

    private func alarm(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            AuvyAlarmKit.handle(call, result)
            return
        }
        #endif
        switch call.method {
        case "isSupported", "canScheduleExact", "canUseFullScreenIntent", "isArmed":
            // Before iOS 26 an app cannot ring at a set time: the ceiling is a
            // notification with a sound of at most 30 seconds, silenced by the
            // ring switch and Focus. Dart hides the alarm when this says false.
            result(false)
        case "alarmAudioState":
            result(nil)
        case "consumePendingAlarm":
            result(nil)
        default:
            result(nil)
        }
    }

    // MARK: Image (WebP encoding)

    /// Encodes a picture as WebP, its longest side at most `maxDimension`. iOS
    /// reads WebP but has no writer, so this uses libwebp. Custom covers are
    /// stored this way: about a sixteenth of the PNG Flutter can write itself.
    private func image(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard call.method == "encodeWebp",
              let args = call.arguments as? [String: Any],
              let data = (args["bytes"] as? FlutterStandardTypedData)?.data else {
            result(FlutterMethodNotImplemented)
            return
        }
        let maxDimension = (args["maxDimension"] as? NSNumber)?.intValue ?? 384
        let quality = Float((args["quality"] as? NSNumber)?.intValue ?? 82)
        DispatchQueue.global(qos: .userInitiated).async {
            let out = AuvySystemChannels.encodeWebp(data, maxDimension: maxDimension, quality: quality)
            DispatchQueue.main.async {
                result(out.map { FlutterStandardTypedData(bytes: $0) })
            }
        }
    }

    static func encodeWebp(_ data: Data, maxDimension: Int, quality: Float) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxDimension,
              ] as CFDictionary)
        else { return nil }
        let width = cg.width, height = cg.height, stride = width * 4
        var rgba = [UInt8](repeating: 0, count: stride * height)
        // Premultiplied is what CoreGraphics draws; covers are opaque, where it is
        // the same as the straight alpha libwebp expects.
        guard let context = CGContext(
            data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var output: UnsafeMutablePointer<UInt8>?
        let size = WebPEncodeRGBA(&rgba, Int32(width), Int32(height), Int32(stride), quality, &output)
        guard size > 0, let bytes = output else { return nil }
        defer { WebPFree(bytes) }
        return Data(bytes: bytes, count: size)
    }

    // MARK: Signing (sideload expiry)

    /// Prefix of the reminders scheduled here, so a reschedule replaces exactly
    /// these and nothing else.
    private static let signingReminderPrefix = "auvy.signing."

    /// When this install stops opening: the ExpirationDate of the provisioning
    /// profile it was signed with (7 days after signing on a free Apple ID).
    /// SideStore writes a new profile on every refresh, so each launch reads the
    /// current one. App Store and TestFlight builds and the simulator carry no
    /// profile, so the answer there is nil and nothing is scheduled.
    static func provisioningDates() -> (created: Date?, expires: Date)? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              // A signed envelope around a plain XML plist: take the plist out.
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil)
                  as? [String: Any],
              let expires = plist["ExpirationDate"] as? Date
        else { return nil }
        return (plist["CreationDate"] as? Date, expires)
    }

    private func signing(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let center = UNUserNotificationCenter.current()
        let prefix = AuvySystemChannels.signingReminderPrefix
        switch call.method {
        case "expiry":
            guard let dates = AuvySystemChannels.provisioningDates() else { result(nil); return }
            var out: [String: Any] = ["expiresMs": Int64(dates.expires.timeIntervalSince1970 * 1000)]
            if let created = dates.created {
                out["createdMs"] = Int64(created.timeIntervalSince1970 * 1000)
            }
            result(out)
        case "permission":
            center.getNotificationSettings { settings in
                let status: String
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: status = "granted"
                case .denied: status = "denied"
                default: status = "undecided"
                }
                DispatchQueue.main.async { result(status) }
            }
        case "requestPermission":
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DispatchQueue.main.async { result(granted) }
            }
        case "schedule":
            // Replaces every reminder from an earlier launch: a refresh moves the
            // expiry, and the old ones would warn about a date that no longer
            // holds. Delivered ones go too, since the app is open to say it now.
            let items = (call.arguments as? [String: Any])?["reminders"] as? [[String: Any]] ?? []
            center.getPendingNotificationRequests { pending in
                center.removePendingNotificationRequests(
                    withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
                center.getDeliveredNotifications { delivered in
                    center.removeDeliveredNotifications(
                        withIdentifiers: delivered.map(\.request.identifier).filter { $0.hasPrefix(prefix) })
                    let now = Date().timeIntervalSince1970
                    var added = 0
                    for item in items {
                        guard let id = item["id"] as? String,
                              let atMs = (item["atMs"] as? NSNumber)?.doubleValue,
                              let title = item["title"] as? String,
                              let body = item["body"] as? String else { continue }
                        // Already due: the in-app card says it instead.
                        let interval = atMs / 1000 - now
                        guard interval > 1 else { continue }
                        let content = UNMutableNotificationContent()
                        content.title = title
                        content.body = body
                        content.sound = .default
                        center.add(UNNotificationRequest(
                            identifier: prefix + id, content: content,
                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)))
                        added += 1
                    }
                    DispatchQueue.main.async { result(added) }
                }
            }
        case "cancel":
            center.getPendingNotificationRequests { pending in
                center.removePendingNotificationRequests(
                    withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
                DispatchQueue.main.async { result(nil) }
            }
        case "openSettings":
            // Auvy's own page in the Settings app, where a denied permission is
            // turned back on (iOS never asks twice).
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: Output routing

    private func output(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let session = AVAudioSession.sharedInstance()
        switch call.method {
        case "carMode":
            result(session.currentRoute.outputs.contains { $0.portType == .carAudio })
        case "route":
            // A KIND, not a name — the same vocabulary MainActivity's
            // currentAudioRoute answers with. This returned portName ("AirPods
            // Pro", "Speaker"), which no caller could match, so Listen Together
            // never saw 'bluetooth' on an iPhone and never applied its output-
            // latency correction: a guest on AirPods sat ~200 ms off for the whole
            // session and nudged its tempo continuously trying to close it.
            result(AuvySystemChannels.routeKind(session.currentRoute.outputs.first?.portType))
        case "watchOutputs":
            let on = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
            setWatchingOutputs(on)
            result(nil)
        case "open":
            // Open the system route picker (AirPlay/Bluetooth chooser), the iOS
            // equivalent of Android's output switcher. There's no public URL for the
            // Bluetooth settings pane, and the picker actually switches the route.
            result(presentRoutePicker())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Show the system's AirPlay / Bluetooth output chooser.
    ///
    /// AVRoutePickerView has no "present" API; it's a button. So a real one is
    /// added to the window (zero alpha, but a normal size, since hidden or
    /// zero-size views don't respond), sent a tap, and removed once the sheet is
    /// showing.
    ///
    /// Returns false when there's no window, so Dart can mark the control as
    /// unavailable.
    private func presentRoutePicker() -> Bool {
        guard let host = AuvySystemChannels.keyWindow() else { return false }
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.alpha = 0.0
        picker.isUserInteractionEnabled = false
        host.addSubview(picker)

        var tapped = false
        for case let button as UIButton in picker.subviews {
            button.sendActions(for: .touchUpInside)
            tapped = true
        }

        // Long enough for the sheet to take over, then gone — leaving it would
        // stack one invisible picker per tap on the key window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            picker.removeFromSuperview()
        }
        if !tapped {
            AuvyPlayer.log("output: AVRoutePickerView exposed no button to tap")
        }
        return tapped
    }

    /// Only while the picker is open: a permanent listener would wake work on every
    /// plug event for a sheet that is visible for seconds.
    private func setWatchingOutputs(_ on: Bool) {
        if let observer = routeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeObserver = nil
        }
        guard on else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.outputChannel?.invokeMethod("outputsChanged", arguments: nil)
        }
    }

    // MARK: Helpers

    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}

/// A label with room around its text, so the toast is not a tight box of letters.
private final class PaddedLabel: UILabel {
    private let inset = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: inset))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + inset.left + inset.right,
                      height: size.height + inset.top + inset.bottom)
    }
}

/// Wraps UIDocumentPicker's delegate-based flow in a single callback.
final class AuvyDocumentPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = AuvyDocumentPicker()
    private var completion: ((URL?) -> Void)?

    func pick(completion: @escaping (URL?) -> Void) {
        guard let host = AuvySystemChannels.keyWindow()?.rootViewController else {
            completion(nil); return
        }
        self.completion = completion
        // asCopy: true so the system downloads an iCloud Drive file that's been
        // evicted to the cloud before handing it over; a plain reference would have
        // no local bytes to copy.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.json, .zip, .commaSeparatedText, .data],
            asCopy: true)
        picker.delegate = self
        var top: UIViewController = host
        while let presented = top.presentedViewController { top = presented }
        top.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { finish(nil); return }
        // A picked file can still live outside the sandbox (and does, when the
        // system declines to copy), so copy it somewhere Dart can open by plain
        // path. Scoping is a no-op for an `asCopy` result and required otherwise.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)

        // The picked file may already be the target (asCopy puts it in our temp
        // directory), in which case the removeItem below would delete it.
        if url.standardizedFileURL == target.standardizedFileURL {
            finish(target)
            return
        }

        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: url, to: target)
            finish(target)
        } catch {
            finish(nil)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(nil)
    }

    private func finish(_ url: URL?) {
        let done = completion
        completion = nil
        done?(url)
    }
}

/// Shows Auvy's own reminders while the app is in front (iOS hides a
/// notification from the app that is open unless its delegate asks), and
/// passes everything else to the delegate that was there before, if any.
final class AuvyNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var previous: UNUserNotificationCenterDelegate?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.identifier.hasPrefix("auvy.") {
            completionHandler([.banner, .list, .sound])
        } else if let previous = previous,
                  previous.responds(to: #selector(UNUserNotificationCenterDelegate
                      .userNotificationCenter(_:willPresent:withCompletionHandler:))) {
            previous.userNotificationCenter?(center, willPresent: notification,
                                             withCompletionHandler: completionHandler)
        } else {
            completionHandler([])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // A tap on a What's New notification opens that page; on a reminder it
        // just opens Auvy, where the Home card says the rest.
        if response.notification.request.identifier.hasPrefix(AuvyWhatsNew.notePrefix) {
            AuvyWhatsNew.notificationTapped()
        }
        if !response.notification.request.identifier.hasPrefix("auvy."),
           let previous = previous,
           previous.responds(to: #selector(UNUserNotificationCenterDelegate
               .userNotificationCenter(_:didReceive:withCompletionHandler:))) {
            previous.userNotificationCenter?(center, didReceive: response,
                                             withCompletionHandler: completionHandler)
        } else {
            completionHandler()
        }
    }
}

// MARK: What's New

/// The What's New channel: the notification permission, posting notifications
/// for what a check in the app found, switching the background check on and
/// off, and telling Dart a notification was tapped.
final class AuvyWhatsNew {
    static let notePrefix = "auvy.whatsnew."
    static let openKey = "auvy.whatsnew.open"
    static let backgroundKey = "auvy.whatsnew.background"
    private static weak var current: AuvyWhatsNew?
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "com.auvy.app/whatsnew", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in AuvyWhatsNew.handle(call, result) }
        AuvyWhatsNew.current = self
    }

    /// Read-and-clear by Dart (consumeOpen); the message reaches a running app
    /// at once, the flag a cold start.
    static func notificationTapped() {
        UserDefaults.standard.set(true, forKey: openKey)
        current?.channel.invokeMethod("openWhatsNew", arguments: nil)
    }

    private static func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let center = UNUserNotificationCenter.current()
        switch call.method {
        case "permission":
            center.getNotificationSettings { settings in
                let status: String
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: status = "granted"
                case .denied: status = "denied"
                default: status = "undecided"
                }
                DispatchQueue.main.async { result(status) }
            }
        case "requestPermission":
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DispatchQueue.main.async { result(granted) }
            }
        case "openSettings":
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            result(nil)
        case "notify":
            let items = (call.arguments as? [String: Any])?["items"] as? [[String: Any]] ?? []
            for item in items {
                guard let id = item["id"] as? String, let title = item["title"] as? String,
                      let body = item["body"] as? String else { continue }
                post(id: id, title: title, body: body)
            }
            result(nil)
        case "setBackground":
            let on = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
            let was = UserDefaults.standard.bool(forKey: backgroundKey)
            UserDefaults.standard.set(on, forKey: backgroundKey)
            if on {
                AuvyWhatsNewBackground.schedule()
            } else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AuvyWhatsNewBackground.taskId)
            }
            if on != was { AuvyPlayer.log("whats new: background check \(on ? "on" : "off")") }
            result(nil)
        case "consumeOpen":
            let pending = UserDefaults.standard.bool(forKey: openKey)
            if pending { UserDefaults.standard.removeObject(forKey: openKey) }
            result(pending)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "auvy.whatsnew"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: notePrefix + id, content: content, trigger: nil))
    }
}

/// The What's New check with Auvy closed. iOS runs it when it sees fit
/// (BGAppRefreshTask, typically a few times a day for an app in use), with
/// Dart not running: it reads the list Dart wrote (whats_new/watch.json), asks
/// the iTunes catalogue the same questions, applies the same rules as
/// whats_new_logic.dart, posts notifications, and leaves what it found in
/// whats_new/bg.json for the app to take in.
enum AuvyWhatsNewBackground {
    static let taskId = "com.auvy.app.whatsnew"

    /// Called from didFinishLaunching: iOS requires the handler before launch ends.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            run(refresh)
        }
    }

    /// Asks for the next run, no sooner than four hours away.
    static func schedule() {
        guard UserDefaults.standard.bool(forKey: AuvyWhatsNew.backgroundKey) else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AuvyPlayer.log("whats new: background check not scheduled: \(error)")
        }
    }

    private static func run(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task {
            let ok = await check()
            task.setTaskCompleted(success: ok && !Task.isCancelled)
        }
        // Out of time: the requests are cancelled and the task ends unsuccessful.
        task.expirationHandler = { work.cancel() }
    }

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whats_new", isDirectory: true)
    }

    private static func readJSON(_ name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The same loose comparison as normalizeArtistName in Dart.
    static func normalize(_ name: String) -> String {
        var n = name.lowercased()
        if n.hasSuffix(" - topic") { n = String(n.dropLast(8)) }
        return n.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    struct Found {
        let key: String, kind: String, title: String, source: String, label: String
        let image: String, dateMs: Int64, target: String
    }

    static func check() async -> Bool {
        guard let watch = readJSON("watch.json"), watch["enabled"] as? Bool == true else { return true }
        let previous = readJSON("bg.json") ?? [:]
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let lastApp = (watch["lastCheckMs"] as? NSNumber)?.int64Value ?? 0
        let lastHere = (previous["checkedMs"] as? NSNumber)?.int64Value ?? 0
        // The app checked recently, or this did: nothing can be new enough yet.
        if nowMs - max(lastApp, lastHere) < 3 * 3600 * 1000 { return true }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        // Data saver: no cellular or Low Data Mode use while closed.
        let saver = watch["dataSaver"] as? Bool == true
        config.allowsExpensiveNetworkAccess = !saver
        config.allowsConstrainedNetworkAccess = !saver
        let session = URLSession(configuration: config)

        var notified = Set((watch["notified"] as? [String]) ?? [])
        notified.formUnion((previous["notified"] as? [String]) ?? [])
        let from = nowMs - 3 * 24 * 3600 * 1000
        var due: [Found] = []
        let iso = ISO8601DateFormatter()

        func get(_ path: String) async -> [[String: Any]] {
            guard let url = URL(string: "https://itunes.apple.com/" + path),
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return [] }
            return json["results"] as? [[String: Any]] ?? []
        }
        func ms(_ raw: Any?) -> Int64? {
            guard let s = raw as? String, let d = iso.date(from: s) else { return nil }
            return Int64(d.timeIntervalSince1970 * 1000)
        }
        func large(_ url: String) -> String {
            url.replacingOccurrences(of: #"/\d+x\d+bb\."#, with: "/600x600bb.", options: .regularExpression)
        }

        // Releases: each artist entry is followed by that artist's releases.
        let artists = (watch["artists"] as? [[String: Any]]) ?? []
        var byId: [Int: (name: String, appId: String)] = [:]
        for a in artists {
            if let id = (a["id"] as? NSNumber)?.intValue, let name = a["name"] as? String {
                byId[id] = (name, a["appId"] as? String ?? "")
            }
        }
        let ids = Array(byId.keys)
        for start in stride(from: 0, to: ids.count, by: 15) {
            if Task.isCancelled { return false }
            let chunk = ids[start..<min(start + 15, ids.count)].map(String.init).joined(separator: ",")
            var current: (id: Int, name: String, appId: String)?
            for r in await get("lookup?id=\(chunk)&entity=album&sort=recent&limit=15") {
                if r["wrapperType"] as? String == "artist" {
                    let id = (r["artistId"] as? NSNumber)?.intValue ?? -1
                    current = byId[id].map { (id, $0.name, $0.appId) }
                    continue
                }
                guard r["wrapperType"] as? String == "collection", let artist = current,
                      let cid = (r["collectionId"] as? NSNumber)?.intValue,
                      let name = r["collectionName"] as? String, !name.isEmpty,
                      let date = ms(r["releaseDate"]), date >= from, date <= nowMs,
                      !name.lowercased().contains("video album"),
                      !notified.contains("rel:\(cid)") else { continue }
                let credited = r["artistName"] as? String ?? ""
                let own = (r["artistId"] as? NSNumber)?.intValue == artist.id
                guard own || " \(normalize(credited)) ".contains(" \(normalize(artist.name)) ")
                else { continue }
                var title = name.trimmingCharacters(in: .whitespaces)
                var label = ((r["trackCount"] as? NSNumber)?.intValue ?? 0).isBetween(1, 3) ? "Single" : "Album"
                for (suffix, l) in [(" - Single", "Single"), (" - EP", "EP")] where title.hasSuffix(suffix) {
                    title = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                    label = l
                }
                notified.insert("rel:\(cid)")
                due.append(Found(key: "rel:\(cid)", kind: "release", title: title,
                                 source: artist.name, label: label,
                                 image: large(r["artworkUrl100"] as? String ?? ""), dateMs: date,
                                 target: artist.appId.isEmpty ? artist.name : artist.appId))
            }
        }

        // Episodes.
        let podcasts = (watch["podcasts"] as? [[String: Any]]) ?? []
        var shows: [Int: (name: String, feed: String)] = [:]
        for p in podcasts {
            if let id = (p["id"] as? NSNumber)?.intValue, let name = p["name"] as? String {
                shows[id] = (name, p["feed"] as? String ?? "")
            }
        }
        let showIds = Array(shows.keys)
        for start in stride(from: 0, to: showIds.count, by: 10) {
            if Task.isCancelled { return false }
            let chunk = showIds[start..<min(start + 10, showIds.count)].map(String.init).joined(separator: ",")
            for r in await get("lookup?id=\(chunk)&entity=podcastEpisode&limit=2") {
                guard r["wrapperType"] as? String == "podcastEpisode",
                      let show = shows[(r["collectionId"] as? NSNumber)?.intValue ?? -1],
                      let tid = (r["trackId"] as? NSNumber)?.intValue,
                      let title = r["trackName"] as? String, !title.isEmpty,
                      let date = ms(r["releaseDate"]), date >= from, date <= nowMs,
                      !notified.contains("ep:\(tid)") else { continue }
                notified.insert("ep:\(tid)")
                due.append(Found(key: "ep:\(tid)", kind: "episode", title: title, source: show.name,
                                 label: "Episode",
                                 image: large(r["artworkUrl600"] as? String ?? ""),
                                 dateMs: date, target: show.feed))
            }
        }

        // The same wording and grouping as notificationsFor in Dart.
        if !due.isEmpty {
            func headline(_ f: Found) -> String {
                f.kind == "episode" ? "New episode of \(f.source)" : "New \(f.label.lowercased()) from \(f.source)"
            }
            if due.count <= 3 {
                for f in due { AuvyWhatsNew.post(id: f.key, title: headline(f), body: f.title) }
            } else {
                var sources: [String] = []
                for f in due where !sources.contains(f.source) { sources.append(f.source) }
                let episodes = due.filter { $0.kind == "episode" }.count
                let what = episodes == 0 ? "new releases"
                    : episodes == due.count ? "new episodes" : "new releases and episodes"
                let names = sources.count <= 2 ? sources.joined(separator: " and ")
                    : "\(sources.prefix(2).joined(separator: ", ")) and \(sources.count - 2) more"
                AuvyWhatsNew.post(id: "summary:\(due[0].key)", title: "\(due.count) \(what)", body: names)
            }
        }

        var found = (previous["found"] as? [[String: Any]]) ?? []
        for f in due {
            found.append(["key": f.key, "kind": f.kind, "title": f.title, "source": f.source,
                          "label": f.label, "image": f.image, "dateMs": f.dateMs,
                          "foundMs": nowMs, "target": f.target])
        }
        if found.count > 50 { found.removeFirst(found.count - 50) }
        var keep = Array(notified)
        if keep.count > 400 { keep = Array(keep.suffix(400)) }
        let line = "\(byId.count) artist(s), \(shows.count) podcast(s), \(due.count) new"
        let out: [String: Any] = ["notified": keep, "found": found, "checkedMs": nowMs,
                                  "line": line]
        if let data = try? JSONSerialization.data(withJSONObject: out) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("bg.json"), options: .atomic)
        }
        AuvyPlayer.log("whats new: background check — \(line)")
        return true
    }
}

private extension Int {
    func isBetween(_ low: Int, _ high: Int) -> Bool { self >= low && self <= high }
}

#if canImport(AlarmKit)
/// The wake-up alarm on iOS 26 and later, through AlarmKit: a real system
/// alarm, shown over the lock screen and heard through silent mode and Focus,
/// like the Clock app's. The system rings it, so it works with Auvy closed. The
/// sound is a clip of the prepared alarm track (see makeClip); with no track
/// yet it is the system tone, and the alarm is rescheduled once the track is
/// ready.
///
/// No snooze yet: AlarmKit's snooze is a countdown shown by a Live Activity
/// widget, and a Snooze button that never rang again would be worse than none.
@available(iOS 26.0, *)
enum AuvyAlarmKit {
    struct Metadata: AlarmMetadata {}

    private static let clipSourceKey = "auvy.alarm.clipSource"
    private static let clipNameKey = "auvy.alarm.clipName"

    /// Alert sounds longer than 30 seconds are replaced by the system tone, so
    /// the clip stays under that.
    private static let clipSeconds: Double = 29

    static func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let manager = AlarmManager.shared
        switch call.method {
        case "isSupported", "canUseFullScreenIntent":
            // An AlarmKit alarm always appears over the lock screen.
            result(true)
        case "canScheduleExact":
            result(manager.authorizationState == .authorized)
        case "requestExactPermission":
            switch manager.authorizationState {
            case .notDetermined:
                Task {
                    let state = try? await manager.requestAuthorization()
                    DispatchQueue.main.async { result(state == .authorized) }
                }
            case .denied:
                // iOS asks once; after that the switch is in the Settings app.
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                result(false)
            default:
                result(true)
            }
        case "schedule":
            let args = call.arguments as? [String: Any] ?? [:]
            Task {
                let error = await schedule(args)
                DispatchQueue.main.async {
                    result(error.map { FlutterError(code: "ALARM", message: $0, details: nil) })
                }
            }
        case "cancel":
            cancelAll()
            AuvyPlayer.log("alarm: cancelled")
            result(nil)
        case "isArmed":
            result(!((try? manager.alarms) ?? []).isEmpty)
        case "consumePendingAlarm":
            result(false)
        default:
            // The ringing-screen and snooze calls: the system owns the alarm here.
            result(nil)
        }
    }

    /// Replaces the alarm. Asks for permission the first time (the moment the
    /// listener turns the alarm on). Returns an error message, or nil.
    private static func schedule(_ args: [String: Any]) async -> String? {
        let manager = AlarmManager.shared
        if manager.authorizationState == .notDetermined {
            _ = try? await manager.requestAuthorization()
        }
        guard manager.authorizationState == .authorized else {
            AuvyPlayer.log("alarm: not allowed to ring alarms, so nothing is set")
            return "not authorized"
        }
        guard let hour = (args["hour"] as? NSNumber)?.intValue,
              let minute = (args["minute"] as? NSNumber)?.intValue else { return "no time" }
        // Calendar's Sunday..Saturday, 1..7 (what Android's scheduler takes too).
        let weekdays: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday,
                                          .thursday, .friday, .saturday]
        let days = ((args["days"] as? [NSNumber]) ?? []).compactMap { n -> Locale.Weekday? in
            let i = n.intValue - 1
            return weekdays.indices.contains(i) ? weekdays[i] : nil
        }
        cancelAll()

        let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Wake up"
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title))
        } else {
            alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: title),
                stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"))
        }
        let attributes = AlarmAttributes<Metadata>(
            presentation: AlarmPresentation(alert: alert),
            tintColor: Color(red: 1.0, green: 0.8, blue: 0.5))
        let sound = await clipSound(args)
        let schedule = Alarm.Schedule.relative(.init(
            time: .init(hour: hour, minute: minute),
            repeats: days.isEmpty ? .never : .weekly(days)))
        do {
            _ = try await manager.schedule(
                id: UUID(),
                configuration: .alarm(schedule: schedule, attributes: attributes, sound: sound))
            AuvyPlayer.log(String(format: "alarm: set for %02d:%02d, ", hour, minute)
                + (days.isEmpty ? "once" : "\(days.count) day(s) a week")
                + (sound == .default ? ", system tone (no track yet)" : ", track clip"))
            return nil
        } catch {
            AuvyPlayer.log("alarm: scheduling failed: \(error)")
            return "\(error)"
        }
    }

    /// Every alarm this app has. There is only ever one, but cancelling all of
    /// them means a lost id can never leave a second alarm behind.
    private static func cancelAll() {
        for alarm in (try? AlarmManager.shared.alarms) ?? [] {
            try? AlarmManager.shared.cancel(id: alarm.id)
        }
    }

    private static func soundsDirectory() -> URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    /// The clip for the prepared track, made once per track and setting.
    private static func clipSound(_ args: [String: Any]) async -> AlertConfiguration.AlertSound {
        guard let path = args["trackPath"] as? String, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return .default }
        // Repaired before the file's date is read: the repair writes to it, and
        // reading the date first made every later call remake the clip.
        AuvyMP4Repair.repairIfFragmented(at: URL(fileURLWithPath: path))
        let fade = max(0, (args["fadeSeconds"] as? NSNumber)?.doubleValue ?? 0)
        let volume = min(1, max(0.05, (args["volume"] as? NSNumber)?.floatValue ?? 1))
        let modified = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
            as? Date)?.timeIntervalSince1970 ?? 0
        let source = "\(path)|\(modified)|\(fade)|\(volume)"
        let defaults = UserDefaults.standard
        if defaults.string(forKey: clipSourceKey) == source,
           let name = defaults.string(forKey: clipNameKey),
           FileManager.default.fileExists(atPath: soundsDirectory().appendingPathComponent(name).path) {
            return .named(name)
        }
        guard let name = await makeClip(from: URL(fileURLWithPath: path), fadeSeconds: fade, volume: volume)
        else { return .default }
        defaults.set(source, forKey: clipSourceKey)
        defaults.set(name, forKey: clipNameKey)
        return .named(name)
    }

    /// The first [clipSeconds] of the track as 16-bit PCM in Library/Sounds,
    /// where alert sounds are looked up, with the alarm's volume and fade-in
    /// applied and a short fade at the end so a repeat doesn't click. Returns
    /// the file name, or nil (then the alarm uses the system tone).
    private static func makeClip(from url: URL, fadeSeconds: Double, volume: Float) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else {
            AuvyPlayer.log("alarm: the track can't be read, so the alarm uses the system tone")
            return nil
        }
        let rate = 44100.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.timeRange = CMTimeRange(start: .zero,
                                       duration: CMTime(seconds: clipSeconds, preferredTimescale: 600))
        reader.add(output)
        guard reader.startReading() else { return nil }
        var samples = [Float]()
        samples.reserveCapacity(Int(rate * clipSeconds) * 2)
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                               destination: raw.baseAddress!)
            }
            samples += chunk
        }
        let frames = samples.count / 2
        guard reader.status == .completed, frames > Int(rate) else {
            AuvyPlayer.log("alarm: reading the track failed (\(reader.status.rawValue)), system tone instead")
            return nil
        }

        let fadeFrames = Int(min(fadeSeconds, clipSeconds) * rate)
        let tailFrames = Int(0.25 * rate)
        for f in 0..<frames {
            var gain = volume
            if f < fadeFrames { gain *= max(0.1, Float(f) / Float(fadeFrames)) }
            if f >= frames - tailFrames { gain *= Float(frames - f) / Float(tailFrames) }
            samples[2 * f] *= gain
            samples[2 * f + 1] *= gain
        }

        let directory = soundsDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A new name each time: the system may keep a sound it has seen by name.
        for old in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where old.hasPrefix("auvy_alarm_") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
        }
        let name = "auvy_alarm_\(Int(Date().timeIntervalSince1970)).caf"
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: 2, interleaved: true),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)
        samples.withUnsafeBufferPointer { src in
            pcm.floatChannelData![0].update(from: src.baseAddress!, count: frames * 2)
        }
        do {
            let file = try AVAudioFile(
                forWriting: directory.appendingPathComponent(name),
                settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                           AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
                commonFormat: .pcmFormatFloat32, interleaved: true)
            try file.write(from: pcm)
        } catch {
            AuvyPlayer.log("alarm: writing the clip failed: \(error)")
            return nil
        }
        AuvyPlayer.log("alarm: made a \(frames / Int(rate))s clip of the track for the alarm sound")
        return name
    }
}
#endif
