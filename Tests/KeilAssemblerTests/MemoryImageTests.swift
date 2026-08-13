import Testing
@testable import KeilAssembler

private func snapshot(store address: UInt32, _ value: UInt32, width: UInt32) -> MachineSnapshot {
    MachineSnapshot(seq: 0, sourceLine: 0, pc: 0x8000,
                    registers: [UInt32](repeating: 0, count: 16), cpsr: 0,
                    storeAddress: address, storeValue: value, storeWidth: width)
}

@Test func memoryImageStartsFromTheStartupImage() {
    let image = MemoryImage(initial: [(address: 0x1000, bytes: [0x12, 0, 0, 0])])
    #expect(image.word(at: 0x1000) == 0x12)
    #expect(image.word(at: 0x2000) == 0)          // unwritten memory reads as zero
}

@Test func applyingAStoreOverwritesTheWord() {
    var image = MemoryImage(initial: [(address: 0x1000, bytes: [0x12, 0, 0, 0])])
    image.apply(snapshot(store: 0x1000, 0xDEADBEEF, width: 4))
    #expect(image.word(at: 0x1000) == 0xDEADBEEF)
}

@Test func aByteStoreOnlyTouchesOneByte() {
    var image = MemoryImage(initial: [(address: 0x1000, bytes: [0xFF, 0xFF, 0xFF, 0xFF])])
    image.apply(snapshot(store: 0x1001, 0xAA, width: 1))
    #expect(image.word(at: 0x1000) == 0xFFFFAAFF)   // little-endian, byte 1 replaced
}

@Test func aSnapshotWithNoStoreChangesNothing() {
    var image = MemoryImage(initial: [(address: 0x1000, bytes: [0x12, 0, 0, 0])])
    image.apply(snapshot(store: 0, 0, width: 0))
    #expect(image.word(at: 0x1000) == 0x12)
    #expect(image.touchedWordAddresses == [0x1000])
}

@Test func foldingStopsAtTheCursor() {
    let writes = [snapshot(store: 0x2000, 1, width: 4),
                  snapshot(store: 0x2000, 2, width: 4),
                  snapshot(store: 0x2000, 3, width: 4)]
    #expect(MemoryImage.folding(initial: [], snapshots: writes, upTo: 0).word(at: 0x2000) == 1)
    #expect(MemoryImage.folding(initial: [], snapshots: writes, upTo: 2).word(at: 0x2000) == 3)
}
