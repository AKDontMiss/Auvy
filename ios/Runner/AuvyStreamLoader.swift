import AVFoundation
import Foundation

/// Audio bytes downloaded over the network in this process, for Settings →
/// Storage & data.
///
/// Those figures otherwise come from Dart's HTTP client, which audio never
/// passes through (this loader has its own URLSession), so this counter fills
/// the gap, like AudioTrafficCounter on Android. Dart pulls it rather than
/// being pushed a message per transfer.
enum AuvyNetworkTally {
    private static let lock = NSLock()
    private static var bytes: Int64 = 0

    static func add(_ n: Int64) {
        lock.lock(); bytes += n; lock.unlock()
    }

    /// Bytes since the last drain, and reset.
    ///
    /// Read-and-reset, not a running total: the Dart tracker ACCUMULATES what
    /// it is handed, so reporting a cumulative figure twice would double-count
    /// and the screen would climb while nothing played.
    static func drain() -> Int64 {
        lock.lock(); let n = bytes; bytes = 0; lock.unlock(); return n
    }
}

/// One resolved stream: where the bytes are, and what the CDN needs to serve them.
struct AuvyStreamSource {
    let url: URL
    let userAgent: String?
    let contentLength: Int64
}

/// Asks Dart for a fresh stream URL — the iOS half of `resolveStream`.
protocol AuvyStreamResolving: AnyObject {
    /// A non-zero `expectContentLength` marks a MID-TRACK re-resolve, and the value
    /// is the content length of the format already playing. The answer must be that
    /// same format: a different one is a different file, and the byte offset the
    /// player is about to ask for would be meaningless in it.
    func resolveStream(videoId: String,
                       expectContentLength: Int64,
                       completion: @escaping (AuvyStreamSource?) -> Void)
    /// A native diagnostic, forwarded to Dart so it lands in the exported log.
    func note(_ message: String)
    /// Whether this file URL is currently being played or buffered by the player.
    func isURLInUse(_ url: URL) -> Bool
}

/// Fetches stream audio from googlevideo, whose URLs can expire underneath it.
///
/// The iOS counterpart of `ChunkedDataSource.kt` + media3's ResolvingDataSource:
///
///  1. **Bounded ranges.** googlevideo refuses large and open-ended ranges, so
///     every fetch is a small bounded range.
///  2. **Re-resolving mid-fetch.** Stream URLs expire and are bound to the IP
///     that resolved them, so after a Wi-Fi/mobile switch we ask Dart for a
///     fresh URL (of the same format) and carry on at the same offset.
///
/// Playback uses [downloadToFile]: the whole track is fetched to a file, then
/// played (see AuvyPlayer).
final class AuvyStreamLoader: NSObject {

    private static let minChunk: Int64 = 256 * 1024
    /// The opening bid on a healthy network.
    private static let maxChunk: Int64 = 1024 * 1024

    /// Largest chunk proven to work on this egress path this session.
    ///
    /// Ratchets DOWN when a size is rejected, so every later fetch starts at the
    /// known-good size and never re-pays the shrink-retry cost. The floor is itself a
    /// proven size, so staying there for the session is safe; a relaunch re-probes.
    private var sessionChunk: Int64 = AuvyStreamLoader.maxChunk

    // MARK: Retry budgets  (the values are Android's, and the reasons are the same)

    /// A range can answer 200 with an EMPTY body during a CDN throttle burst. Three
    /// attempts over ~1.5s rides that out; a genuinely dead range still surfaces fast.
    private static let maxEmptyRetries = 3
    /// A connectivity fault means "no network right now" — the URL is fine. Only
    /// waiting helps, so wait, because the alternative is a fatal error that makes
    /// Dart re-resolve (which also cannot reach the network) and cascade-skip.
    private static let maxNetWaitMs: Int64 = 60_000
    /// How many times one request may re-resolve before giving up. Without a
    /// bound, a URL that keeps being refused would loop forever and the track
    /// would neither play nor fail (Android's MAX_OPEN_RETRIES is the equivalent).
    private static let maxResolveAttempts = 3

    // MARK: State

    private let lock = NSLock()
    /// Keyed by a per-item token, not by videoId: the same track can be started
    /// twice in quick succession and resolve to different formats, and sharing one
    /// entry would splice bytes from two different encodes into one stream.
    private var sources: [String: AuvyStreamSource] = [:]
    /// token -> videoId for every seeded playback (used to bound the registry).
    private var tokenVideoIds: [String: String] = [:]
    private var tokenCounter: Int = 0

    /// Real network throughput, measured inside the HTTP fetches only (as
    /// ExoPlayer's bandwidth meter does). AVPlayer's `observedBitrate` drops
    /// towards zero once the item is buffered, and Dart's ladder treats anything
    /// under 40 kbps as "can't carry music".
    private var fetchedBytes: Int64 = 0
    private var fetchSeconds: Double = 0

    private weak var resolver: AuvyStreamResolving?
    private let session: URLSession
    private let queue = DispatchQueue(label: "app.auvy.streamloader",
                                      qos: .userInitiated,
                                      attributes: .concurrent)

    init(resolver: AuvyStreamResolving) {
        self.resolver = resolver
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        super.init()
    }

    // MARK: Source registry

    /// Seed the URL for one PLAYBACK of a track, returning its token.
    func newToken(videoId: String, source: AuvyStreamSource?) -> String {
        lock.lock()
        tokenCounter += 1
        let token = "\(videoId)#\(tokenCounter)"
        tokenVideoIds[token] = videoId
        if let source = source { sources[token] = source }
        // Bound the registries: a long session starts many tracks.
        if tokenVideoIds.count > 32, let oldest = tokenVideoIds.keys.sorted(by: {
            (Int($0.split(separator: "#").last ?? "0") ?? 0) < (Int($1.split(separator: "#").last ?? "0") ?? 0)
        }).first {
            tokenVideoIds.removeValue(forKey: oldest)
            sources.removeValue(forKey: oldest)
        }
        lock.unlock()
        return token
    }

    /// Replace the URL for ONE playback (a re-resolve), never for the track globally.
    func setSource(token: String, source: AuvyStreamSource) {
        lock.lock(); sources[token] = source; lock.unlock()
    }

    /// Drop every cached URL. googlevideo URLs are bound to the egress IP that
    /// resolved them, so after a network switch they all 403 at once and the next
    /// fetch must re-resolve rather than retry a URL that cannot work.
    func clearAll() {
        lock.lock()
        sources.removeAll()
        tokenVideoIds.removeAll()
        lock.unlock()
    }

    // MARK: Fetching

    private enum ChunkResult {
        case data(Data)
        /// The CDN refused this range (403/400/416). Shrink, or re-resolve.
        case rejected
        case failed(Error)
    }

    private func currentChunk() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return sessionChunk
    }

    /// Halve the chunk toward the floor. False once already there.
    private func shrinkChunk() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if sessionChunk <= AuvyStreamLoader.minChunk { return false }
        sessionChunk = max(AuvyStreamLoader.minChunk, sessionChunk / 2)
        return true
    }

    /// A ranged GET, run to completion on the calling queue.
    ///
    /// Blocking is deliberate and matches the design on both sides: this runs on our
    /// own concurrent queue, never the main thread, and the player's loader is meant
    /// to block while bytes are on the way.
    private func syncGet(url: URL, range: (Int64, Int64), userAgent: String?)
        -> (Data?, URLResponse?, Error?) {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.0)-\(range.1)", forHTTPHeaderField: "Range")
        // googlevideo 403s when the UA does not match the client that produced the URL.
        if let ua = userAgent, !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var out: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        let started = ProcessInfo.processInfo.systemUptime
        let task = session.dataTask(with: request) { data, response, error in
            out = (data, response, error)
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        // out = (data, response, error) — the closure's `error` is out of scope here.
        if out.2 == nil, let bytes = out.0?.count, bytes > 0, elapsed > 0.001 {
            lock.lock()
            fetchedBytes += Int64(bytes)
            fetchSeconds += elapsed
            lock.unlock()
        }
        // Data accounting, separate from the throughput estimate: `fetchedBytes`
        // decays on every read (it's a rolling average), so it can't be a total.
        // Counted outside the elapsed>0.001 guard, which only exists to avoid
        // dividing by ~zero; a very fast chunk still used data.
        if out.2 == nil, let bytes = out.0?.count, bytes > 0 {
            AuvyNetworkTally.add(Int64(bytes))
        }
        return out
    }

    /// Measured throughput in bits per second, or -1 when nothing has been read.
    ///
    /// Read-and-decay: the window is halved on each read so the figure tracks the
    /// link as it changes instead of averaging the whole session, while old
    /// samples still damp a single odd reading.
    func bandwidthEstimateBps() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard fetchSeconds > 0.05, fetchedBytes > 0 else { return -1 }
        let bps = Double(fetchedBytes) * 8.0 / fetchSeconds
        fetchedBytes /= 2
        fetchSeconds /= 2
        return Int(bps)
    }

    /// Resolve a URL for a token and remember it, blocking the caller's queue.
    func resolveSynchronously(token: String, videoId: String) -> AuvyStreamSource? {
        return reresolveAndStore(token: token, videoId: videoId, expect: 0)
    }

    /// Fetch a whole track to a file, using the same bounded-range ladder.
    ///
    /// AVFoundation fed through AVAssetResourceLoader parsed a correct 230s stream
    /// as 460s (the audio followed by silence). A complete file on disk is parsed
    /// like any other music file (after AuvyMP4Repair fixes the duration).
    func downloadToFile(token: String, videoId: String, source: AuvyStreamSource,
                        cancelled: @escaping () -> Bool,
                        completion: @escaping (URL?) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { completion(nil); return }
            var src = source
            if src.contentLength <= 0, let actual = self.probeTotalLength(src) {
                src = AuvyStreamSource(url: src.url, userAgent: src.userAgent, contentLength: actual)
            }
            guard src.contentLength > 0 else { completion(nil); return }

            // Named by id AND length so a different encode is a different file.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("auvy-tracks", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent("\(videoId)-\(src.contentLength).m4a")

            if let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size]) as? Int,
               Int64(size) == src.contentLength {
                AuvyPlayer.log("fetch: \(videoId) already on disk")
                // Idempotent, and needed here: a file cached before the repair
                // existed would otherwise keep playing back at double length.
                AuvyMP4Repair.repairIfFragmented(at: target)
                completion(target)
                return
            }

            self.evictCacheIfNeeded(in: dir, keeping: target)
            FileManager.default.createFile(atPath: target.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: target) else { completion(nil); return }
            defer { try? handle.close() }

            var offset: Int64 = 0
            var attempts = 0
            let started = ProcessInfo.processInfo.systemUptime
            while offset < src.contentLength {
                if cancelled() {
                    try? FileManager.default.removeItem(at: target)
                    completion(nil)
                    return
                }
                let want = min(self.currentChunk(), src.contentLength - offset)
                switch self.fetchChunkForDownload(src: src, offset: offset, length: want) {
                case .data(let data):
                    try? handle.write(contentsOf: data)
                    offset += Int64(data.count)
                case .rejected:
                    if self.shrinkChunk() { continue }
                    attempts += 1
                    if attempts > AuvyStreamLoader.maxResolveAttempts {
                        AuvyPlayer.log("fetch: giving up on \(videoId)")
                        try? FileManager.default.removeItem(at: target)
                        completion(nil)
                        return
                    }
                    guard let fresh = self.reresolve(videoId: videoId, expect: src.contentLength),
                          fresh.contentLength == src.contentLength else {
                        try? FileManager.default.removeItem(at: target)
                        completion(nil)
                        return
                    }
                    src = fresh
                case .failed:
                    try? FileManager.default.removeItem(at: target)
                    completion(nil)
                    return
                }
            }
            let secs = ProcessInfo.processInfo.systemUptime - started
            AuvyPlayer.log(String(format: "fetch: %@ %lldB in %.1fs", videoId, offset, secs))
            try? handle.close()
            AuvyMP4Repair.repairIfFragmented(at: target)
            completion(target)
        }
    }


    /// Keep the fetched-track cache bounded.
    ///
    /// Without this every track ever played stays on disk for the life of the
    /// install — invisible, unbounded, and charged to the user's storage. Oldest
    /// first by last-access, so a replayed track survives and a one-off does not.
    private static let maxCacheBytes: Int64 = 300 * 1024 * 1024

    private func evictCacheIfNeeded(in dir: URL, keeping: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentAccessDateKey, .fileSizeKey]) else { return }
        var entries: [(url: URL, accessed: Date, size: Int64)] = []
        var total: Int64 = 0
        for url in files where url != keeping {
            let values = try? url.resourceValues(forKeys: [.contentAccessDateKey, .fileSizeKey])
            let size = Int64(values?.fileSize ?? 0)
            entries.append((url, values?.contentAccessDate ?? .distantPast, size))
            total += size
        }
        guard total > AuvyStreamLoader.maxCacheBytes else { return }
        for entry in entries.sorted(by: { $0.accessed < $1.accessed }) {
            if resolver?.isURLInUse(entry.url) == true {
                AuvyPlayer.log("fetch cache: preserving active playing file \(entry.url.lastPathComponent)")
                continue
            }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
            if total <= AuvyStreamLoader.maxCacheBytes { break }
        }
        AuvyPlayer.log("fetch cache: evicted down to \(total / 1024 / 1024)MB")
    }

    /// Same retry semantics as playback, without a loading request to cancel against.
    private func fetchChunkForDownload(src: AuvyStreamSource, offset: Int64, length: Int64) -> ChunkResult {
        var emptyRetries = 0
        var netWaited: Int64 = 0
        while true {
            let (data, response, error) = syncGet(url: src.url,
                                                  range: (offset, offset + length - 1),
                                                  userAgent: src.userAgent)
            if let error = error {
                if AuvyStreamLoader.isConnectivityError(error) {
                    if netWaited >= AuvyStreamLoader.maxNetWaitMs { return .failed(error) }
                    Thread.sleep(forTimeInterval: 1.0)
                    netWaited += 1000
                    continue
                }
                return .failed(error)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 403 || status == 400 || status == 416 || status == 410 { return .rejected }
            if status < 200 || status >= 300 {
                return .failed(NSError(domain: "auvy", code: status, userInfo: nil))
            }
            guard let data = data, !data.isEmpty else {
                emptyRetries += 1
                if emptyRetries > AuvyStreamLoader.maxEmptyRetries { return .rejected }
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            return .data(data.count > Int(length) ? data.prefix(Int(length)) : data)
        }
    }

    /// The real size of what this URL serves, from Content-Range on a tiny probe.
    ///
    /// `Content-Range: bytes 0-1/5440259` names the total after the slash. Falls
    /// back to nil (keep the declared value) if the server answers without one.
    private func probeTotalLength(_ src: AuvyStreamSource) -> Int64? {
        let (_, response, error) = syncGet(url: src.url, range: (0, 1), userAgent: src.userAgent)
        guard error == nil, let http = response as? HTTPURLResponse else { return nil }
        guard let range = http.value(forHTTPHeaderField: "Content-Range"),
              let slash = range.lastIndex(of: "/") else { return nil }
        let total = range[range.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard let value = Int64(total), value > 0 else { return nil }
        return value
    }

    /// Resolve and remember, for the lazy path where nothing was seeded.
    private func reresolveAndStore(token: String, videoId: String, expect: Int64) -> AuvyStreamSource? {
        guard let fresh = reresolve(videoId: videoId, expect: expect) else { return nil }
        AuvyPlayer.log("loader: lazily resolved \(videoId) len=\(fresh.contentLength)")
        setSource(token: token, source: fresh)
        return fresh
    }

    /// Ask Dart for a fresh URL and wait for the answer.
    private func reresolve(videoId: String, expect: Int64) -> AuvyStreamSource? {
        let semaphore = DispatchSemaphore(value: 0)
        var fresh: AuvyStreamSource?
        resolver?.resolveStream(videoId: videoId, expectContentLength: expect) { result in
            fresh = result
            semaphore.signal()
        }
        // Bounded: a resolve that has not answered in 20s is not going to, and holding
        // the loader past that turns a recoverable stall into a hang.
        if semaphore.wait(timeout: .now() + 20) == .timedOut { return nil }
        return fresh
    }

    // MARK: Helpers

    /// URLSession's flavours of "the network is not there".
    private static func isConnectivityError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorTimedOut,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorDataNotAllowed:
            return true
        default:
            return false
        }
    }
}
