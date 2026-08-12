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
