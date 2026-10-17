import AppIntents
import Foundation
import WidgetKit

/// How a widget or Control Center button reaches the player.
///
/// These intents are compiled into the app and the widget. Being
/// AudioPlaybackIntents, iOS runs them in the app's process even when tapped
/// on a widget, so [run] is set by the app (AuvyCommands) and is never needed
/// in the widget's own process.
enum AuvyIntentRouter {
    static var run: ((String, [String: Any]) async -> AuvyIntentOutcome)?

    /// Makes the error that asks iOS to open Auvy. Set by the app, because the
    /// call behind it (ForegroundContinuableIntent) isn't allowed in an
    /// extension, and this file is compiled into the widget too.
    static var openAppError: ((Any) -> Error)?
}

enum AuvyIntentOutcome {
    /// Done, with what Siri should say (nil: nothing to say).
    case done(String?)
    /// Auvy isn't running and iOS didn't start its screen; the app has to open.
    case needsApp
}

enum AuvyIntentError: Error {
    case openAuvy
}

@available(iOS 16.0, *)
extension AuvyIntentError: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        "Open Auvy first, then try again."
    }
}

@available(iOS 17.0, *)
extension AppIntent {
    /// Sends [command] to the player. When Auvy isn't running, asks iOS to open
    /// it; the command is held and runs as soon as it has.
    func runPlayerCommand(_ command: String, from: String,
                          extra: [String: Any] = [:]) async throws -> String? {
        var args = extra
        args["from"] = from
        switch await AuvyIntentRouter.run?(command, args) ?? .needsApp {
        case .done(let message):
            return message
        case .needsApp:
            throw AuvyIntentRouter.openAppError?(self) ?? AuvyIntentError.openAuvy
        }
    }
}

/// The widgets' and Control Center's play/pause button.
@available(iOS 17.0, *)
struct AuvyTogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause Auvy"
    static let description = IntentDescription("Plays or pauses what Auvy is playing.")
    // Siri and Shortcuts get their own intents (AuvyIntents.swift); this one is
    // the button.
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        // Shown at once; the app's next state push corrects it if needed.
        var state = AuvyNowPlayingStore.load()
        let before = state.isPlaying
        if state.hasSong {
            state.isPlaying.toggle()
            AuvyNowPlayingStore.save(state)
            WidgetCenter.shared.reloadAllTimelines()
        }
        do {
            _ = try await runPlayerCommand("togglePlay", from: "widget")
        } catch {
            state.isPlaying = before
            AuvyNowPlayingStore.save(state)
            WidgetCenter.shared.reloadAllTimelines()
            throw error
        }
        return .result()
    }
}

@available(iOS 17.0, *)
struct AuvyNextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Song in Auvy"
    static let isDiscoverable = false
    func perform() async throws -> some IntentResult {
        _ = try await runPlayerCommand("next", from: "widget")
        return .result()
    }
}

@available(iOS 17.0, *)
struct AuvyPreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Song in Auvy"
    static let isDiscoverable = false
    func perform() async throws -> some IntentResult {
        _ = try await runPlayerCommand("previous", from: "widget")
        return .result()
    }
}

@available(iOS 17.0, *)
struct AuvyToggleLikeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Like the Song in Auvy"
    static let isDiscoverable = false
    func perform() async throws -> some IntentResult {
        var state = AuvyNowPlayingStore.load()
        if state.hasSong {
            state.isLiked.toggle()
            AuvyNowPlayingStore.save(state)
            WidgetCenter.shared.reloadAllTimelines()
        }
        _ = try await runPlayerCommand("toggleLike", from: "widget")
        return .result()
    }
}

/// The "Your mixes" widget's buttons: plays one of the built-in lists. The
/// collection travels as its id, the same ids AppCommands' playCollection takes.
@available(iOS 17.0, *)
struct AuvyPlayMixIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play a Mix in Auvy"
    static let isDiscoverable = false

    @Parameter(title: "Mix")
    var mix: String

    @Parameter(title: "Shuffle")
    var shuffle: Bool

    init() {}

    init(mix: String, shuffle: Bool = false) {
        self.mix = mix
        self.shuffle = shuffle
    }

    func perform() async throws -> some IntentResult {
        _ = try await runPlayerCommand("playCollection", from: "widget",
                                       extra: ["id": mix, "shuffle": shuffle])
        return .result()
    }
}
