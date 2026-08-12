import Foundation

/// Spec §5.3. Memory contents supplied by the client rather than by the source —
/// how the lab's Memory-window values are expressed.
struct MemoryPreload: Sendable {
    var entries: [(address: UInt32, bytes: [UInt8])]

    init(entries: [(address: UInt32, bytes: [UInt8])] = []) {
        self.entries = entries
    }

    /// Convenience for the common case: one 32-bit word at one address. A
    /// dictionary has no inherent iteration order, and the startup image's
    /// byte layout must be deterministic across runs (Spec §5.3), so entries
    /// are sorted by address before `encode` ever sees them.
    init(words: [UInt32: UInt32]) {
        entries = words.sorted { $0.key < $1.key }.map { address, value in
            (address, (0...3).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) })
        }
    }
}

/// Spec §5.3 blob format:
///   `u32 arm7Address · u32 byteCount · byteCount bytes · zero-pad to 4 bytes`
enum StartupImage {
    static func encode(dataImage: [ImageBlob], preload: MemoryPreload) -> Data {
        var data = Data()
        for blob in dataImage {
            append(address: blob.address, bytes: blob.bytes, to: &data)
        }
        for entry in preload.entries {
            append(address: entry.address, bytes: entry.bytes, to: &data)
        }
        PerfLog.info("startup image: \(dataImage.count) data blobs, \(preload.entries.count) preload blobs, \(data.count) bytes")
        return data
    }

    /// A zero-length blob (a `SPACE 0` or an empty `DCB` list, or an empty
    /// preload entry) carries no information the runtime needs — unwritten
    /// ARM7 memory already reads as zero (Spec §5.3, §7.8) — so it is skipped
    /// rather than emitted as an eight-byte header for zero bytes of content.
    private static func append(address: UInt32, bytes: [UInt8], to data: inout Data) {
        guard !bytes.isEmpty else { return }
        appendWord(address, to: &data)
        appendWord(UInt32(bytes.count), to: &data)
        data.append(contentsOf: bytes)
        let padding = (4 - bytes.count % 4) % 4
        data.append(contentsOf: Array(repeating: 0, count: padding))
    }

    private static func appendWord(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }
}
