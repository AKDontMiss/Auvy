import Foundation

/// Fixes the duration of YouTube's FRAGMENTED MP4 audio for iOS.
///
/// YouTube serves DASH-fragmented audio: the moov's sample table is empty and
/// the samples live in `moof` fragments. The moov's duration fields should be
/// 0 ("derive from the fragments"), but YouTube fills in the real duration,
/// and iOS then counts both (e.g. 253.8s declared + 253.8s of fragments =
/// 507.6s reported). The track plays normally to the halfway point and then
/// plays silence. macOS reads the same files correctly.
///
/// Shared by the stream loader and by every other way a file reaches the
/// player (downloads, the auto-cache, imported files).
///
/// The fields are zeroed in place, keeping their width, so every offset in the
/// file stays valid and nothing needs remuxing.
enum AuvyMP4Repair {

    /// Boxes whose `duration` field is the lie. `tkhd` lays its fields out
    /// differently from the other two, which is why the offset is computed per box.
    private static let durationBoxes: Set<String> = ["mvhd", "mdhd", "tkhd"]

    /// A moov larger than this is not something we are willing to read whole.
    /// A fragmented audio moov is a few KB (its sample tables are empty); even a
    /// fully-muxed hour-long file is well under this.
    private static let maxMoovBytes: Int64 = 8 * 1024 * 1024

    /// Repair [url] only if it is a fragmented MP4 whose moov declares a non-zero
    /// duration. Returns true when bytes were actually written.
    ///
    /// Safe to call on anything: a no-op for non-MP4 files (MP3, Opus/WebM), for
    /// normal non-fragmented MP4s (where the moov duration is the only record of
    /// the length and must not be zeroed), and for already-repaired files.
    @discardableResult
    static func repairIfFragmented(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }

        guard let moov = findMoov(handle) else { return false }
        guard let body = try? readBox(handle, at: moov.offset, size: moov.size) else { return false }
        let firstChild = moov.headerSize

        // `mvex` (Movie Extends) marks a fragmented file: it is required in the moov
        // of every fragmented MP4 and absent otherwise. Without this check the repair
        // would zero the duration of an ordinary m4a.
        guard hasChild("mvex", in: body, from: firstChild) else { return false }

        var patched = 0
        forEachDurationField(in: body, from: firstChild) { fieldOffset, width in
            // Idempotent: a file repaired on a previous play (or before it was
            // cached) has nothing left to write, and re-writing would only churn
            // the file's modification date — which the download folder sorts by.
            guard !isZero(body, at: fieldOffset, width: width) else { return }
            try? handle.seek(toOffset: UInt64(moov.offset + Int64(fieldOffset)))
            try? handle.write(contentsOf: Data(repeating: 0, count: width))
            patched += 1
        }

        if patched > 0 {
            AuvyPlayer.log("repair: zeroed \(patched) moov duration field(s) in "
                + "\(url.lastPathComponent) — fragmented MP4")
        }
        return patched > 0
    }

    // MARK: Box walking

    /// Top-level scan for the moov, by seeking over box headers rather than
    /// reading the file, so it's found even after a large mdat (common in normal
    /// m4a files) without loading the audio into memory.
    private static func findMoov(_ handle: FileHandle) -> (offset: Int64, size: Int64, headerSize: Int)? {
        let end = (try? handle.seekToEnd()).map(Int64.init) ?? 0
        var offset: Int64 = 0
        var sawFtyp = false

        while offset + 8 <= end {
            try? handle.seek(toOffset: UInt64(offset))
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { return nil }
            let bytes = [UInt8](header)
            var size = Int64(be32(bytes, 0))
            let name = fourCC(bytes, 4)
            var headerSize: Int64 = 8

            if size == 1 {
                // 64-bit `largesize` — an mdat over 4 GB. Rare for audio, fatal to
                // the walk if mishandled, because the next offset would be garbage.
                guard bytes.count >= 16 else { return nil }
                size = Int64(bitPattern: be64(bytes, 8))
                headerSize = 16
            } else if size == 0 {
                // "To the end of the file" — only legal for the last box, and there
                // is nothing after it to find.
                return name == "moov" ? (offset, end - offset, Int(headerSize)) : nil
            }
            guard size >= headerSize, offset + size <= end else { return nil }

            // A file that does not START with ftyp is not the MP4 family at all
            // (an MP3 download, a WebM cache entry), and walking it as one would
            // read random bytes as box sizes.
            if !sawFtyp {
                guard name == "ftyp" else { return nil }
                sawFtyp = true
            }
            if name == "moov" {
                guard size <= maxMoovBytes else { return nil }
                return (offset, size, Int(headerSize))
            }
            offset += size
        }
        return nil
    }

    private static func readBox(_ handle: FileHandle, at offset: Int64, size: Int64) throws -> [UInt8] {
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: Int(size)), data.count == Int(size) else {
            return []
        }
        return [UInt8](data)
    }

    /// Is [name] a DIRECT child of this box? (`mvex` sits at the top of the moov.)
    private static func hasChild(_ name: String, in box: [UInt8], from start: Int) -> Bool {
        var found = false
        forEachChild(of: box, from: start, to: box.count) { childName, _, _ in
            if childName == name { found = true }
        }
        return found
    }

    /// Visit every `mvhd` / `mdhd` / `tkhd` duration field inside the moov,
    /// reporting its offset RELATIVE TO THE MOOV and its width in bytes.
    private static func forEachDurationField(in moov: [UInt8], from start: Int,
                                             _ visit: (Int, Int) -> Void) {
        // Only descend into the containers that can hold a header box; anything
        // else is a sample table we have no business parsing.
        let containers: Set<String> = ["moov", "trak", "mdia"]

        func walk(_ start: Int, _ end: Int) {
            forEachChild(of: moov, from: start, to: end) { name, body, boxEnd in
                if durationBoxes.contains(name), body < moov.count {
                    let version = moov[body]
                    // The layout differs by box and by version, but duration always
                    // follows the timescale (mvhd/mdhd) or the reserved word (tkhd).
                    let field: Int
                    if name == "tkhd" {
                        field = body + (version == 1 ? 32 : 20)
                    } else {
                        field = body + (version == 1 ? 24 : 16)
                    }
                    let width = (version == 1) ? 8 : 4
                    if field + width <= boxEnd { visit(field, width) }
                }
                if containers.contains(name) { walk(body, boxEnd) }
            }
        }
        walk(start, moov.count)
    }

    /// One level of children, with 64-bit sizes and truncation handled once.
    private static func forEachChild(of box: [UInt8], from start: Int, to end: Int,
                                     _ visit: (String, Int, Int) -> Void) {
        var offset = start
        while offset + 8 <= end {
            var size = Int(be32(box, offset))
            let name = fourCC(box, offset + 4)
            var body = offset + 8
            if size == 1 {
                guard offset + 16 <= end else { return }
                size = Int(be64(box, offset + 8))
                body = offset + 16
            } else if size == 0 {
                size = end - offset
            }
            guard size >= body - offset, offset + size <= end else { return }
            visit(name, body, offset + size)
            offset += size
        }
    }

    // MARK: Byte helpers

    private static func isZero(_ bytes: [UInt8], at offset: Int, width: Int) -> Bool {
        guard offset + width <= bytes.count else { return true }
        for i in offset..<(offset + width) where bytes[i] != 0 { return false }
        return true
    }

    private static func be32(_ bytes: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= bytes.count else { return 0 }
        return (UInt32(bytes[i]) << 24) | (UInt32(bytes[i + 1]) << 16)
            | (UInt32(bytes[i + 2]) << 8) | UInt32(bytes[i + 3])
    }

    private static func be64(_ bytes: [UInt8], _ i: Int) -> UInt64 {
        guard i + 8 <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for k in 0..<8 { value = (value << 8) | UInt64(bytes[i + k]) }
        return value
    }

    private static func fourCC(_ bytes: [UInt8], _ i: Int) -> String {
        guard i + 4 <= bytes.count else { return "" }
        return String(bytes: bytes[i..<(i + 4)], encoding: .ascii) ?? ""
    }
}
