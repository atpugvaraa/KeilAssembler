import Foundation
import Testing
@testable import KeilAssembler

/// Spec §10 corpus 1(a): MOV R1, #0x12 / MOV R2, R1 / MOV R3, R1
private let exercise1a = """
    AREA PROGRAM, CODE, READONLY
    ENTRY

MAIN
MOV R1, #0X12
MOV R2, R1
MOV R3, R1
END
"""

@Test func corpus1aCopiesTheImmediateIntoThreeRegisters() throws {
    let result = try Driver().run(source: exercise1a, preload: MemoryPreload())
    #expect(result.diagnostics.contains { $0.severity == .error } == false)
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[1] == 0x12)
    #expect(result.finalRegisters[2] == 0x12)
    #expect(result.finalRegisters[3] == 0x12)
}

@Test func corpus1aProducesOneSnapshotPerInstruction() throws {
    let result = try Driver().run(source: exercise1a, preload: MemoryPreload())
    #expect(result.snapshots.count == 3)
    #expect(result.snapshots[0].registers[1] == 0x12)
    #expect(result.snapshots[0].registers[2] == 0)     // not yet written
    #expect(result.snapshots[1].registers[2] == 0x12)
}

/// Spec §10 corpus 1(b)
@Test func corpus1bAddsTwoImmediates() throws {
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R1, #0X12
    MOV R2, #0X15
    ADD R4, R1, R2
    END
    """, preload: MemoryPreload())
    #expect(result.finalRegisters[4] == 0x27)
}

/// Spec §10 corpus 1(e)
@Test func corpus1eInvertsEveryBit() throws {
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R1, #0X12
    MVN R2, R1
    END
    """, preload: MemoryPreload())
    #expect(result.finalRegisters[2] == 0xFFFF_FFED)
}

/// Spec §10 corpus 1(c) — LDR Rd, label loads the *word at* the label.
@Test func corpus1cLoadsTwoWordsAndAddsThem() throws {
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    LDR R1, VALUE1
    LDR R2, VALUE2
    ADD R3, R1, R2
        AREA STORAGE, DATA, READONLY
    VALUE1 DCD, &00000012
    VALUE2 DCD, &00000013
    END
    """, preload: MemoryPreload())
    #expect(result.finalRegisters[1] == 0x12)
    #expect(result.finalRegisters[2] == 0x13)
    #expect(result.finalRegisters[3] == 0x25)
}

private let exercise1d = """
    AREA PROGRAM, CODE, READONLY
    ENTRY

MAIN
LDR R1, VALUE1
LDR R2, VALUE2
LDR R3, [R1]
LDR R4, [R2]
ADD R6, R4, R3
    AREA STORAGE, DATA, READONLY
VALUE1 DCD, &00001000
VALUE2 DCD, &00001004
END
"""

/// Spec §10 corpus 1(d) — memory contents come from the preload image (§5.3).
@Test func corpus1dDereferencesPreloadedAddresses() throws {
    let result = try Driver().run(
        source: exercise1d,
        preload: MemoryPreload(words: [0x1000: 0x12, 0x1004: 0x13])
    )
    #expect(result.finalRegisters[1] == 0x1000)
    #expect(result.finalRegisters[2] == 0x1004)
    #expect(result.finalRegisters[3] == 0x12)
    #expect(result.finalRegisters[4] == 0x13)
    #expect(result.finalRegisters[6] == 0x25)
}

/// Spec §10 corpus `1d-zero` — pins the documented zero-fill of unwritten memory.
@Test func corpus1dWithoutPreloadReadsZeros() throws {
    let result = try Driver().run(source: exercise1d, preload: MemoryPreload())
    #expect(result.finalRegisters[1] == 0x1000)
    #expect(result.finalRegisters[3] == 0)
    #expect(result.finalRegisters[4] == 0)
    #expect(result.finalRegisters[6] == 0)
}

/// Spec §10 corpus 2(a) — shifted Operand2.
@Test func corpus2aShiftsALoadedWordLeftByTwo() throws {
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    LDR R1, VALUE
    MOV R3, R1, LSL #2
        AREA STORAGE, DATA, READONLY
    VALUE DCD &3000F000
    END
    """, preload: MemoryPreload())
    #expect(result.finalRegisters[1] == 0x3000_F000)
    #expect(result.finalRegisters[3] == 0xC003_C000)
}

/// Spec §10 corpus 2(b) — exercises the §7.3 CPSR round-trip and §6.1 guard.
@Test func corpus2bExecutesTheConditionalMoveWhenZIsSet() throws {
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R1, #0X12
    MOVS R3, #0
    MOVEQ R3, R1, LSL #3
    END
    """, preload: MemoryPreload())
    // MOVS R3, #0 sets Z, so the conditional move runs: 0x12 << 3 = 0x90.
    #expect(result.finalRegisters[3] == 0x90)
}

@Test func storesAreVisibleInTheTrace() throws {
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    LDR R1, =0x00002000
    MOV R2, #0X12
    STR R2, [R1]
    END
    """, preload: MemoryPreload())
    let store = result.snapshots.last
    #expect(store?.storeAddress == 0x2000)
    #expect(store?.storeValue == 0x12)
    #expect(store?.storeWidth == 4)
}
