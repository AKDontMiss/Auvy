import AppIntents
import Foundation

// Siri and the Shortcuts app. Each intent hands a command to the player through
// AuvyCommands and says back what happened ("Shuffling Liked Songs"). Defined in
// the app, so they run in its process; the ones that start music are
// AudioPlaybackIntents so iOS lets them start it from the background. iOS 17 and
// newer, like the widgets.
//
// Android has no equivalent of Siri phrases for a third-party player; its
// counterparts are the icon's long-press menu, pinned playlist shortcuts and
// the media session's voice search (see AuvyCommands.kt).

@available(iOS 17.0, *)
enum AuvyCollection: String, AppEnum {
    case liked, weekly, top50, downloads, recent, library

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Collection"
    static let caseDisplayRepresentations: [AuvyCollection: DisplayRepresentation] = [
        .liked: DisplayRepresentation(title: "Liked Songs", synonyms: ["likes", "my likes", "favourites", "favorites", "liked"]),
        .weekly: DisplayRepresentation(title: "Weekly Discovery", synonyms: ["discovery", "my discovery", "new music"]),
        .top50: DisplayRepresentation(title: "My Top 50", synonyms: ["top 50", "top fifty", "my top songs", "most played"]),
        .downloads: DisplayRepresentation(title: "Downloads", synonyms: ["downloaded songs", "offline songs"]),
        .recent: DisplayRepresentation(title: "Recently Played", synonyms: ["recent", "history"]),
        .library: DisplayRepresentation(title: "My Library", synonyms: ["library", "everything", "all my music"]),
    ]
}

/// A playlist, by name, from the list the app keeps up to date (AuvyCommands'
/// "setPlaylists"), so Siri can offer them with Auvy closed.
@available(iOS 17.0, *)
struct AuvyPlaylistEntity: AppEntity {
    let id: String
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static let defaultQuery = AuvyPlaylistQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

@available(iOS 17.0, *)
struct AuvyPlaylistQuery: EntityStringQuery {
    private var names: [String] {
        UserDefaults.standard.stringArray(forKey: AuvyCommands.playlistsKey) ?? []
    }

    func entities(for identifiers: [String]) async throws -> [AuvyPlaylistEntity] {
        identifiers.map { AuvyPlaylistEntity(id: $0) }
    }

    func entities(matching string: String) async throws -> [AuvyPlaylistEntity] {
        let wanted = string.lowercased()
        return names.filter { $0.lowercased().contains(wanted) }.map { AuvyPlaylistEntity(id: $0) }
    }

    func suggestedEntities() async throws -> [AuvyPlaylistEntity] {
        names.map { AuvyPlaylistEntity(id: $0) }
    }
}

// The widgets' buttons (AuvyPlaybackIntents.swift, shared with the widget) can
// ask to open Auvy only from here: the protocol isn't allowed in an extension.
@available(iOS 17.0, *) extension AuvyTogglePlaybackIntent: ForegroundContinuableIntent {}
@available(iOS 17.0, *) extension AuvyNextTrackIntent: ForegroundContinuableIntent {}
@available(iOS 17.0, *) extension AuvyPreviousTrackIntent: ForegroundContinuableIntent {}
@available(iOS 17.0, *) extension AuvyToggleLikeIntent: ForegroundContinuableIntent {}
@available(iOS 17.0, *) extension AuvyPlayMixIntent: ForegroundContinuableIntent {}

@available(iOS 17.0, *)
private extension ForegroundContinuableIntent {
    /// What Siri says: the app's own answer, or [fallback] when it had none.
    func spoken(_ message: String?, _ fallback: String) -> IntentDialog {
        IntentDialog(stringLiteral: message ?? fallback)
    }
}

@available(iOS 17.0, *)
struct PlayCollectionIntent: AudioPlaybackIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Play a Library List"
    static let description = IntentDescription(
        "Plays one of your library's own lists: Liked Songs, Weekly Discovery, My Top 50, Downloads, Recently Played or everything.")

    @Parameter(title: "Collection")
    var collection: AuvyCollection

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$collection)") { \.$shuffle }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await runPlayerCommand(
            "playCollection", from: "siri", extra: ["id": collection.rawValue, "shuffle": shuffle])
        return .result(dialog: spoken(message, "Playing"))
    }
}

/// One named list, as its own action: what the Shortcuts app shows and Siri
/// answers to, without a "collection" to pick first.
@available(iOS 17.0, *)
private protocol AuvyNamedListIntent: AudioPlaybackIntent, ForegroundContinuableIntent {
    static var listId: String { get }
    static var shuffled: Bool { get }
    static var spokenName: String { get }
}

@available(iOS 17.0, *)
private extension AuvyNamedListIntent {
    func playNamedList() async throws -> IntentDialog {
        let message = try await runPlayerCommand(
            "playCollection", from: "siri", extra: ["id": Self.listId, "shuffle": Self.shuffled])
        return IntentDialog(stringLiteral: message ?? (Self.shuffled ? "Shuffling \(Self.spokenName)" : "Playing \(Self.spokenName)"))
    }
}

@available(iOS 17.0, *)
struct ShuffleLikedSongsIntent: AuvyNamedListIntent {
    static let title: LocalizedStringResource = "Shuffle Liked Songs"
    static let description = IntentDescription("Shuffles your Liked Songs in Auvy.")
    static let listId = "liked", shuffled = true, spokenName = "Liked Songs"
    func perform() async throws -> some IntentResult & ProvidesDialog { .result(dialog: try await playNamedList()) }
}

@available(iOS 17.0, *)
struct PlayWeeklyDiscoveryIntent: AuvyNamedListIntent {
    static let title: LocalizedStringResource = "Play Weekly Discovery"
    static let description = IntentDescription("Plays this week's Weekly Discovery in Auvy.")
    static let listId = "weekly", shuffled = false, spokenName = "Weekly Discovery"
    func perform() async throws -> some IntentResult & ProvidesDialog { .result(dialog: try await playNamedList()) }
}

@available(iOS 17.0, *)
struct PlayTopFiftyIntent: AuvyNamedListIntent {
    static let title: LocalizedStringResource = "Play My Top 50"
    static let description = IntentDescription("Plays your 50 most played songs in Auvy.")
    static let listId = "top50", shuffled = false, spokenName = "My Top 50"
    func perform() async throws -> some IntentResult & ProvidesDialog { .result(dialog: try await playNamedList()) }
}

@available(iOS 17.0, *)
struct ShuffleLibraryIntent: AuvyNamedListIntent {
    static let title: LocalizedStringResource = "Shuffle My Library"
    static let description = IntentDescription("Shuffles everything you've saved in Auvy: liked songs and every playlist.")
    static let listId = "library", shuffled = true, spokenName = "your library"
    func perform() async throws -> some IntentResult & ProvidesDialog { .result(dialog: try await playNamedList()) }
}

@available(iOS 17.0, *)
struct PlayPlaylistIntent: AudioPlaybackIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Play a Playlist"
    static let description = IntentDescription("Plays one of your Auvy playlists.")

    @Parameter(title: "Playlist")
    var playlist: AuvyPlaylistEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)") { \.$shuffle }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await runPlayerCommand(
            "playPlaylist", from: "siri", extra: ["name": playlist.id, "shuffle": shuffle])
        return .result(dialog: spoken(message, "Playing \(playlist.id)"))
    }
}

@available(iOS 17.0, *)
struct SearchAndPlayIntent: AudioPlaybackIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Search and Play"
    static let description = IntentDescription(
        "Finds a song, an artist or a playlist by name and plays it: your library first, then all of YouTube Music.")

    @Parameter(title: "Song, artist or playlist",
               requestValueDialog: IntentDialog("What should Auvy play?"))
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$query) in Auvy")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await runPlayerCommand("searchPlay", from: "siri", extra: ["query": query])
        return .result(dialog: spoken(message, "Playing \(query)"))
    }
}

@available(iOS 17.0, *)
struct OpenMusicLinkIntent: AudioPlaybackIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Play a Music Link"
    static let description = IntentDescription(
        "Plays a Spotify, Apple Music, YouTube or YouTube Music link in Auvy. Use it in a Share Sheet shortcut to send links from any app.")

    @Parameter(title: "Link")
    var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$url) in Auvy")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await runPlayerCommand(
            "openLink", from: "siri", extra: ["url": url.absoluteString, "background": true])
        return .result(dialog: spoken(message, "Playing the link"))
    }
}

@available(iOS 17.0, *)
struct ResumeIntent: AudioPlaybackIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Resume"
    static let description = IntentDescription("Carries on with what Auvy was playing.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await runPlayerCommand("play", from: "siri")
        return .result(dialog: spoken(message, "Resuming"))
    }
}

@available(iOS 17.0, *)
struct PauseIntent: AudioPlaybackIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Pause"
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await runPlayerCommand("pause", from: "siri")
        return .result(dialog: spoken(message, "Paused"))
    }
}

@available(iOS 17.0, *)
struct NextTrackIntent: AudioPlaybackIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Next Song"
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await runPlayerCommand("next", from: "siri")
        return .result(dialog: spoken(message, "Skipped"))
    }
}

@available(iOS 17.0, *)
struct PreviousTrackIntent: AudioPlaybackIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Previous Song"
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await runPlayerCommand("previous", from: "siri")
        return .result(dialog: spoken(message, "Going back"))
    }
}

@available(iOS 17.0, *)
struct LikeSongIntent: AudioPlaybackIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Like This Song"
    static let description = IntentDescription("Adds the song that's playing to Liked Songs, or removes it.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await runPlayerCommand("toggleLike", from: "siri")
        return .result(dialog: spoken(message, "Done"))
    }
}

/// The phrases Siri knows without any setup, and the actions the Shortcuts app
/// shows first. Every phrase names the app, as Apple requires. Ten is Apple's
/// limit; the rest (a library list, a music link, the previous song) are in the
/// Shortcuts app's full list of Auvy actions.
///
/// "Play <any song> on Auvy" is not here and can't be: iOS sends free-form
/// "Play …" requests to its own media handling, which needs the paid Siri
/// capability that SideStore can't give a free Apple ID. "Search Auvy" is the
/// way in: Siri then asks what to play.
@available(iOS 17.0, *)
struct AuvyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShuffleLikedSongsIntent(),
            phrases: [
                "Shuffle my liked songs in \(.applicationName)",
                "Shuffle my liked songs on \(.applicationName)",
                "Play my liked songs in \(.applicationName)",
                "Play my liked songs on \(.applicationName)",
                "Shuffle my likes in \(.applicationName)",
                "Start my liked songs in \(.applicationName)",
            ],
            shortTitle: "Shuffle Liked Songs",
            systemImageName: "heart.fill")
        AppShortcut(
            intent: PlayWeeklyDiscoveryIntent(),
            phrases: [
                "Play Weekly Discovery in \(.applicationName)",
                "Play Weekly Discovery on \(.applicationName)",
                "Play my Weekly Discovery in \(.applicationName)",
                "Start Weekly Discovery in \(.applicationName)",
            ],
            shortTitle: "Weekly Discovery",
            systemImageName: "sparkles")
        AppShortcut(
            intent: PlayTopFiftyIntent(),
            phrases: [
                "Play my Top 50 in \(.applicationName)",
                "Play my Top 50 on \(.applicationName)",
                "Play my top songs in \(.applicationName)",
                "Start my Top 50 in \(.applicationName)",
            ],
            shortTitle: "My Top 50",
            systemImageName: "chart.bar.fill")
        AppShortcut(
            intent: ShuffleLibraryIntent(),
            phrases: [
                "Shuffle my library in \(.applicationName)",
                "Shuffle everything in \(.applicationName)",
                "Shuffle all my music in \(.applicationName)",
            ],
            shortTitle: "Shuffle My Library",
            systemImageName: "shuffle")
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play \(\.$playlist) in \(.applicationName)",
                "Play \(\.$playlist) on \(.applicationName)",
                "Play my \(\.$playlist) playlist in \(.applicationName)",
                "Start \(\.$playlist) in \(.applicationName)",
            ],
            shortTitle: "Play a Playlist",
            systemImageName: "music.note.list")
        AppShortcut(
            intent: SearchAndPlayIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search for a song in \(.applicationName)",
                "Find a song in \(.applicationName)",
            ],
            shortTitle: "Search and Play",
            systemImageName: "magnifyingglass")
        AppShortcut(
            intent: ResumeIntent(),
            phrases: ["Resume \(.applicationName)", "Continue \(.applicationName)", "Unpause \(.applicationName)"],
            shortTitle: "Resume",
            systemImageName: "play.fill")
        AppShortcut(
            intent: PauseIntent(),
            phrases: ["Pause \(.applicationName)", "Stop \(.applicationName)"],
            shortTitle: "Pause",
            systemImageName: "pause.fill")
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: [
                "Skip this song in \(.applicationName)",
                "Next song in \(.applicationName)",
                "Skip in \(.applicationName)",
            ],
            shortTitle: "Next Song",
            systemImageName: "forward.fill")
        AppShortcut(
            intent: LikeSongIntent(),
            phrases: [
                "Like this song in \(.applicationName)",
                "Love this song in \(.applicationName)",
                "Add this song to my likes in \(.applicationName)",
            ],
            shortTitle: "Like This Song",
            systemImageName: "heart")
    }
}
