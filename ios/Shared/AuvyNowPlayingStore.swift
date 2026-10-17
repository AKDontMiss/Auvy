import Foundation
import WidgetKit

/// What the widgets show: the song, whether it's playing, and the colours to
/// draw it in. Written by the app (AuvySystemChannels' widget channel, fed by
/// the same push as Android's widget) and read by the widget extension, through
/// the App Group they share. Compiled into both targets.
struct AuvyNowPlaying: Codable, Equatable {
    var title = ""
    var artist = ""
    var hasSong = false
    var isPlaying = false
    var isLiked = false
    /// The user's accent colour and the cover's darkened colour, 0xRRGGBB.
    var accent: UInt32 = 0x53B1E1
    var tint: UInt32?
    /// Bumped with each new cover, so a widget never shows the last one's.
    var artVersion = 0
    /// Where it's playing from: a playlist or album, or what autoplay picked it
    /// for ("Based on …").
    var context = ""
    /// The position at [sampledAtMs] and the song's length. The widgets draw
    /// progress from these (it moves on its own), so the app only sends them on
    /// a play, a pause, a seek or a new song.
    var positionMs = 0
    var durationMs = 0
    var sampledAtMs: Double = 0
    /// The next few songs, "Title — Artist".
    var upNext: [String] = []

    /// When the song started, as if it had played without a break: progress is
    /// measured from here while playing.
    var startDate: Date {
        Date(timeIntervalSince1970: (sampledAtMs - Double(positionMs)) / 1000)
    }

    var endDate: Date {
        startDate.addingTimeInterval(Double(durationMs) / 1000)
    }

    /// Playing, unless it says so for longer than the song lasts. The app marks
    /// itself paused when iOS closes it, but a crash or a kill can't; then the
    /// song's end is the latest that "playing" can still be true.
    var isReallyPlaying: Bool {
        guard isPlaying, hasSong else { return false }
        guard durationMs > 0, sampledAtMs > 0 else { return true }
        return Date() < endDate.addingTimeInterval(20)
    }

    init() {}

    // Decoded field by field with defaults, so a state written by an older
    // build (without the newer fields) still reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        artist = (try? c.decode(String.self, forKey: .artist)) ?? ""
        hasSong = (try? c.decode(Bool.self, forKey: .hasSong)) ?? false
        isPlaying = (try? c.decode(Bool.self, forKey: .isPlaying)) ?? false
        isLiked = (try? c.decode(Bool.self, forKey: .isLiked)) ?? false
        accent = (try? c.decode(UInt32.self, forKey: .accent)) ?? 0x53B1E1
        tint = try? c.decode(UInt32.self, forKey: .tint)
        artVersion = (try? c.decode(Int.self, forKey: .artVersion)) ?? 0
        context = (try? c.decode(String.self, forKey: .context)) ?? ""
        positionMs = (try? c.decode(Int.self, forKey: .positionMs)) ?? 0
        durationMs = (try? c.decode(Int.self, forKey: .durationMs)) ?? 0
        sampledAtMs = (try? c.decode(Double.self, forKey: .sampledAtMs)) ?? 0
        upNext = (try? c.decode([String].self, forKey: .upNext)) ?? []
    }
}

enum AuvyNowPlayingStore {

    /// The App Group, or nil when the app isn't signed for one (an Xcode build on
    /// a free team, or SideStore told to drop it). The widget then shows its
    /// "open Auvy" face, and its buttons still work: they run in the app.
    static let groupIdentifier: String? = AuvyAppGroup.resolve()

    static var container: URL? {
        groupIdentifier.flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
    }

    static var stateURL: URL? { container?.appendingPathComponent("now_playing.json") }
    static var artURL: URL? { container?.appendingPathComponent("now_playing_art.jpg") }

    static func load() -> AuvyNowPlaying {
        guard let url = stateURL, let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(AuvyNowPlaying.self, from: data)
        else { return AuvyNowPlaying() }
        return state
    }

    /// The app is going away: whatever was playing has stopped. Freezes the
    /// position where it got to and redraws the widgets.
    static func markStopped() {
        var state = load()
        guard state.isPlaying else { return }
        let now = Date().timeIntervalSince1970 * 1000
        state.positionMs = min(state.durationMs > 0 ? state.durationMs : Int.max,
                               state.positionMs + Int(max(0, now - state.sampledAtMs)))
        state.sampledAtMs = now
        state.isPlaying = false
        save(state)
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadAllControls()
        }
    }

    @discardableResult
    static func save(_ state: AuvyNowPlaying) -> Bool {
        guard let url = stateURL, let data = try? JSONEncoder().encode(state) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

/// Finds the App Group this copy of Auvy was actually signed with.
///
/// Built as "group.com.auvy.app", but SideStore renames it for the installing
/// Apple ID's team ("group.com.auvy.app.<team>") and renames the app to match
/// ("com.auvy.app.<team>"). So the group is read from this binary's own code
/// signature, the way SideStore's own app finds its group, with the name
/// derived from the bundle id and the original name as fallbacks. The first one
/// iOS gives a container for wins.
enum AuvyAppGroup {

    static func resolve() -> String? {
        var candidates = signedGroups()
        if let app = appBundleIdentifier { candidates.append("group." + app) }
        candidates.append("group.com.auvy.app")
        let fm = FileManager.default
        return candidates.first { fm.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }
    }

    /// The app's bundle id, from the app or from its widget (whose id is the
    /// app's plus ".widget").
    static var appBundleIdentifier: String? {
        guard var id = Bundle.main.bundleIdentifier else { return nil }
        if Bundle.main.bundleURL.pathExtension == "appex", let dot = id.lastIndex(of: ".") {
            id = String(id[..<dot])
        }
        return id
    }

    /// The groups in this binary's signed entitlements. They are an XML plist
    /// inside the code signature at the end of the executable, so the file is
    /// mapped rather than read, and searched from the end.
    static func signedGroups() -> [String] {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let key = data.range(of: Data("<key>com.apple.security.application-groups</key>".utf8),
                                   options: .backwards),
              let end = data.range(of: Data("</array>".utf8), in: key.upperBound..<data.endIndex)
        else { return [] }
        let xml = String(decoding: data[key.upperBound..<end.lowerBound], as: UTF8.self)
        var groups: [String] = []
        var rest = xml[...]
        while let open = rest.range(of: "<string>"), let close = rest.range(of: "</string>", range: open.upperBound..<rest.endIndex) {
            groups.append(String(rest[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces))
            rest = rest[close.upperBound...]
        }
        return groups.filter { $0.hasPrefix("group.") }
    }
}
