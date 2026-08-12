import Foundation
import Testing
@testable import KeilAssembler

/// Encodes 24 little-endian words into one trace record's worth of bytes.
/// Deliberately independent of `TraceDecoder`'s own word-reading code, so a
/// bug shared between encoder and decoder wouldn't cancel out and hide a defect.
private func fullRecord(words: [UInt32]) -> Data {
    precondition(words.count == 24, "a trace record is 24 words (Spec §7.7)")
    var data = Data()
    for word in words {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
        }
    }
    return data
}

private func record(seq: UInt32, line: UInt32, r1: UInt32) -> Data {
    var words = [UInt32](repeating: 0, count: 24)
    words[0] = seq
    words[1] = line
    words[2] = 0x8000                 // pc
    words[3 + 1] = r1                 // r[1]
    words[19] = 0                     // cpsr
    return fullRecord(words: words)
}

@Test func decoderReadsFixedSizeRecords() throws {
    let snapshots = try TraceDecoder.decode(record(seq: 0, line: 3, r1: 0x12) + record(seq: 1, line: 4, r1: 0x27))
    #expect(snapshots.count == 2)
    #expect(snapshots[0].sourceLine == 3)
    #expect(snapshots[0].registers[1] == 0x12)
    #expect(snapshots[1].seq == 1)
    #expect(snapshots[1].registers[1] == 0x27)
    #expect(snapshots[0].pc == 0x8000)
}

@Test func decoderRejectsATruncatedTraceAndReportsTheByteCount() {
    // Pins both the failure case and the diagnostic payload: a decoder that
    // throws a generic/placeholder error, or that reports the wrong byte
    // count (e.g. the record size instead of the actual truncated length),
    // would fail this even though "decoderRejectsATruncatedTrace" alone
    // would not catch it.
    let data = record(seq: 0, line: 0, r1: 0).dropLast(4)
    #expect(data.count == 92)
    #expect(throws: TraceDecoder.Failure.truncated(byteCount: 92)) {
        try TraceDecoder.decode(data)
    }
}

@Test func decoderRejectsATrailingPartialRecordAfterAValidOne() {
    // A decoder that only checks `data.count >= recordSize` (rather than an
    // exact multiple) would accept this: one full record followed by a
    // partial second one. That would silently drop the tail instead of
    // signalling a malformed trace file.
    let data = fullRecord(words: [UInt32](repeating: 0, count: 24)) + Data(repeating: 0xFF, count: 50)
    #expect(throws: TraceDecoder.Failure.self) {
        try TraceDecoder.decode(data)
    }
}

@Test func decoderReturnsEmptyArrayForEmptyData() throws {
    // 0 % recordSize == 0: an implementation that special-cases "must be
    // non-empty" or that miscomputes the loop bound for zero-length input
    // would either throw here or crash, rather than reporting zero steps.
    #expect(try TraceDecoder.decode(Data()).isEmpty)
}

@Test func recordSizeMatchesTheSpec() {
    #expect(TraceDecoder.recordSize == 96)     // Spec §7.7
}

@Test func decoderMapsEveryWordToItsOwnField() throws {
    // Spec §7.7 order: seq, srcLine, pc, r[16], cpsr, storeAddr, storeValue,
    // storeWidth, pad. Every word below is a distinct sentinel, so a decoder
    // with an off-by-one in the registers slice, or a swap of storeAddress
    // and storeValue, produces a value that plainly does not match -- rather
    // than a coincidentally plausible number, which is the failure mode the
    // brief calls out as highest risk here.
    let words: [UInt32] = [
        0xA000,                                                          // seq
        0xA001,                                                          // srcLine
        0xA002,                                                          // pc
        0xA010, 0xA011, 0xA012, 0xA013, 0xA014, 0xA015, 0xA016, 0xA017,
        0xA018, 0xA019, 0xA01A, 0xA01B, 0xA01C, 0xA01D, 0xA01E, 0xA01F,   // r0...r15
        0xA020,                                                          // cpsr
        0xA021,                                                          // storeAddr
        0xA022,                                                          // storeValue
        0xA023,                                                          // storeWidth
        0xDEAD_BEEF,                                                     // pad -- must not leak
    ]
    let snapshot = try #require(try TraceDecoder.decode(fullRecord(words: words)).first)
    #expect(snapshot.seq == 0xA000)
    #expect(snapshot.sourceLine == 0xA001)
    #expect(snapshot.pc == 0xA002)
    #expect(snapshot.registers == (0...15).map { UInt32(0xA010 + $0) })
    #expect(snapshot.cpsr == 0xA020)
    #expect(snapshot.storeAddress == 0xA021)
    #expect(snapshot.storeValue == 0xA022)
    #expect(snapshot.storeWidth == 0xA023)
}
