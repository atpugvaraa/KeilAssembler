import Foundation

/// One ARM7 machine state, as recorded after a single instruction. Spec §7.7.
public struct MachineSnapshot: Sendable, Equatable {
    public let seq: UInt32
    public let sourceLine: Int
    public let pc: UInt32
    public let registers: [UInt32]     // 16 entries, R0...R15
    public let cpsr: UInt32
    public let storeAddress: UInt32
    public let storeValue: UInt32
    public let storeWidth: UInt32

    public init(
        seq: UInt32,
        sourceLine: Int,
        pc: UInt32,
        registers: [UInt32],
        cpsr: UInt32,
        storeAddress: UInt32,
        storeValue: UInt32,
        storeWidth: UInt32
    ) {
        self.seq = seq
        self.sourceLine = sourceLine
        self.pc = pc
        self.registers = registers
        self.cpsr = cpsr
        self.storeAddress = storeAddress
        self.storeValue = storeValue
        self.storeWidth = storeWidth
    }
}

/// Decodes `trace.bin`, the fixed-size record stream `armd_trace` (Spec §7.8)
/// appends to. Because each record carries any memory write, the decoded
/// array is the sole input to the memory browser, registers panel, step,
/// step-back, and run-to-line (Spec §7.7) -- there is no live debugger.
enum TraceDecoder {
    /// Spec §7.7: 24 words = 96 bytes. Must match `struct ARMdTraceRecord`
    /// in armd_rt.c exactly, or every record after the first is misaligned.
    static let recordSize = 96

    enum Failure: Error, Equatable {
        case truncated(byteCount: Int)
    }

    static func decode(_ data: Data) throws -> [MachineSnapshot] {
        guard data.count % recordSize == 0 else {
            PerfLog.error("trace is \(data.count) bytes, not a multiple of \(recordSize)")
            throw Failure.truncated(byteCount: data.count)
        }

        return try PerfLog.measure("decode-trace") { () -> [MachineSnapshot] in
            let bytes = [UInt8](data)
            var snapshots: [MachineSnapshot] = []
            snapshots.reserveCapacity(bytes.count / recordSize)

            for start in stride(from: 0, to: bytes.count, by: recordSize) {
                func word(_ index: Int) -> UInt32 {
                    let offset = start + index * 4
                    return UInt32(bytes[offset])
                        | UInt32(bytes[offset + 1]) << 8
                        | UInt32(bytes[offset + 2]) << 16
                        | UInt32(bytes[offset + 3]) << 24
                }
                // Word layout (Spec §7.7): 0 seq, 1 srcLine, 2 pc, 3..18 r[16],
                // 19 cpsr, 20 storeAddr, 21 storeValue, 22 storeWidth, 23 pad.
                snapshots.append(MachineSnapshot(
                    seq: word(0),
                    sourceLine: Int(word(1)),
                    pc: word(2),
                    registers: (3..<19).map(word),
                    cpsr: word(19),
                    storeAddress: word(20),
                    storeValue: word(21),
                    storeWidth: word(22)
                ))
            }
            PerfLog.info("decoded \(snapshots.count) snapshots")
            return snapshots
        }
    }
}
