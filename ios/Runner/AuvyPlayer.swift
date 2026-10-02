import AVFoundation
import Flutter
import Foundation
import MediaPlayer

/// The iOS side of `com.auvy.app/native_player`.
///
/// Playback lives natively on both platforms (not in a Flutter plugin) so it
/// survives the OS trying to sleep the process. This is the counterpart of
/// `NativePlayerManager.kt` and answers the same method names with the same
/// argument shapes, so `native_audio_engine.dart` works unchanged.
///
/// Where AVPlayer can't do what ExoPlayer does (`setEqualizer`, `setPitch`,
/// `setSkipSilence`), the method says so to Dart rather than pretending.
final class AuvyPlayer: NSObject {

    static let channelName = "com.auvy.app/native_player"

    /// The live instance, so the static logger can reach the Dart channel.
    /// Weak: the logger must never be the reason this object stays alive.
    private static weak var shared: AuvyPlayer?

    private let channel: FlutterMethodChannel
    private let player = AVQueuePlayer()
    private lazy var loader = AuvyStreamLoader(resolver: self)

    /// The videoId of the item now playing, so callbacks can name it.
    private var currentVideoId: String = ""
    /// The item armed by `setUpcoming`, and the id it represents.
    private var upcomingItem: AVPlayerItem?
    private var upcomingVideoId: String = ""

    /// The next track, fetched to disk shortly before the current one ends so the
    /// change starts from a local file. Otherwise each change resolves and downloads
    /// the next track in the gap, about a second of silence (up to three). Only in
    /// the last [prefetchLeadSeconds], so a track the listener skips costs no
    /// data.
    private var upcomingSource: (videoId: String, source: AuvyStreamSource)?
    private static let prefetchLeadSeconds = 25.0
    /// The track being fetched ahead, and the plays waiting for it: a change that
    /// arrives mid-fetch waits for that fetch rather than downloading the same file
    /// again (two writers on one path corrupt it).
    private var prefetchingVideoId = ""
    private var prefetchWaiters: [(URL?) -> Void] = []
    /// Tracks fetched ahead, by video id. Small: only the next one matters.
    private var prefetchedFiles: [String: URL] = [:]


    private var metadataOutput: (AVPlayerItem, AVPlayerItemMetadataOutput)?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var volumeObservation: NSKeyValueObservation?

    /// Last reported values, so we only speak when something actually changed.
    private var lastIsPlaying = false
    private var lastBuffering = false
    /// The user's play/pause INTENT, which survives an error — unlike `isPlaying`,
    /// which has already gone false by the time a buffer underrun surfaces.
    private var playWhenReady = false
    /// Stalls since Dart last asked, read-and-cleared: the question is "has
    /// anything gone wrong since I last decided?", so a running total would keep
    /// re-triggering the same downgrade.
    private var stallCount = 0
    /// When the last seek was asked for, so its re-buffer is not a "stall".
    private var lastSeekUptime: TimeInterval = 0
    /// When playback was last started or resumed; see the stall count.
    private var lastPlayUptime: TimeInterval = 0

    // MARK: Setup

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: AuvyPlayer.channelName, binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        AuvyPlayer.shared = self
        configureAudioSession()
        observePlayer()
        registerRemoteCommands()
    }

    /// `.playback` is what keeps audio alive with the screen off. Without it — and
    /// without the `audio` background mode in Info.plist — iOS suspends the process
    /// at the first lock, which is the single most load-bearing behaviour the app has.
    private func configureAudioSession() {
        activatePlaybackSession()
        // No interruption observer here: Dart subscribes to audio_session's
        // interruption events (player_system.dart) and decides what to do on both
        // platforms; a second observer here would handle the same event twice.
        //
        // Activating the session is this class's job, though: Dart never takes audio
        // focus itself (on Android the native layer owns it too).
    }

    /// Claim the `.playback` category, and re-claim it before every start. Song
    /// recognition switches the session to `.playAndRecord` to reach the mic, and
    /// a session left in that category plays through the earpiece instead of the
    /// speaker.
    private func activatePlaybackSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback {
                try session.setCategory(.playback, mode: .default, options: [])
            }
            try session.setActive(true)
        } catch {
            note("audio session setup failed: \(error.localizedDescription)")
        }
    }

    private func observePlayer() {
        // ~2Hz, matching the Android feed the UI clock is built around.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main) { [weak self] _ in self?.emitPosition() }

        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            guard let self = self else { return }
            let playing = p.timeControlStatus == .playing
            if playing != self.lastIsPlaying {
                self.lastIsPlaying = playing
                AuvyPlayer.log("timeControlStatus -> \(p.timeControlStatus.rawValue) isPlaying=\(playing)")
                self.send("onIsPlayingChanged",
                          ["isPlaying": playing, "playWhenReady": self.playWhenReady])
            }
            // AVPlayer reports a stall as "waiting to play at the specified rate",
            // which is the same signal ExoPlayer calls BUFFERING. The raw edge goes
            // to Dart; how long a stall must last to be worth mentioning is the
            // listener's decision, not ours.
            let buffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
            if buffering != self.lastBuffering {
                self.lastBuffering = buffering
                // Only a MID-TRACK stall counts, as in NativePlayerManager: track
                // starts and item ends pass through this state too, and counting
                // them walked the bitrate ladder down a rung per track change.
                let position = p.currentTime().seconds
                let duration = p.currentItem?.duration.seconds ?? .nan
                let atEnd = duration.isFinite && position >= duration - 1
                // A seek re-buffers too, and says nothing about the network.
                // Listen Together seeks a guest often, so without this each
                // correction cost a rung of audio quality.
                let afterSeek = ProcessInfo.processInfo.systemUptime - self.lastSeekUptime < 2
                // Starting or resuming passes through the same wait while AVPlayer
                // prerolls (a few hundred ms, from a local file); without this, each
                // resume after a pause would count as a stall and cost a rung.
                let afterPlay = ProcessInfo.processInfo.systemUptime - self.lastPlayUptime < 2
                if buffering && self.playWhenReady && position.isFinite && position > 3
                    && !atEnd && !afterSeek && !afterPlay {
                    self.stallCount += 1
                }
                self.send("onBuffering", ["buffering": buffering])
            }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(itemDidEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(itemFailed(_:)),
            name: .AVPlayerItemFailedToPlayToEndTime, object: nil)

        // Media volume reaching zero, for the "pause when muted" setting. Only the
        // change to 0 is sent, not repeats while muted.
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) {
            [weak self] session, _ in
            if session.outputVolume <= 0.0001 { self?.send("onVolumeMuted", nil) }
        }
    }

    /// Deliberately empty: audio_service owns the remote commands on iOS
    /// (AudioServicePlugin registers them on MPRemoteCommandCenter and routes them
    /// to Dart). A second set here would make one lock-screen or headset press
    /// act twice, and since Dart's togglePlay is relative the two would fight.
    private func registerRemoteCommands() {}

    // MARK: Channel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "playVideo":
            playVideo(args)
            result(nil)

        case "pause":
            pause(); result(nil)

        case "resume":
            resume(); result(nil)

        case "stop":
            playWhenReady = false
            // Invalidate any in-flight fetch: otherwise a fetch that finishes after
            // Dart said stop would still pass the generation check and start playing.
            playGeneration += 1
            player.pause()
            player.removeAllItems()
            currentVideoId = ""
            send("onBuffering", ["buffering": false])
            result(nil)

        case "seek":
            let ms = (args["positionMs"] as? NSNumber)?.int64Value ?? 0
            lastSeekUptime = ProcessInfo.processInfo.systemUptime
            player.seek(to: CMTime(value: ms, timescale: 1000),
                        toleranceBefore: .zero, toleranceAfter: .zero)
            result(nil)

        case "setSpeed":
            let speed = (args["speed"] as? NSNumber)?.floatValue ?? 1.0
            // Pitch stays constant through a rate change because every item is
            // created with `.spectral` (see start). Not reassigned here: the
            // algorithm is fixed per item, and switching it mid-play can click.
            // An unchanged speed is not re-applied: every rate assignment
            // reconfigures the time-stretch, which is audible.
            //
            // Applied whenever the player means to play (rate is non-zero, including
            // while it waits on data), not only while it is audibly playing: otherwise
            // a change sent during a brief wait is only stored for the next play, and
            // Dart, believing it applied, never sends it again. A paused player
            // (rate 0) picks up currentSpeed when it resumes.
            if player.rate != 0 && abs(player.rate - speed) > 0.0001 {
                player.rate = speed
                if abs(player.rate - speed) > 0.001 {
                    note("rate \(speed) not taken (player at \(player.rate))")
                }
            }
            currentSpeed = speed
            result(nil)

        case "setVolume":
            player.volume = (args["volume"] as? NSNumber)?.floatValue ?? 1.0
            result(nil)

        case "setUpcoming":
            setUpcoming(args); result(nil)

        case "advanceToUpcoming":
            result(advanceToUpcoming(args["videoId"] as? String ?? ""))

        case "clearUpcoming":
            clearUpcoming(); result(nil)

        case "prewarmNext":
            // Dart warms the next track this way when the gapless setting is off.
            // iOS has no play-cache to pull a first megabyte into and never queues
            // the item anyway, so both paths do the same thing: fetch the next file
            // ahead (see setUpcoming).
            setUpcoming(args)
            result(nil)

        // The pull half of AuvyNetworkTally — see its note in
        // AuvyStreamLoader. Android has the identical method name on the
        // same channel, so the Dart side needs no platform branch.
        case "drainAudioBytes":
            result(NSNumber(value: AuvyNetworkTally.drain()))
            return

        case "clearUrlCache":
            loader.clearAll(); result(nil)

        case "repairAudioFile":
            // Repair a file Dart downloaded as soon as it lands, not only at first play
            // (playVideo repairs too). A download is a file the user keeps and may open
            // in other apps, so the file itself should carry the correct duration, and
            // the tag writer and later duration probes then see the repaired version.
            //
            // Answers `false` for "nothing needed doing" (e.g. a podcast or an
            // already-repaired file), which is not an error.
            if let path = args["path"] as? String, !path.isEmpty {
                result(AuvyMP4Repair.repairIfFragmented(at: URL(fileURLWithPath: path)))
            } else {
                result(false)
            }

        case "promoteFromPlayCache":
            // "Save from stream", as on Android: copy a track we already fetched instead
            // of downloading it again. Every played track sits complete (and repaired) in
            // tmp/auvy-tracks.
            let args = call.arguments as? [String: Any] ?? [:]
            let videoId = args["videoId"] as? String ?? ""
            let targetPath = args["targetPath"] as? String ?? ""
            let wanted = (args["contentLength"] as? NSNumber)?.int64Value ?? 0
            guard !videoId.isEmpty, !targetPath.isEmpty, !videoId.hasPrefix("http") else {
                result(["promoted": false, "reason": "invalid"]); return
            }
            DispatchQueue.global(qos: .utility).async {
                let answer = AuvyPlayer.promoteFetchedTrack(
                    videoId: videoId, to: URL(fileURLWithPath: targetPath), wanted: wanted)
                DispatchQueue.main.async { result(answer) }
            }

        case "isMusicActive":
            result(AVAudioSession.sharedInstance().isOtherAudioPlaying)

        case "getNetworkStats":
            result(networkStats())

        case "setEqualizer", "setPitch", "setSkipSilence", "setNormalizationGain":
            result(unsupportedDSP(call.method))

        // Output routing. iOS does not let an app choose its output device — the
        // system route picker owns that — so these answer honestly rather than
        // pretending a selection was made.
        case "route":
            result(currentRouteName())
        case "carMode":
            result(isCarRoute())
        case "listOutputs":
            // iOS cannot enumerate AVAILABLE outputs — only the route in use, and
            // an app may not switch to a named device; the system route picker owns
            // that. Returning nothing made the sheet say it could not read the
            // device's outputs, which is wrong: we know exactly what audio is
            // coming out of. So report the ACTIVE route, marked as the current
            // selection, and let the sheet's system-picker link do the choosing.
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            result(outputs.enumerated().map { index, port in
                [
                    "id": index,
                    "name": port.portName,
                    "kind": AuvyPlayer.kind(for: port.portType),
                    // The active route IS the selection on iOS; nothing else can be.
                    "isPreferred": true,
                    "isDefault": port.portType == .builtInSpeaker,
                    "isCar": port.portType == .carAudio,
                ]
            })

        case "watchOutputs", "setOutput":
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private var currentSpeed: Float = 1.0

    // MARK: Playback

    private func source(from args: [String: Any]) -> AuvyStreamSource? {
        guard let urlString = args["url"] as? String, let url = URL(string: urlString) else { return nil }
        return AuvyStreamSource(
            url: url,
            userAgent: args["userAgent"] as? String,
            contentLength: AuvyPlayer.int64(args["contentLength"]))
    }

    /// contentLength arrives as an int from `playVideo` but as a String ("0" by
    /// default) from the resolver's reply, so accept both. Reading only NSNumber
    /// would yield 0 for the string form, and a length of 0 means an open-ended
    /// request, which googlevideo refuses.
    private static func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) ?? 0 }
        return 0
    }

    // Tracks are fetched to a complete file and repaired (see AuvyStreamLoader)
    // rather than played through AVAssetResourceLoader, which mis-parsed
    // YouTube's fragmented MP4s and reported double the real duration.

    /// Bumped on every start, so a fetch that finishes after the user has moved
    /// on is discarded instead of hijacking the player.
    private var playGeneration: Int = 0

    private func playVideo(_ args: [String: Any]) {
        let videoId = args["videoId"] as? String ?? ""
        let autoPlay = args["autoPlay"] as? Bool ?? true
        playGeneration += 1
        let generation = playGeneration
        currentVideoId = videoId
        clearUpcoming()

        // A downloaded file, or a podcast/radio stream with no length to fetch by.
        //
        // Downloads and the auto-cache are the same DASH-fragmented MP4s as streamed
        // tracks, so they need the same duration repair before playing (see
        // AuvyMP4Repair). The repair is a no-op for anything that isn't a fragmented
        // MP4 or is already repaired, and it reads only box headers, so it's cheap
        // enough to run inline.
        if let localPath = args["localPath"] as? String, !localPath.isEmpty {
            let fileURL = URL(fileURLWithPath: localPath)
            AuvyMP4Repair.repairIfFragmented(at: fileURL)
            // A fetch for the previous track may still be in flight; its completion is
            // discarded by the generation check and won't send this, so send it here or
            // the UI keeps spinning.
            send("onBuffering", ["buffering": false])
            start(AVPlayerItem(url: fileURL), autoPlay: autoPlay)
            return
        }
        guard let src = source(from: args) else {
            // No URL yet: resolve, then fetch, on the loader's queue.
            fetchThenPlay(videoId: videoId, source: nil, generation: generation, autoPlay: autoPlay)
            return
        }
        if src.contentLength <= 0 {
            // Live radio: no length, nothing to fetch ahead, stream it.
            AuvyPlayer.log("playVideo \(videoId): direct stream (no length)")
            send("onBuffering", ["buffering": false])
            start(AVPlayerItem(url: src.url), autoPlay: autoPlay)
            return
        }
        fetchThenPlay(videoId: videoId, source: src, generation: generation, autoPlay: autoPlay)
    }

    /// Fetch the whole track to disk, then play the file.
    ///
    /// Slower to start than streaming, and worth it: fed through the resource
    /// loader, AVFoundation parsed a byte-perfect 230s stream as 460s and played
    /// the music followed by an equal stretch of silence. Podcasts never showed it
    /// because they have no content length and so never used that path at all.
    private func fetchThenPlay(videoId: String, source: AuvyStreamSource?,
                               generation: Int, autoPlay: Bool) {
        playWhenReady = autoPlay
        // Fetched ahead (see prefetch): start from that file, or wait for the fetch
        // that is still writing it.
        if let file = prefetchedFiles.removeValue(forKey: videoId),
           FileManager.default.fileExists(atPath: file.path) {
            AuvyPlayer.log("playVideo \(videoId): fetched ahead, starting from disk")
            send("onBuffering", ["buffering": false])
            start(AVPlayerItem(url: file), autoPlay: autoPlay)
            return
        }
        if videoId == prefetchingVideoId {
            send("onBuffering", ["buffering": true])
            prefetchWaiters.append { [weak self] url in
                guard let self = self, self.playGeneration == generation else { return }
                if let url = url {
                    self.send("onBuffering", ["buffering": false])
                    self.start(AVPlayerItem(url: url), autoPlay: autoPlay)
                } else {
                    self.fetchThenPlay(videoId: videoId, source: source,
                                       generation: generation, autoPlay: autoPlay)
                }
            }
            return
        }
        send("onBuffering", ["buffering": true])
        let token = loader.newToken(videoId: videoId, source: source)

        let resolve: () -> AuvyStreamSource? = { [weak self] in
            guard let self = self else { return nil }
            if let source = source { return source }
            return self.loader.resolveSynchronously(token: token, videoId: videoId)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let src = resolve() else {
                DispatchQueue.main.async {
                    // Same check as the download below: if another track started
                    // meanwhile, this failure is the old track's. Reported, it would
                    // make Dart heal the new track (restarting it and distrusting its
                    // good local copy).
                    guard let self = self, self.playGeneration == generation else { return }
                    self.send("onBuffering", ["buffering": false])
                    self.send("onPlayerError", ["playWhenReady": autoPlay])
                }
                return
            }
            self.loader.downloadToFile(
                token: token, videoId: videoId, source: src,
                cancelled: { [weak self] in self?.playGeneration != generation }
            ) { [weak self] fileURL in
                DispatchQueue.main.async {
                    guard let self = self, self.playGeneration == generation else { return }
                    self.send("onBuffering", ["buffering": false])
                    guard let fileURL = fileURL else {
                        self.send("onPlayerError", ["playWhenReady": autoPlay])
                        return
                    }
                    self.start(AVPlayerItem(url: fileURL), autoPlay: autoPlay)
                }
            }
        }
    }

    private func start(_ item: AVPlayerItem, autoPlay: Bool) {
        // Log the duration read straight from the asset (before any player touches
        // it), to tell whether a wrong duration comes from the file, the
        // AVPlayerItem, or the session.
        if let url = (item.asset as? AVURLAsset)?.url {
            let session = AVAudioSession.sharedInstance()
            AuvyPlayer.log(String(format: "session: rate=%.0fHz ioBuf=%.4fs out=%d route=%@",
                                  session.sampleRate, session.ioBufferDuration,
                                  session.outputNumberOfChannels,
                                  session.currentRoute.outputs.first?.portType.rawValue ?? "?"))
            Task {
                let asset = AVURLAsset(url: url)
                if let d = try? await asset.load(.duration) {
                    AuvyPlayer.log(String(format: "asset duration (direct): %.1fs", CMTimeGetSeconds(d)))
                }
            }
        }
        // Use the spectral time-pitch algorithm, set before the item plays.
        // `.timeDomain` is tuned for speech and warbles on music at any rate other
        // than 1.0 (Listen Together nudges guests to 0.97–1.06x). Setting it here
        // means it never changes mid-playback, which could click.
        item.audioTimePitchAlgorithm = .spectral
        player.removeAllItems()
        player.insert(item, after: nil)
        observeItem(item)
        playWhenReady = autoPlay
        if autoPlay {
            activatePlaybackSession()
            lastPlayUptime = ProcessInfo.processInfo.systemUptime
            player.playImmediately(atRate: currentSpeed)
        }
    }

    /// Live radio announces the current track in the stream itself (ICY).
    /// Attached only for remote streams, and only one output at a time, so
    /// outputs don't pile up over a long session.
    private func observeIcyMetadata(on item: AVPlayerItem) {
        detachMetadataOutput()
        guard (item.asset as? AVURLAsset)?.url.isFileURL == false else { return }
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(self, queue: .main)
        item.add(output)
        metadataOutput = (item, output)
    }

    private func detachMetadataOutput() {
        if let (item, output) = metadataOutput { item.remove(output) }
        metadataOutput = nil
    }

    private func observeItem(_ item: AVPlayerItem) {
        observeIcyMetadata(on: item)
        // KVO delivers the same resolved duration two or three times per item;
        // the track inspection below is async asset work, so it runs once.
        var reported = -1.0
        durationObservation = item.observe(\.duration, options: [.new]) { i, _ in
            let seconds = CMTimeGetSeconds(i.duration)
            guard seconds.isFinite, seconds > 0, seconds != reported else { return }
            reported = seconds
            AuvyPlayer.log(String(format: "item duration resolved: %.1fs", seconds))
            // Log what the container says (sample rate, timescale), which tells an
            // HE-AAC/SBR misparse (decoder running at twice the core rate) apart from a
            // file that really is that long.
            Task {
                guard let track = try? await i.asset.loadTracks(withMediaType: .audio).first
                else { return }
                let rate = (try? await track.load(.estimatedDataRate)) ?? 0
                let scale = (try? await track.load(.naturalTimeScale)) ?? 0
                let range = (try? await track.load(.timeRange)) ?? .zero
                var sampleRate: Double = 0
                var formatID: FourCharCode = 0
                var framesPerPacket: UInt32 = 0
                if let descs = try? await track.load(.formatDescriptions) {
                    for d in descs {
                        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d) {
                            sampleRate = asbd.pointee.mSampleRate
                            formatID = asbd.pointee.mFormatID
                            framesPerPacket = asbd.pointee.mFramesPerPacket
                        }
                    }
                }
                // mFormatID identifies the codec; mFramesPerPacket reveals SBR: LC-AAC packs
                // 1024 frames per packet, HE-AAC 2048.
                let codec = String(format: "%c%c%c%c",
                                   (formatID >> 24) & 0xff, (formatID >> 16) & 0xff,
                                   (formatID >> 8) & 0xff, formatID & 0xff)
                AuvyPlayer.log(String(
                    format: "  track: codec=%@ framesPerPacket=%u sampleRate=%.0fHz timescale=%d dataRate=%.0fbps trackDur=%.1fs",
                    codec, framesPerPacket, sampleRate, scale, rate, CMTimeGetSeconds(range.duration)))
            }
        }
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] i, _ in
            guard let self = self, i.status == .failed else { return }
            let reason = i.error?.localizedDescription ?? "unknown"
            AuvyPlayer.log("ITEM FAILED: \(reason)")
            self.note("item failed: \(reason)")
            self.send("onPlayerError", ["playWhenReady": self.playWhenReady])
        }
    }

    private func pause() {
        playWhenReady = false
        player.pause()
        reassertState()
    }

    /// Tell Dart the actual playing state, even when nothing changed.
    ///
    /// `onIsPlayingChanged` only fires on a KVO change, and Dart's play()/pause()
    /// are guarded on its own isPlaying (togglePlay is relative), so once the two
    /// sides disagree nothing corrects it. Restating after each explicit command
    /// keeps them in sync.
    private func reassertState() {
        let playing = player.timeControlStatus == .playing
        lastIsPlaying = playing
        AuvyPlayer.log("reassert isPlaying=\(playing) playWhenReady=\(playWhenReady)")
        send("onIsPlayingChanged", ["isPlaying": playing, "playWhenReady": playWhenReady])
    }

    private func resume() {
        playWhenReady = true
        activatePlaybackSession()
        lastPlayUptime = ProcessInfo.processInfo.systemUptime
        player.playImmediately(atRate: currentSpeed)
        reassertState()
    }

    // MARK: Gapless

    /// The upcoming track is NOT inserted into the AVQueuePlayer on iOS.
    ///
    /// A queued item would give a seamless join, but AVQueuePlayer's end-of-item
    /// signal doesn't reliably say whether currentItem has already swapped, so the
    /// track boundary would have to be guessed. Everything that happens at a
    /// boundary (crediting the play, caching, queue bookkeeping, the UI) depends
    /// on it, so the boundary stays with Dart: the item ends, Dart hears
    /// onTrackEnded and starts the next track. Its file is fetched ahead instead
    /// (see [upcomingSource]), so the start is still close to seamless.
    private func setUpcoming(_ args: [String: Any]) {
        let videoId = args["videoId"] as? String ?? ""
        guard !videoId.isEmpty else { return }
        // A downloaded track is already a file, and without a URL there is nothing to
        // fetch; either way the change goes the ordinary way.
        let local = args["localPath"] as? String ?? ""
        guard local.isEmpty, let src = source(from: args) else {
            upcomingSource = nil
            return
        }
        upcomingSource = (videoId, src)
        AuvyPlayer.log("setUpcoming \(videoId): fetched ahead near the end, NOT queued (see the note)")
    }

    /// Starts fetching the upcoming track once the current one is in its last
    /// seconds. Called with every position update.
    private func prefetchIfDue(position: Double, duration: Double) {
        guard let up = upcomingSource, prefetchingVideoId.isEmpty,
              position.isFinite, duration.isFinite, duration > 0,
              duration - position < AuvyPlayer.prefetchLeadSeconds,
              player.timeControlStatus == .playing else { return }
        upcomingSource = nil
        if let file = prefetchedFiles[up.videoId], FileManager.default.fileExists(atPath: file.path) {
            return
        }
        let videoId = up.videoId
        prefetchingVideoId = videoId
        let token = loader.newToken(videoId: videoId, source: up.source)
        loader.downloadToFile(token: token, videoId: videoId, source: up.source,
                              cancelled: { false }) { [weak self] url in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let url = url {
                    if self.prefetchedFiles.count >= 4 { self.prefetchedFiles.removeAll() }
                    self.prefetchedFiles[videoId] = url
                }
                AuvyPlayer.log(url != nil
                    ? "prefetch: \(videoId) on disk before its turn"
                    : "prefetch: \(videoId) failed — it is fetched when it plays")
                if self.prefetchingVideoId == videoId { self.prefetchingVideoId = "" }
                let waiters = self.prefetchWaiters
                self.prefetchWaiters = []
                waiters.forEach { $0(url) }
            }
        }
    }

    /// Jump to an already-buffered upcoming item instead of preparing it again.
    ///
    /// Always false on iOS, since nothing is armed in the queue (see
    /// [setUpcoming]). Dart reads false as "prepare the track the ordinary way",
    /// which is what should happen.
    private func advanceToUpcoming(_ videoId: String) -> Bool {
        return false
    }

    /// Drop the armed item on skip/prev/reorder/remove, so the player cannot roll
    /// into a track that is no longer next.
    private func clearUpcoming() {
        // NEVER remove the item that is now playing.
        //
        // If the queue already advanced into the armed item, `upcomingItem` IS the
        // current item, and removing it would tear out the track under the
        // listener — silence, mid-song, from a call that only meant "forget what
        // comes next".
        if let item = upcomingItem, item !== player.currentItem {
            player.remove(item)
        }
        upcomingItem = nil
        upcomingVideoId = ""
        // A fetch already running finishes into the cache; only the pending one is
        // forgotten.
        upcomingSource = nil
    }

    // MARK: Events

    private func emitPosition() {
        guard let item = player.currentItem else { return }
        let position = CMTimeGetSeconds(player.currentTime())
        let duration = CMTimeGetSeconds(item.duration)
        prefetchIfDue(position: position, duration: duration)
        send("onPosition", [
            "positionMs": Int(max(0, position.isFinite ? position : 0) * 1000),
            "durationMs": Int(max(0, duration.isFinite ? duration : 0) * 1000),
            "isPlaying": player.timeControlStatus == .playing,
        ])
    }

    @objc private func itemDidEnd(_ notification: Notification) {
        guard let ended = notification.object as? AVPlayerItem else { return }

        // Nothing is ever armed in the queue, so every end is a plain end and Dart
        // decides what happens next.
        AuvyPlayer.log("item ended -> onTrackEnded")
        send("onTrackEnded", nil)
    }

    @objc private func itemFailed(_ notification: Notification) {
        send("onPlayerError", ["playWhenReady": playWhenReady])
    }


    // MARK: Stats and routing

    /// What the network is actually doing, for the adaptive bitrate ladder.
    ///
    /// `-1` means "not measured yet" and is deliberately distinguishable from a bad
    /// reading — treating "don't know" as "bad" makes every cold start begin at the
    /// lowest quality. The stall count is read-and-cleared.
    private func networkStats() -> [String: Any] {
        // From the loader, the only place that touches the network. AVPlayer's
        // observedBitrate describes the player rather than the link, and a reading
        // under 40 kbps would drop Dart's quality ladder straight to its floor.
        let estimate = loader.bandwidthEstimateBps()
        let stalls = stallCount
        stallCount = 0
        AuvyPlayer.log("networkStats: estimate=\(estimate)bps stalls=\(stalls)")
        return ["bitrateEstimate": estimate, "stalls": stalls]
    }

    /// Map an iOS port type onto the `kind` strings audio_output_service expects.
    static func kind(for port: AVAudioSession.Port) -> String {
        switch port {
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "bluetooth"
        case .headphones, .headsetMic: return "headphones"
        case .usbAudio: return "usb"
        case .HDMI, .airPlay: return "hdmi"
        case .builtInSpeaker, .builtInReceiver: return "speaker"
        default: return "other"
        }
    }

    private func currentRouteName() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? ""
    }

    private func isCarRoute() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
    }

    /// AVPlayer exposes no equalizer, no independent pitch shift and no silence
    /// trimmer. Honouring these would mean decoding through AVAudioEngine, which
    /// cannot stream from a URL the way this player must. Reported, not silently
    /// swallowed, so the setting can be hidden rather than appear to work.
    /// Methods already reported as unavailable, so each is noted once per launch
    /// (Dart sends the normalization gain with every track).
    private var reportedUnsupported = Set<String>()

    private func unsupportedDSP(_ method: String) -> Any? {
        if reportedUnsupported.insert(method).inserted {
            note("\(method) is not available on iOS (AVPlayer has no DSP chain)")
        }
        return nil
    }

    /// Copy a complete fetched track to `target`.
    ///
    /// AuvyStreamLoader names fetched files `<id>-<length>.m4a`, and a file is
    /// complete exactly when its size equals the length in its name, so a partial
    /// file can never be promoted. With several encodes on disk, the one Dart
    /// asked for wins, otherwise the largest (best bitrate). Copied, not moved,
    /// because it may be playing right now.
    static func promoteFetchedTrack(videoId: String, to target: URL, wanted: Int64) -> [String: Any] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("auvy-tracks", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            return ["promoted": false, "reason": "not fetched"]
        }
        let prefix = "\(videoId)-"
        var best: (url: URL, length: Int64)?
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".m4a") {
            let lengthText = name.dropFirst(prefix.count).dropLast(".m4a".count)
            guard let declared = Int64(lengthText), declared > 0 else { continue }
            let url = dir.appendingPathComponent(name)
            let size = ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
            guard size == declared else { continue }
            if wanted > 0 && declared == wanted { best = (url, declared); break }
            if best == nil || declared > best!.length { best = (url, declared) }
        }
        guard let source = best else { return ["promoted": false, "reason": "not fetched"] }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source.url, to: target)
        } catch {
            try? fm.removeItem(at: target)
            return ["promoted": false, "reason": "copy failed: \(error.localizedDescription)"]
        }
        AuvyPlayer.log("promote: \(videoId) copied from the stream cache (\(source.length)B) — no download")
        return ["promoted": true, "bytes": source.length]
    }

    // MARK: Plumbing

    /// A native diagnostic, written where it can be exported. Three destinations,
    /// because each is unreliable in a different way:
    ///
    ///  • `onNativeNote` → Dart's `logEvent` → the app's own log, which is what
    ///    users export (as on Android). Prefixed `native:` by the Dart handler.
    ///  • the console (see [console]), for a `devicectl --console` session.
    ///  • a file in Application Support, which survives a dropped connection and
    ///    can be pulled with `devicectl device copy from`.
    static func log(_ message: String) {
        console(message)
        logQueue.async { appendToLogFile(message) }
        shared?.note(message)
    }

    /// NSLog in DEBUG, stderr otherwise. NSLog writes to the persistent unified
    /// log (included in sysdiagnose), and these lines are timestamped video ids,
    /// i.e. listening history, so release builds keep them out of it. stderr still
    /// shows up under `devicectl device process launch --console`.
    private static func console(_ message: String) {
        #if DEBUG
        NSLog("[Auvy] %@", message)
        #else
        FileHandle.standardError.write(Data("[Auvy] \(message)\n".utf8))
        #endif
    }

    /// Also written to a file, since a `devicectl --console` session can drop
    /// and take the output with it.
    private static let logQueue = DispatchQueue(label: "app.auvy.nativelog")
    private static let maxLogBytes = 512 * 1024

    /// In APPLICATION SUPPORT, not Documents: Documents is published in the Files
    /// app, and this file is a timestamped list of every video id played. It is
    /// still pulled over USB with `--source "Library/Application Support/auvy-native.log"`.
    private static let logFileURL: URL? = {
        let fm = FileManager.default
        if let legacy = fm.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("auvy-native.log") {
            try? fm.removeItem(at: legacy)
        }
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("auvy-native.log")
    }()

    private static func appendToLogFile(_ message: String) {
        guard let url = logFileURL,
              let data = "\(Date().timeIntervalSince1970) \(message)\n".data(using: .utf8)
        else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            try? data.write(to: url)
            return
        }
        // Bounded: start over rather than grow without limit on a long session.
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
        if size > maxLogBytes {
            try? data.write(to: url)
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private func send(_ method: String, _ arguments: Any?) {
        if Thread.isMainThread {
            channel.invokeMethod(method, arguments: arguments)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.channel.invokeMethod(method, arguments: arguments)
            }
        }
    }

    deinit {
        if let observer = timeObserver { player.removeTimeObserver(observer) }
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Resolving stream URLs from Dart

extension AuvyPlayer: AuvyStreamResolving {

    func resolveStream(videoId: String, expectContentLength: Int64,
                       completion: @escaping (AuvyStreamSource?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { completion(nil); return }
            self.channel.invokeMethod("resolveStream", arguments: [
                "videoId": videoId,
                "expectContentLength": expectContentLength,
            ]) { reply in
                guard let map = reply as? [String: Any],
                      let urlString = map["url"] as? String,
                      let url = URL(string: urlString) else {
                    completion(nil); return
                }
                // Fall back to the length already playing: a same-format re-resolve is the
                // same file, so the previous length still describes it.
                let resolved = AuvyPlayer.int64(map["contentLength"])
                completion(AuvyStreamSource(
                    url: url,
                    userAgent: map["userAgent"] as? String,
                    contentLength: resolved > 0 ? resolved : expectContentLength))
            }
        }
    }

    /// A native diagnostic, forwarded so it appears in the app's exported log
    /// rather than only the Xcode console.
    func note(_ message: String) {
        send("onNativeNote", ["msg": message])
    }

    /// Whether this file URL is currently loaded or queued in AVPlayer.
    func isURLInUse(_ url: URL) -> Bool {
        let check = { () -> Bool in
            for item in self.player.items() {
                if let assetURL = (item.asset as? AVURLAsset)?.url,
                   assetURL.standardizedFileURL == url.standardizedFileURL {
                    return true
                }
            }
            if let assetURL = (self.upcomingItem?.asset as? AVURLAsset)?.url,
               assetURL.standardizedFileURL == url.standardizedFileURL {
                return true
            }
            return false
        }
        if Thread.isMainThread {
            return check()
        } else {
            return DispatchQueue.main.sync(execute: check)
        }
    }
}


// MARK: - ICY stream metadata

extension AuvyPlayer: AVPlayerItemMetadataOutputPushDelegate {

    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        var streamTitle: String?
        var stationName: String?
        for group in groups {
            for item in group.items {
                guard let value = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { continue }
                switch item.identifier {
                case AVMetadataIdentifier.icyMetadataStreamTitle:
                    streamTitle = value
                case AVMetadataIdentifier.icyMetadataStreamURL:
                    stationName = value
                default:
                    // Some stations carry the title under the common key instead.
                    if item.commonKey == .commonKeyTitle, streamTitle == nil { streamTitle = value }
                }
            }
        }
        guard streamTitle != nil || stationName != nil else { return }
        send("onIcyMetadata", [
            "streamTitle": streamTitle as Any,
            "stationName": stationName as Any,
            "genre": NSNull(),
            "bitrate": NSNull(),
        ])
    }
}
