import AVFoundation
import MediaToolbox
import os

/// The equaliser and the loudness trim on iOS, applied inside AVPlayer.
///
/// AVPlayer has no effect chain, but an MTAudioProcessingTap on an item's audio
/// mix is handed every decoded buffer before it is played. That is enough for a
/// five-band equaliser and a gain stage, without swapping the player for
/// AVAudioEngine (which cannot play the files this player fetches the way it
/// does). The bands match Android's: 60, 230, 910, 3600 and 14000 Hz, ±12 dB, so
/// the Settings sliders mean the same thing on both phones.
///
/// Attached only while something is switched on. With the equaliser off and no
/// loudness correction, items play exactly as they did before this existed.
final class AuvyAudioTap {

    static let shared = AuvyAudioTap()

    /// Read by the render thread; see [AuvyTapSettings].
    let settings = AuvyTapSettings()

    private var eqOn = false
    private var bands: [Float] = [0, 0, 0, 0, 0]
    private var normalizationOn = false
    private var normalizationGainMb = 0
    private var meteringOn = false

    /// Whether the tap is wanted: some processing would change the sound, or
    /// the player cover's glow is following the music ([setMetering]).
    var isNeeded: Bool {
        (eqOn && bands.contains { abs($0) > 0.05 }) || (normalizationOn && normalizationGainMb != 0)
            || meteringOn
    }

    /// How loud the music is right now (RMS of the last buffer, 0...1), for the
    /// player cover's glow. 0 while metering is off or nothing plays.
    var level: Float { meteringOn ? settings.level : 0 }

    /// The glow follows the music only while the player is on screen, so the
    /// tap measures only then. Turned on mid-song, the tap goes onto the
    /// playing item; turned off, it stays there harmlessly until the next one.
    func setMetering(_ on: Bool, item: AVPlayerItem?) {
        meteringOn = on
        settings.setMetering(on)
        if on { attachIfNeeded(to: item) }
    }

    /// The song stopped making sound (paused, stopped): the glow settles.
    func resetLevel() { settings.resetLevel() }

    func setEqualizer(enabled: Bool, bands newBands: [Double]) {
        eqOn = enabled
        for i in 0..<min(5, newBands.count) {
            bands[i] = Float(max(-12, min(12, newBands[i])))
        }
        push()
    }

    /// The gain in millibels, the same value Android's LoudnessEnhancer gets.
    /// Android applies a cut as a player-volume trim; here both directions go
    /// through the tap.
    func setNormalization(enabled: Bool, gainMb: Int) {
        normalizationOn = enabled
        normalizationGainMb = max(-2000, min(2000, gainMb))
        push()
    }

    private func push() {
        // A boost needs headroom or it clips: half the largest boost comes off the
        // whole signal, and the limiter in the render loop catches the rest.
        let maxBoost = eqOn ? max(0, bands.max() ?? 0) : 0
        let trimDb = normalizationOn ? Float(normalizationGainMb) / 100 : 0
        settings.update(eqOn: eqOn, bands: bands, gainDb: trimDb - maxBoost * 0.5)
    }

    /// Puts the tap on [item] when something is switched on and it has none yet.
    /// Live HLS radio has no audio track to tap; it simply plays unprocessed.
    func attachIfNeeded(to item: AVPlayerItem?) {
        guard let item = item, isNeeded, item.audioMix == nil else { return }
        Task { @MainActor in
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else {
                AuvyPlayer.log("eq: no audio track to process on this item; playing it unprocessed")
                return
            }
            // Checked again: a second call may have attached one while this loaded.
            guard item.audioMix == nil, let tap = self.makeTap() else { return }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
            AuvyPlayer.log("eq: processing on (equaliser \(self.eqOn ? "on" : "off"), "
                + "loudness \(self.normalizationOn ? "\(self.normalizationGainMb) mB" : "off"), "
                + "level meter \(self.meteringOn ? "on" : "off"))")
        }
    }

    private func makeTap() -> MTAudioProcessingTap? {
        let context = AuvyTapContext(settings: settings)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: auvyTapInit,
            finalize: auvyTapFinalize,
            prepare: auvyTapPrepare,
            unprepare: nil,
            process: auvyTapProcess)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let made = tap else {
            // init never ran, so finalize won't either: release the context here.
            Unmanaged<AuvyTapContext>.fromOpaque(callbacks.clientInfo!).release()
            AuvyPlayer.log("eq: could not create the audio tap (status \(status))")
            return nil
        }
        return made
    }
}

/// What the render thread reads. Written on the main thread under a lock that
/// the render thread only ever try-locks, so audio never waits on the UI: a
/// buffer that finds it busy keeps the previous settings for 20 ms.
final class AuvyTapSettings {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let bands = UnsafeMutablePointer<Float>.allocate(capacity: 5)
    private var eqOn = false
    private var gainDb: Float = 0
    private var version: UInt64 = 0
    /// The level meter: a flag the render thread reads and a value it writes,
    /// one 32-bit word each, no lock (a torn read can't happen on one aligned
    /// word, and a stale one only delays the glow by a buffer).
    private let meterFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let levelValue = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        bands.initialize(repeating: 0, count: 5)
        meterFlag.initialize(to: 0)
        levelValue.initialize(to: 0)
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
        bands.deallocate()
        meterFlag.deallocate()
        levelValue.deallocate()
    }

    var metering: Bool { meterFlag.pointee != 0 }
    var level: Float { levelValue.pointee }
    func setMetering(_ on: Bool) {
        meterFlag.pointee = on ? 1 : 0
        if !on { levelValue.pointee = 0 }
    }
    func resetLevel() { levelValue.pointee = 0 }
    func storeLevel(_ value: Float) { levelValue.pointee = value }

    func update(eqOn: Bool, bands newBands: [Float], gainDb: Float) {
        os_unfair_lock_lock(lock)
        self.eqOn = eqOn
        for i in 0..<5 { bands[i] = i < newBands.count ? newBands[i] : 0 }
        self.gainDb = gainDb
        version &+= 1
        os_unfair_lock_unlock(lock)
    }

    /// Copies newer settings into [context]. False when there is nothing new or
    /// the lock is busy; the caller then keeps what it has.
    func copyIfNewer(into context: AuvyTapContext) -> Bool {
        guard os_unfair_lock_trylock(lock) else { return false }
        defer { os_unfair_lock_unlock(lock) }
        guard version != context.appliedVersion else { return false }
        context.appliedVersion = version
        context.eqOn = eqOn
        for i in 0..<5 { context.bandDb[i] = Double(bands[i]) }
        context.targetGain = Float(pow(10, Double(gainDb) / 20))
        return true
    }
}

/// One tap's render state: the format, the filter coefficients and each
/// channel's filter memory. Fixed-size buffers, so the render loop never
/// allocates.
final class AuvyTapContext {
    static let maxChannels = 8
    static let bandCount = 5
    /// Low shelf, three peaks, high shelf. The shelves sit inside their labels
    /// (90 Hz for "60 Hz", 10 kHz for "14 kHz"), so the named frequency gets
    /// nearly the full gain rather than half of it.
    static let frequencies: [Double] = [90, 230, 910, 3600, 10000]
    /// The middle bands are about two octaves apart; Q 0.7 spans that.
    static let peakQ = 0.7

    let settings: AuvyTapSettings
    var appliedVersion: UInt64 = .max
    var eqOn = false
    let bandDb = UnsafeMutablePointer<Double>.allocate(capacity: bandCount)
    var targetGain: Float = 1
    var currentGain: Float = 1

    var sampleRate: Double = 44100
    var processable = false
    /// Bands that change the sound, one bit each.
    var activeMask: UInt8 = 0
    /// b0, b1, b2, a1, a2 per band, normalised by a0.
    let coefficients = UnsafeMutablePointer<Double>.allocate(capacity: bandCount * 5)
    /// z1, z2 per band per channel.
    let memory = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels * bandCount * 2)

    init(settings: AuvyTapSettings) {
        self.settings = settings
        bandDb.initialize(repeating: 0, count: Self.bandCount)
        coefficients.initialize(repeating: 0, count: Self.bandCount * 5)
        memory.initialize(repeating: 0, count: Self.maxChannels * Self.bandCount * 2)
    }

    deinit {
        bandDb.deallocate()
        coefficients.deallocate()
        memory.deallocate()
    }

    func prepare(format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44100
        processable = format.mFormatID == kAudioFormatLinearPCM
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && format.mBitsPerChannel == 32
        memory.update(repeating: 0, count: Self.maxChannels * Self.bandCount * 2)
        // Forces a fresh copy and coefficients for this sample rate.
        appliedVersion = .max
        _ = settings.copyIfNewer(into: self)
        recomputeCoefficients()
        currentGain = targetGain
    }

    func recomputeCoefficients() {
        activeMask = 0
        for band in 0..<Self.bandCount {
            let db = bandDb[band]
            guard eqOn, abs(db) > 0.05 else { continue }
            activeMask |= 1 << UInt8(band)
            let f0 = min(Self.frequencies[band], sampleRate * 0.45)
            let w0 = 2 * Double.pi * f0 / sampleRate
            let cosW = cos(w0), sinW = sin(w0)
            let a = pow(10, db / 40)
            var b0, b1, b2, a0, a1, a2: Double
            if band == 0 || band == Self.bandCount - 1 {
                // RBJ shelf, slope 1.
                let alpha = sinW / 2 * sqrt(2)
                let twoSqrtAAlpha = 2 * sqrt(a) * alpha
                if band == 0 {
                    b0 = a * ((a + 1) - (a - 1) * cosW + twoSqrtAAlpha)
                    b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
                    b2 = a * ((a + 1) - (a - 1) * cosW - twoSqrtAAlpha)
                    a0 = (a + 1) + (a - 1) * cosW + twoSqrtAAlpha
                    a1 = -2 * ((a - 1) + (a + 1) * cosW)
                    a2 = (a + 1) + (a - 1) * cosW - twoSqrtAAlpha
                } else {
                    b0 = a * ((a + 1) + (a - 1) * cosW + twoSqrtAAlpha)
                    b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
                    b2 = a * ((a + 1) + (a - 1) * cosW - twoSqrtAAlpha)
                    a0 = (a + 1) - (a - 1) * cosW + twoSqrtAAlpha
                    a1 = 2 * ((a - 1) - (a + 1) * cosW)
                    a2 = (a + 1) - (a - 1) * cosW - twoSqrtAAlpha
                }
            } else {
                // RBJ peaking.
                let alpha = sinW / (2 * Self.peakQ)
                b0 = 1 + alpha * a
                b1 = -2 * cosW
                b2 = 1 - alpha * a
                a0 = 1 + alpha / a
                a1 = -2 * cosW
                a2 = 1 - alpha / a
            }
            let k = coefficients + band * 5
            k[0] = b0 / a0; k[1] = b1 / a0; k[2] = b2 / a0; k[3] = a1 / a0; k[4] = a2 / a0
        }
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard processable, frames > 0 else { return }
        if settings.metering { measure(buffers, frames: frames) }
        if settings.copyIfNewer(into: self) { recomputeCoefficients() }
        let mask = activeMask
        let startGain = currentGain, endGain = targetGain
        if mask == 0 && startGain == 1 && endGain == 1 { return }

        var channel = 0
        for buffer in buffers {
            let stride = max(1, Int(buffer.mNumberChannels))
            defer { channel += stride }
            guard let raw = buffer.mData else { continue }
            let data = raw.assumingMemoryBound(to: Float.self)
            let n = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride))
            for c in 0..<stride where channel + c < Self.maxChannels {
                let ch = channel + c
                var band = 0
                while band < Self.bandCount {
                    if mask & (1 << UInt8(band)) != 0 {
                        let k = coefficients + band * 5
                        let z = memory + (ch * Self.bandCount + band) * 2
                        let b0 = k[0], b1 = k[1], b2 = k[2], a1 = k[3], a2 = k[4]
                        var z1 = z[0], z2 = z[1]
                        var p = data + c
                        for _ in 0..<n {
                            let x = Double(p.pointee)
                            let y = b0 * x + z1
                            z1 = b1 * x - a1 * y + z2
                            z2 = b2 * x - a2 * y
                            p.pointee = Float(y)
                            p += stride
                        }
                        z[0] = z1; z[1] = z2
                    }
                    band += 1
                }
                // Gain, ramped across the buffer so a new track's correction
                // doesn't click, then a soft knee above -1 dBFS instead of clipping.
                let step = n > 1 ? (endGain - startGain) / Float(n) : 0
                var g = startGain
                var p = data + c
                for _ in 0..<n {
                    var s = p.pointee * g
                    let mag = abs(s)
                    if mag > 0.89 {
                        let over = (mag - 0.89) / 0.11
                        s = (s < 0 ? -1 : 1) * (0.89 + 0.11 * tanhf(over))
                    }
                    p.pointee = s
                    g += step
                    p += stride
                }
            }
        }
        currentGain = endGain
    }
}

extension AuvyTapContext {
    /// RMS of the first channel of this buffer, as played (before the equaliser
    /// and gain, so the glow follows the music rather than the settings).
    /// Every second sample is enough for a light that moves at 20 frames a
    /// second.
    func measure(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard let first = buffers.first, let raw = first.mData else { return }
        let stride = max(1, Int(first.mNumberChannels))
        let n = min(frames, Int(first.mDataByteSize) / (MemoryLayout<Float>.size * stride))
        guard n > 1 else { return }
        let data = raw.assumingMemoryBound(to: Float.self)
        var sum: Float = 0
        var count = 0
        var i = 0
        while i < n {
            let x = data[i * stride]
            sum += x * x
            count += 1
            i += 2
        }
        settings.storeLevel(count > 0 ? (sum / Float(count)).squareRoot() : 0)
    }
}

// The C callbacks. The context travels as the tap's storage: retained when the
// tap is created, released in finalize.

private let auvyTapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let auvyTapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<AuvyTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let auvyTapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let context = Unmanaged<AuvyTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()
    context.prepare(format: format.pointee)
}

private let auvyTapProcess: MTAudioProcessingTapProcessCallback = {
    tap, frameCount, _, bufferList, framesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, nil, framesOut)
    guard status == noErr else { return }
    let context = Unmanaged<AuvyTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()
    context.process(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(framesOut.pointee))
}
