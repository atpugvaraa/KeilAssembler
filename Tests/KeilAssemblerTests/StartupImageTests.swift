import Foundation
import Testing
@testable import KeilAssembler

/// Decodes a `Data` blob into little-endian 32-bit words for assertions below.
/// Deliberately independent of `StartupImage`'s own word-writing code, so a bug
/// shared between encoder and this helper wouldn't cancel out and hide a defect.
private func words(_ data: Data) -> [UInt32] {
    stride(from: 0, to: data.count, by: 4).map { offset in
        data[offset..<offset + 4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

@Test func encoderWritesAddressLengthAndPaddedBytes() {
    let data = StartupImage.encode(
        dataImage: [ImageBlob(address: 0x8000, bytes: [0x12, 0x00, 0x00, 0x00])],
        preload: MemoryPreload()
    )
    #expect(words(data) == [0x8000, 4, 0x12])
}

@Test func encoderPadsShortBlobsToAFourByteBoundary() {
    let data = StartupImage.encode(
        dataImage: [ImageBlob(address: 0x8000, bytes: [0xAA])],
        preload: MemoryPreload()
    )
    // header (2 words) + 1 byte padded to one word
    #expect(data.count == 12)
    #expect(words(data) == [0x8000, 1, 0x0000_00AA])
}

@Test func preloadBlobsFollowTheDataImageSoTheyWin() {
    // Spec §5.3: later blobs overwrite earlier ones.
    let data = StartupImage.encode(
        dataImage: [ImageBlob(address: 0x1000, bytes: [1, 0, 0, 0])],
        preload: MemoryPreload(entries: [(address: 0x1000, bytes: [2, 0, 0, 0])])
    )
    #expect(words(data) == [0x1000, 4, 1, 0x1000, 4, 2])
}

@Test func encoderProducesAnEmptyImageWhenThereIsNothingToLoad() {
    #expect(StartupImage.encode(dataImage: [], preload: MemoryPreload()).isEmpty)
}

// MARK: - Padding at every residue mod 4
//
// `(4 - bytes.count % 4) % 4` is the kind of expression that is easy to get
// wrong by one at a boundary. Pin every residue an implementer could get
// wrong: 1 (covered above), 2, 3, and 4 (the "already aligned, no padding"
// case, which a naive `4 - bytes.count % 4` without the outer `% 4` would
// wrongly pad by a full extra word).

@Test func encoderPadsTwoByteBlobsWithTwoZeroBytes() {
    let data = StartupImage.encode(
        dataImage: [ImageBlob(address: 0x9000, bytes: [0xAA, 0xBB])],
        preload: MemoryPreload()
    )
    #expect(data.count == 12)
    #expect(words(data) == [0x9000, 2, 0x0000_BBAA])
}

@Test func encoderPadsThreeByteBlobsWithOneZeroByte() {
    let data = StartupImage.encode(
        dataImage: [ImageBlob(address: 0xA000, bytes: [0x11, 0x22, 0x33])],
        preload: MemoryPreload()
    )
    #expect(data.count == 12)
    #expect(words(data) == [0xA000, 3, 0x0033_2211])
}

@Test func encoderAddsNoPaddingWhenAlreadyFourByteAligned() {
    let data = StartupImage.encode(
        dataImage: [ImageBlob(address: 0xB000, bytes: [0x01, 0x02, 0x03, 0x04])],
        preload: MemoryPreload()
    )
    // header (2 words) + exactly 1 word of payload, no third payload word from padding.
    #expect(data.count == 12)
    #expect(words(data) == [0xB000, 4, 0x0403_0201])
}

// MARK: - Zero-length blobs
//
// A `SPACE 0` or an empty `DCB` list evaluates to a zero-byte ImageBlob (see
// Analyser.swift's `.space` and `.defineBytes` cases). Emitting a header for
// it would add eight bytes that say "here are zero bytes of content," which
// carries no information the runtime needs — unwritten ARM7 memory already
// reads as zero (Spec §5.3, §7.8). So a zero-length blob is skipped entirely,
// not diagnosed: nothing in the source is wrong, there is just nothing to load.
// Pinned here rather than left as an accidental side effect of the early return.

@Test func encoderSkipsZeroLengthBlobsEntirely() {
    let data = StartupImage.encode(
        dataImage: [
            ImageBlob(address: 0x2000, bytes: []),
            ImageBlob(address: 0x3000, bytes: [0x7F]),
        ],
        preload: MemoryPreload()
    )
    // If the empty blob emitted anything, the surviving blob's address
    // wouldn't be the first word in the output.
    #expect(words(data) == [0x3000, 1, 0x7F])
}

@Test func encoderSkipsAZeroLengthPreloadEntryToo() {
    let data = StartupImage.encode(
        dataImage: [],
        preload: MemoryPreload(entries: [(address: 0x4000, bytes: [])])
    )
    #expect(data.isEmpty)
}

// MARK: - MemoryPreload(words:) ordering
//
// `MemoryPreload.init(words:)` builds its entries from a `[UInt32: UInt32]`
// dictionary, which has no inherent order. Without the address sort the brief
// specifies, the byte layout would be non-deterministic across runs of the
// same program. Insert the higher address first so an implementation that
// forgot to sort (i.e. that used the dictionary's own iteration order) would
// have to coincidentally match insertion order to pass — and pin the exact
// little-endian byte layout of each word at the same time.

@Test func preloadFromWordsIsSortedByAddressRegardlessOfInsertionOrder() {
    // Two entries only catch a missing `.sorted()` about half the time (there
    // are only two possible orderings of a 2-element dictionary). Five entries,
    // inserted in a deliberately scrambled order, make a coincidental pass
    // overwhelmingly unlikely (1-in-120, not 1-in-2).
    let preload = MemoryPreload(words: [
        0x3000: 0x3333_3333,
        0x1000: 0x1111_1111,
        0x5000: 0x5555_5555,
        0x2000: 0x2222_2222,
        0x4000: 0x4444_4444,
    ])
    let data = StartupImage.encode(dataImage: [], preload: preload)
    #expect(words(data) == [
        0x1000, 4, 0x1111_1111,
        0x2000, 4, 0x2222_2222,
        0x3000, 4, 0x3333_3333,
        0x4000, 4, 0x4444_4444,
        0x5000, 4, 0x5555_5555,
    ])
}
