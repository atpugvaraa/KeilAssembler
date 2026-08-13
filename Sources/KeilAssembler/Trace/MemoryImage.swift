import Foundation

/// Spec §5.3: ARM7 memory at step *n* is the startup image folded with the first
/// *n* trace records. Sparse — a lab touches a handful of words out of 4 GiB.
public struct MemoryImage: Sendable {
    private var bytes: [UInt32: UInt8] = [:]

    public init(initial: [(address: UInt32, bytes: [UInt8])] = []) {
        for blob in initial {
            for (offset, byte) in blob.bytes.enumerated() {
                bytes[blob.address &+ UInt32(offset)] = byte
            }
        }
    }

    public mutating func apply(_ snapshot: MachineSnapshot) {
        guard snapshot.storeWidth > 0 else { return }
        for offset in 0..<snapshot.storeWidth {
            bytes[snapshot.storeAddress &+ offset] =
                UInt8(truncatingIfNeeded: snapshot.storeValue >> (offset &* 8))
        }
    }

    /// Little-endian; unwritten memory reads as zero (Spec §3).
    public func word(at address: UInt32) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { result, offset in
            result | UInt32(bytes[address &+ offset] ?? 0) << (offset &* 8)
        }
    }

    /// Word-aligned addresses with at least one byte written, ascending.
    public var touchedWordAddresses: [UInt32] {
        Set(bytes.keys.map { $0 & ~UInt32(3) }).sorted()
    }

    public static func folding(
        initial: [(address: UInt32, bytes: [UInt8])],
        snapshots: [MachineSnapshot],
        upTo cursor: Int
    ) -> MemoryImage {
        var image = MemoryImage(initial: initial)
        guard cursor >= 0 else { return image }
        for snapshot in snapshots.prefix(cursor + 1) { image.apply(snapshot) }
        return image
    }
}
