import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// The iPhone widgets. Drawn like the app's "Cover colour" mini-player: a card
// tinted from the cover, the cover with rounded corners, the accent colour on
// the play button and the progress. Buttons are AudioPlaybackIntents
// (AuvyPlaybackIntents.swift), which iOS runs inside Auvy itself; tapping the
// rest opens the playlist the song is playing from, or its album. The Android
// widgets (PlayerWidgetProvider.kt, MixesWidgetProvider.kt) share the design.
//
//   Now Playing   small, medium, large (with Up Next), and on the lock screen
//                 a line, a ring with the progress round it, and a card.
//   Your Mixes    Liked Songs, Weekly Discovery, My Top 50 and the whole
//                 library, one tap each.
//   Control       Control Center's play/pause button (iOS 18).

@main
struct AuvyWidgetBundle: WidgetBundle {
    var body: some Widget {
        AuvyNowPlayingWidget()
        AuvyMixesWidget()
        if #available(iOS 18.0, *) {
            AuvyPlaybackControl()
        }
    }
}

private let nowPlayingURL = URL(string: "auvy://nowplaying")!

// MARK: - Timeline

struct AuvyEntry: TimelineEntry {
    let date: Date
    let state: AuvyNowPlaying
    let art: UIImage?
    /// False when the app isn't signed for the shared group, so there is
    /// nothing to read; the widget then says to open Auvy.
    let connected: Bool

    /// Playing as of this entry's moment: "playing" can't outlast the song (see
    /// AuvyNowPlaying.isReallyPlaying), so the entry after the song's end draws
    /// it paused even if the app never said so.
    var playing: Bool {
        guard state.isPlaying, state.hasSong else { return false }
        guard state.durationMs > 0, state.sampledAtMs > 0 else { return true }
        return date < state.endDate.addingTimeInterval(20)
    }
}

struct AuvyTimeline: TimelineProvider {
    func placeholder(in context: Context) -> AuvyEntry {
        var sample = AuvyNowPlaying()
        sample.title = "Song"
        sample.artist = "Artist"
        sample.context = "Liked Songs"
        sample.hasSong = true
        sample.durationMs = 200_000
        sample.positionMs = 60_000
        sample.sampledAtMs = Date().timeIntervalSince1970 * 1000
        sample.upNext = ["Next song — Artist", "Another one — Artist", "And another — Artist"]
        return AuvyEntry(date: .now, state: sample, art: nil, connected: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (AuvyEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current(at: .now))
    }

    /// The app reloads the widget whenever what it shows changes. While a song
    /// plays there is one more entry just after it should have ended, drawn
    /// paused: if Auvy was killed without telling anyone, the widget still stops
    /// claiming it plays.
    func getTimeline(in context: Context, completion: @escaping (Timeline<AuvyEntry>) -> Void) {
        let now = current(at: .now)
        var entries = [now]
        if now.playing, now.state.durationMs > 0 {
            entries.append(current(at: now.state.endDate.addingTimeInterval(21)))
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    private func current(at date: Date) -> AuvyEntry {
        let state = AuvyNowPlayingStore.load()
        var art: UIImage?
        if state.hasSong, let url = AuvyNowPlayingStore.artURL {
            art = UIImage(contentsOfFile: url.path)
        }
        return AuvyEntry(date: date, state: state, art: art,
                         connected: AuvyNowPlayingStore.container != nil)
    }
}

// MARK: - Now Playing

struct AuvyNowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.auvy.app.widget.nowplaying", provider: AuvyTimeline()) { entry in
            AuvyWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("What Auvy is playing: where from, how far in, what's next, with play, skip and like.")
        // Extra large appears wherever iOS offers it (the iPad, and newer
        // iPhones' editors); elsewhere it is simply not listed.
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

struct AuvyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AuvyEntry

    private var state: AuvyNowPlaying { entry.state }
    private var playing: Bool { entry.playing }
    private var accent: Color { Color(rgb: state.accent) }
    private var title: String { state.hasSong ? state.title : "Auvy" }
    private var subtitle: String {
        if state.hasSong { return state.artist }
        return entry.connected ? "Tap to start listening" : "Open Auvy to see what's playing"
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular: rectangular
            case .accessoryCircular: circular
            case .accessoryInline: inline
            case .systemExtraLarge: extraLarge.containerBackground(for: .widget) { card }
            case .systemLarge: large.containerBackground(for: .widget) { card }
            case .systemMedium: medium.containerBackground(for: .widget) { card }
            default: small.containerBackground(for: .widget) { card }
            }
        }
        .widgetURL(nowPlayingURL)
    }

    // MARK: Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                cover(size: 58, radius: 13)
                Spacer(minLength: 4)
                playButton(size: 40)
            }
            Spacer(minLength: 6)
            contextLabel
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            if state.hasSong {
                progressBar.padding(.top, 7)
            }
        }
        .padding(14)
    }

    private var medium: some View {
        HStack(spacing: 14) {
            cover(size: 124, radius: 18)
            VStack(alignment: .leading, spacing: 0) {
                contextLabel
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if state.hasSong {
                    progressBar
                    timesRow.padding(.top, 3)
                    Spacer(minLength: 4)
                }
                controlsRow(play: 42, glyph: 16)
            }
        }
        .padding(14)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                cover(size: 112, radius: 18)
                VStack(alignment: .leading, spacing: 2) {
                    contextLabel
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if state.hasSong {
                progressBar.padding(.top, 14)
                timesRow.padding(.top, 4)
            }
            controlsRow(play: 52, glyph: 20).padding(.top, 10)
            Rectangle().fill(.white.opacity(0.10)).frame(height: 1).padding(.vertical, 12)
            upNextList
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    /// The widest: the song on the left, what's next on the right.
    private var extraLarge: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                cover(size: 150, radius: 22)
                contextLabel.padding(.top, 14)
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if state.hasSong {
                    progressBar
                    timesRow.padding(.top, 4)
                }
                controlsRow(play: 54, glyph: 20).padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(.white.opacity(0.10)).frame(width: 1)
            upNextList
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(20)
    }

    private var upNextList: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("UP NEXT")
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(.white.opacity(0.55))
            if state.upNext.isEmpty {
                Text(state.hasSong ? "Recommendations carry on after this song." : "Your next songs appear here.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                ForEach(Array(state.upNext.prefix(3).enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(accent)
                            .frame(width: 14)
                        Text(line)
                            .font(.system(size: 13.5))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// "Playing from …", small and quiet above the title.
    @ViewBuilder
    private var contextLabel: some View {
        if state.hasSong, !state.context.isEmpty {
            Text(state.context.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(accent.opacity(0.95))
                .lineLimit(1)
                .padding(.bottom, 2)
        }
    }

    /// Moves on its own while playing (iOS animates a timer interval), so the
    /// app never has to push the position.
    @ViewBuilder
    private var progressBar: some View {
        Group {
            if playing, state.durationMs > 0, state.startDate < state.endDate {
                ProgressView(timerInterval: state.startDate...state.endDate, countsDown: false,
                             label: { EmptyView() }, currentValueLabel: { EmptyView() })
            } else {
                ProgressView(value: Double(min(state.positionMs, max(state.durationMs, 1))),
                             total: Double(max(state.durationMs, 1)))
            }
        }
        .progressViewStyle(.linear)
        .tint(accent)
        .frame(height: 4)
    }

    private var timesRow: some View {
        HStack {
            Group {
                if playing, state.durationMs > 0, state.startDate < state.endDate {
                    Text(timerInterval: state.startDate...state.endDate, countsDown: false)
                } else {
                    Text(clock(state.positionMs))
                }
            }
            Spacer()
            Text(clock(state.durationMs))
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.6))
    }

    private func controlsRow(play: CGFloat, glyph: CGFloat) -> some View {
        HStack(spacing: 0) {
            if state.hasSong {
                Button(intent: AuvyPreviousTrackIntent()) { symbol("backward.fill", glyph) }
                    .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            playButton(size: play)
            if state.hasSong {
                Spacer(minLength: 0)
                Button(intent: AuvyNextTrackIntent()) { symbol("forward.fill", glyph) }
                    .buttonStyle(.plain)
                Spacer(minLength: 0)
                Button(intent: AuvyToggleLikeIntent()) {
                    Image(systemName: state.isLiked ? "heart.fill" : "heart")
                        .font(.system(size: glyph, weight: .semibold))
                        .foregroundStyle(state.isLiked ? accent : .white.opacity(0.85))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(state.isLiked ? "Remove from Liked Songs" : "Like")
            }
        }
    }

    /// The card behind it all, tinted from the cover like the mini-player's
    /// "Cover colour" style; the app's sheet colour when there's no cover.
    private var card: some View {
        let base = state.hasSong && state.tint != nil ? Color(rgb: state.tint!) : Color(rgb: 0x17171C)
        return ZStack {
            base
            LinearGradient(colors: [.white.opacity(0.08), .clear, .black.opacity(0.30)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    @ViewBuilder
    private func cover(size: CGFloat, radius: CGFloat) -> some View {
        Group {
            if let art = entry.art {
                Image(uiImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [accent.opacity(0.9), accent.opacity(0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }

    private func playButton(size: CGFloat) -> some View {
        Button(intent: AuvyTogglePlaybackIntent()) {
            ZStack {
                Circle().fill(accent)
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(Color.glyph(on: state.accent))
                    .offset(x: playing ? 0 : size * 0.03)
            }
            .frame(width: size, height: size)
            .widgetAccentable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playing ? "Pause" : "Play")
    }

    private func symbol(_ name: String, _ size: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 36, height: 36)
    }

    private func clock(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Lock screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.headline).lineLimit(1).widgetAccentable()
                    Text(subtitle).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                Button(intent: AuvyTogglePlaybackIntent()) {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 26))
                }
                .buttonStyle(.plain)
            }
            if state.hasSong {
                progressBar.frame(height: 3)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    /// The play button with the song's progress round it.
    private var circular: some View {
        Button(intent: AuvyTogglePlaybackIntent()) {
            ZStack {
                AccessoryWidgetBackground()
                if state.hasSong, state.durationMs > 0 {
                    Group {
                        if playing, state.startDate < state.endDate {
                            ProgressView(timerInterval: state.startDate...state.endDate, countsDown: false,
                                         label: { EmptyView() }, currentValueLabel: { EmptyView() })
                        } else {
                            ProgressView(value: Double(min(state.positionMs, state.durationMs)),
                                         total: Double(state.durationMs))
                        }
                    }
                    .progressViewStyle(.circular)
                    .padding(2)
                }
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
        .containerBackground(for: .widget) { Color.clear }
    }

    private var inline: some View {
        Label(state.hasSong ? "\(state.title) · \(state.artist)" : "Auvy",
              systemImage: playing ? "waveform" : "music.note")
            .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Your Mixes

struct AuvyMixesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.auvy.app.widget.mixes", provider: AuvyTimeline()) { entry in
            AuvyMixesView(entry: entry)
        }
        .configurationDisplayName("Your Mixes")
        .description("Liked Songs, Weekly Discovery, My Top 50 or everything you've saved, one tap each.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct AuvyMixesView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AuvyEntry

    private var accent: Color { Color(rgb: entry.state.accent) }

    private struct Mix: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let shuffle: Bool
    }

    private let mixes = [
        Mix(id: "liked", label: "Liked Songs", symbol: "heart.fill", shuffle: true),
        Mix(id: "weekly", label: "Weekly Discovery", symbol: "sparkles", shuffle: false),
        Mix(id: "top50", label: "My Top 50", symbol: "chart.bar.fill", shuffle: false),
        Mix(id: "library", label: "Shuffle All", symbol: "shuffle", shuffle: true),
    ]

    var body: some View {
        Group {
            if family == .systemLarge {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    VStack(spacing: 10) {
                        HStack(spacing: 10) { tile(mixes[0], tall: true); tile(mixes[1], tall: true) }
                        HStack(spacing: 10) { tile(mixes[2], tall: true); tile(mixes[3], tall: true) }
                    }
                }
                .padding(16)
            } else if family == .systemMedium {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    HStack(spacing: 8) {
                        ForEach(mixes) { tile($0, tall: true) }
                    }
                }
                .padding(14)
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 8) { tile(mixes[0], tall: false); tile(mixes[1], tall: false) }
                    HStack(spacing: 8) { tile(mixes[2], tall: false); tile(mixes[3], tall: false) }
                }
                .padding(12)
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                Color(rgb: 0x17171C)
                LinearGradient(colors: [accent.opacity(0.16), .clear, .black.opacity(0.25)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "music.note.list").font(.system(size: 12, weight: .bold))
            Text("YOUR MIXES").font(.system(size: 11, weight: .bold)).tracking(0.9)
        }
        .foregroundStyle(accent)
    }

    private func tile(_ mix: Mix, tall: Bool) -> some View {
        Button(intent: AuvyPlayMixIntent(mix: mix.id, shuffle: mix.shuffle)) {
            VStack(alignment: .leading, spacing: tall ? 8 : 4) {
                Image(systemName: mix.symbol)
                    .font(.system(size: tall ? 18 : 16, weight: .semibold))
                    .foregroundStyle(accent)
                if tall {
                    Spacer(minLength: 0)
                }
                Text(mix.label)
                    .font(.system(size: tall ? 11.5 : 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(accent.opacity(0.22), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(mix.label)")
    }
}

// MARK: - Control Center (iOS 18)

@available(iOS 18.0, *)
struct AuvyPlaybackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.auvy.app.control.playback", provider: Provider()) { value in
            ControlWidgetButton(action: AuvyTogglePlaybackIntent()) {
                Label(value.title, systemImage: value.isPlaying ? "pause.fill" : "play.fill")
            }
        }
        .displayName("Auvy")
        .description("Play or pause Auvy.")
    }

    struct Value {
        var isPlaying: Bool
        var title: String
    }

    struct Provider: ControlValueProvider {
        var previewValue: Value { Value(isPlaying: false, title: "Auvy") }

        func currentValue() async throws -> Value {
            let state = AuvyNowPlayingStore.load()
            return Value(isPlaying: state.isReallyPlaying,
                         title: state.hasSong ? state.title : "Auvy")
        }
    }
}

// MARK: - Colour helpers

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }

    /// Near-black on a light accent, white on a dark one: the play glyph stays
    /// readable whichever of the six accents (or a cover colour) is chosen.
    static func glyph(on rgb: UInt32) -> Color {
        let r = Double((rgb >> 16) & 0xFF), g = Double((rgb >> 8) & 0xFF), b = Double(rgb & 0xFF)
        let luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        return luminance > 0.62 ? Color(rgb: 0x101014) : .white
    }
}
