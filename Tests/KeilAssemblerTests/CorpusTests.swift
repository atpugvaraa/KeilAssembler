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
    #expect(result.exitCode == 0)
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
    #expect(result.exitCode == 0)
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
    #expect(result.exitCode == 0)
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
    #expect(result.exitCode == 0)
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
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[1] == 0x1000)
    #expect(result.finalRegisters[2] == 0x1004)
    #expect(result.finalRegisters[3] == 0x12)
    #expect(result.finalRegisters[4] == 0x13)
    #expect(result.finalRegisters[6] == 0x25)
}

/// Spec §10 corpus `1d-zero` — pins the documented zero-fill of unwritten memory.
@Test func corpus1dWithoutPreloadReadsZeros() throws {
    let result = try Driver().run(source: exercise1d, preload: MemoryPreload())
    #expect(result.exitCode == 0)
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
    #expect(result.exitCode == 0)
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
    #expect(result.exitCode == 0)
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
    #expect(result.exitCode == 0)
    let store = result.snapshots.last
    #expect(store?.storeAddress == 0x2000)
    #expect(store?.storeValue == 0x12)
    #expect(store?.storeWidth == 4)
}

// MARK: - Final fix wave

@Test func criticalPopWithPCReturnsCorrectlyFromASubroutine() throws {
    // Critical 1's exact repro: HELPER opens a frame via PUSH {R4, LR} and ends
    // with POP {R4, PC} — the canonical ARM subroutine-return idiom, the
    // natural partner to PUSH {R4, LR}. Before the fix this wrote R15's
    // *display* slot like an ordinary register and fell straight through with
    // HELPER's frame never popped, so the shared epilogue's `ldp` read the
    // wrong stack slots and `ret` jumped to garbage (exit 11, R2 left at 0, no
    // diagnostics at all).
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R4, #7
    BL HELPER
    MOV R2, #9
    B FINISH
    HELPER
    PUSH {R4, LR}
    MOV R4, #1
    POP {R4, PC}
    FINISH
    MOV R3, #1
    END
    """, preload: MemoryPreload())
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[2] == 9)
    #expect(result.finalRegisters[3] == 1)
    #expect(result.diagnostics.contains { $0.severity == .error } == false)
}

@Test func importantTwoATopLevelBxLrExitsCleanlyInsteadOfCrashing() throws {
    // Important 2's exact repro: `BX LR` at the top of MAIN — the obvious way
    // to end a program with no subroutines — used to pop the frame every BL
    // target's prologue opens, but MAIN was never reached via BL, so nothing
    // pushed one. It popped the host `_main` prologue's own saved register
    // pairs instead and returned through garbage (exit 11, zero snapshots: the
    // one instruction that did execute and trace was lost to Important 3's
    // buffering bug on top of it).
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R1, #0x12
    BX LR
    END
    """, preload: MemoryPreload())
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[1] == 0x12)
    #expect(result.snapshots.count == 2)
}

@Test func importantFourEveryTraceRecordCarriesItsOwnInstructionAddress() throws {
    // Important 4: R15/PC was never written anywhere, so `pc` (and
    // `registers[15]`) were always 0 in every trace record — Spec §3, §7.7,
    // and §9 D2 all describe a feature that did not exist, and the app's PC
    // display and current-line highlight had nothing to read. CODE labels
    // advance 4 bytes per instruction (Spec §5.2), starting at `Analyser.origin`.
    let result = try Driver().run(source: exercise1a, preload: MemoryPreload())
    #expect(result.exitCode == 0)
    #expect(result.snapshots.count == 3)
    let origin = Analyser.origin
    #expect(result.snapshots.map(\.pc) == [origin, origin + 4, origin + 8])
    #expect(result.snapshots.map { $0.registers[15] } == [origin, origin + 4, origin + 8])
}

// MARK: - Re-review residual fixes

@Test func r2AdcProducesTheRightValueWithCarryClear() throws {
    // R2: `restoreFlags` clobbers w9 (holding Rn) before `adc` reads it back, so
    // ADC silently computes Rn's *destination* from the CPSR word instead of Rn.
    // ADDS here leaves C clear (5 + 1 does not overflow 32 bits), so ADC's carry
    // input is 0: R9 should end up R1 + R0 + 0 = 5.
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R1, #5
    ADDS R8, R1, #1
    ADC R9, R1, #0
    END
    """, preload: MemoryPreload())
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[8] == 6)
    #expect(result.finalRegisters[9] == 5)
}

@Test func r2AdcProducesTheRightValueWithCarrySet() throws {
    // Same shape, but the preceding ADDS overflows 32 bits (0xFF000000 + 0xFF000000
    // — 0xFF000000 is an ARM7-encodable modified immediate, an 8-bit value rotated
    // right by 8) and leaves C set, so ADC's carry input is 1: R9 should end up
    // R1 + R0 + 1 = 6.
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R1, #5
    MOV R2, #0XFF000000
    ADDS R8, R2, R2
    ADC R9, R1, #0
    END
    """, preload: MemoryPreload())
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[9] == 6)
}

@Test func r2SbcProducesTheRightValueAcrossBothCarryStates() throws {
    // R2: SBC reads NOT(borrow) from C, same clobber risk as ADC. `SUBS R8, R2,
    // R2` (0 - 0) leaves C set (no borrow — A64/ARM7 carry is inverted borrow for
    // subtraction), so `SBC R9, R1, #0` should compute R1 - 0 - 0 = R1.
    let noBorrow = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R1, #9
    MOV R2, #3
    SUBS R8, R2, R2
    SBC R9, R1, #0
    END
    """, preload: MemoryPreload())
    #expect(noBorrow.exitCode == 0)
    #expect(noBorrow.finalRegisters[9] == 9)

    // `SUBS R8, R2, R1` with R2 < R1 (3 - 9) borrows, clearing C, so
    // `SBC R9, R1, #0` should compute R1 - 0 - 1 = R1 - 1.
    let borrow = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R1, #9
    MOV R2, #3
    SUBS R8, R2, R1
    SBC R9, R1, #0
    END
    """, preload: MemoryPreload())
    #expect(borrow.exitCode == 0)
    #expect(borrow.finalRegisters[9] == 8)
}

@Test func r1TopLevelReturnAfterASubroutineDoesNotCorruptTheFrame() throws {
    // R1: the previous wave's "inside a call target" latch is monotonic — once any
    // call-target label (HELPER) is seen, every later return, including FINISH's
    // top-level one, is treated as though it has a frame to pop. FINISH never had
    // one pushed, so its `BX LR` pops the host prologue's own saved x27/x28 pair
    // and returns through garbage. Exact re-review repro.
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R4, #7
    BL HELPER
    B FINISH
    HELPER
    MOV R6, #2
    BX LR
    FINISH
    MOV R2, #9
    BX LR
    END
    """, preload: MemoryPreload())
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[4] == 7)
    #expect(result.finalRegisters[6] == 2)
    #expect(result.finalRegisters[2] == 9)
}

@Test func r1SubroutineDefinedBeforeItsCallerStillWorks() throws {
    // R1: the same latch bug, from the other direction — HELPER's call-target
    // label is seen *before* MAIN's, so by the time MAIN's own top-level `BX LR`
    // runs, the latch has already gone true and stays true. Nothing in the
    // previous wave's premise ("call targets are always written after their
    // callers") holds here.
    // ENTRY still marks MAIN (not HELPER) as the actual entry point — that's how
    // Keil ARMASM's ENTRY directive works, and moving it would test something
    // else entirely. What's unusual here is only that HELPER's *definition*
    // precedes MAIN's in the source, lexically ahead of the entry label.
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY

    HELPER
    MOV R6, #2
    BX LR
    ENTRY
    MAIN
    MOV R4, #7
    BL HELPER
    MOV R2, #9
    BX LR
    END
    """, preload: MemoryPreload())
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[4] == 7)
    #expect(result.finalRegisters[6] == 2)
    #expect(result.finalRegisters[2] == 9)
}

@Test func r1NestedSubroutinesEachReturnCorrectly() throws {
    // R1: MAIN calls SUBA, SUBA calls SUBB, each with its own frame and return —
    // confirms the fix handles more than one call-target region in a single
    // program, not just a single HELPER.
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R1, #1
    BL SUBA
    MOV R2, #2
    BX LR
    SUBA
    MOV R3, #3
    BL SUBB
    MOV R4, #4
    BX LR
    SUBB
    MOV R5, #5
    BX LR
    END
    """, preload: MemoryPreload())
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[1] == 1)
    #expect(result.finalRegisters[2] == 2)
    #expect(result.finalRegisters[3] == 3)
    #expect(result.finalRegisters[4] == 4)
    #expect(result.finalRegisters[5] == 5)
}

@Test func r2RscReversesItsOperandsAndReadsCarryCorrectly() throws {
    // R2: RSC is the most likely to hide a second bug on top of the clobber,
    // since it also reverses its operands (Op2 - Rn, not Rn - Op2). With C set
    // (no borrow) via `SUBS R8, R2, R2`, `RSC R9, R1, #20` should compute
    // 20 - R1 - 0 = 20 - 9 = 11.
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R1, #9
    MOV R2, #3
    SUBS R8, R2, R2
    RSC R9, R1, #20
    END
    """, preload: MemoryPreload())
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[9] == 11)
}
