import Testing
@testable import KeilAssembler

@Test func builderIndentsInstructionsButNotLabels() {
    var builder = AssemblyBuilder()
    builder.label("Lmain")
    builder.instruction("mov w0, #1")
    builder.comment("a note")
    #expect(builder.text == "Lmain:\n        mov w0, #1\n        ; a note\n")
}

@Test func registerAccessUsesTheNormativeOffsets() {
    // Spec §7.2: Rn at [x27, #(n*4)], cpsr at [x27, #0x40].
    var builder = AssemblyBuilder()
    Emitter.loadRegister(1, into: "w9", into: &builder)
    Emitter.storeRegister(4, from: "w11", into: &builder)
    #expect(builder.text.contains("ldr     w9, [x27, #4]"))
    #expect(builder.text.contains("str     w11, [x27, #16]"))
    #expect(Emitter.cpsrOffset == 0x40)
}

@Test func immediatesUseMovzThenMovk() {
    // Spec §7.4: always two instructions, always correct, no encoding analysis.
    var builder = AssemblyBuilder()
    Emitter.materialiseImmediate(0x3000_F000, into: "w10", into: &builder)
    #expect(builder.text.contains("movz    w10, #0xf000"))
    #expect(builder.text.contains("movk    w10, #0x3000, lsl #16"))
}

@Test func immediatesSkipMovkWhenTheHighHalfIsZero() {
    // movz zeroes the rest of the register, so a zero high half needs no movk —
    // this is the one-instruction path Tasks 14-16 rely on for every small #imm.
    var builder = AssemblyBuilder()
    Emitter.materialiseImmediate(7, into: "w0", into: &builder)
    #expect(builder.text == "        movz    w0, #0x7\n")
    #expect(!builder.text.contains("movk"))
}

@Test func frameEmitsThePrologueAndEpilogueInMirroredOrder() {
    // Spec §7.9: a mismatched stp/ldp pairing corrupts the host stack and would
    // only surface when a program actually runs, tasks later. Pin the exact text,
    // including that the epilogue's ldp order is the reverse of the prologue's stp order.
    var builder = AssemblyBuilder()
    Emitter.prologue(entryLabel: "Lentry", into: &builder)
    Emitter.epilogue(into: &builder)
    let expected = [
        "        .section __TEXT,__text",
        "        .globl _main",
        "        .p2align 2",
        "_main:",
        "        stp     x29, x30, [sp, #-16]!",
        "        stp     x27, x28, [sp, #-16]!",
        "        bl      _armd_init",
        "        mov     x28, x0",
        "        adrp    x27, _armd_state@PAGE",
        "        add     x27, x27, _armd_state@PAGEOFF",
        "        b       Lentry",
        "",
        "",
        "Larmd_exit:",
        "        bl      _armd_fini",
        "        mov     w0, #0",
        "        ldp     x27, x28, [sp], #16",
        "        ldp     x29, x30, [sp], #16",
        "        ret",
    ].map { $0 + "\n" }.joined()
    #expect(builder.text == expected)
}

@Test func flagsRoundTripThroughTheCPSRSlot() {
    // Spec §7.3: bl to a runtime helper clobbers PSTATE, so CPSR is the source of truth.
    var builder = AssemblyBuilder()
    Emitter.saveFlags(into: &builder)
    Emitter.restoreFlags(into: &builder)
    #expect(builder.text.contains("mrs     x9, nzcv"))
    #expect(builder.text.contains("str     w9, [x27, #64]"))
    #expect(builder.text.contains("ldr     w9, [x27, #64]"))
    #expect(builder.text.contains("msr     nzcv, x9"))
}

@Test func traceCallPassesTheStoreAddressFromW9() {
    // Spec §7.7: the store address is a runtime value, not an immediate.
    var builder = AssemblyBuilder()
    Emitter.trace(line: 7, storeAddressRegister: "w9", storeWidth: 4, into: &builder)
    #expect(builder.text.contains("movz    w0, #7"))
    #expect(builder.text.contains("mov     w1, w9"))
    #expect(builder.text.contains("movz    w2, #4"))
    #expect(builder.text.contains("bl      _armd_trace"))

    var plain = AssemblyBuilder()
    Emitter.trace(line: 2, storeAddressRegister: nil, storeWidth: 0, into: &plain)
    #expect(plain.text.contains("mov     w1, wzr"))
    #expect(plain.text.contains("mov     w2, wzr"))
}

// MARK: - Operand2 materialisation (Task 14, Spec §7.4)

private func materialise(_ operand2: Operand2) -> String {
    var builder = AssemblyBuilder()
    var bag = DiagnosticBag()
    Lowering.materialiseOperand2(
        operand2, symbols: SymbolTable(), address: 0,
        range: SourceRange(line: 0, column: 0, length: 0),
        into: &builder, diagnostics: &bag
    )
    return builder.text
}

@Test func operand2AlwaysLandsInW10() {
    #expect(materialise(.immediate(.integer(0x12))).contains("movz    w10, #0x12"))
    #expect(materialise(.register(2)).contains("ldr     w10, [x27, #8]"))
}

@Test func shiftByImmediateUsesTheFixedShiftForm() {
    let text = materialise(.shifted(register: 1, shift: ShiftSpec(kind: .lsl, amount: .integer(2))))
    #expect(text.contains("ldr     w10, [x27, #4]"))
    #expect(text.contains("lsl     w10, w10, #2"))
}

@Test func shiftByRegisterUsesTheVariableShiftForm() {
    // Spec §7.4: A64 has no register-shifted operand, so it becomes lslv/lsrv/asrv/rorv.
    let text = materialise(.shifted(register: 1, shift: ShiftSpec(kind: .lsr, amountRegister: 2)))
    #expect(text.contains("ldr     w10, [x27, #4]"))
    #expect(text.contains("ldr     w11, [x27, #8]"))
    #expect(text.contains("lsrv    w10, w10, w11"))
}

// The brief pins LSL-by-immediate and LSR-by-register. A `variableMnemonic` that
// returned the wrong suffix, or a fixed-shift path that ignored `shift.kind`
// (e.g. always emitting `lsl`), would still pass those two cases. Pin the other
// six kind/amount-form combinations so such a mistake fails immediately.

@Test func shiftByImmediateCoversEveryFixedKind() {
    #expect(materialise(.shifted(register: 1, shift: ShiftSpec(kind: .lsr, amount: .integer(3))))
        .contains("lsr     w10, w10, #3"))
    #expect(materialise(.shifted(register: 1, shift: ShiftSpec(kind: .asr, amount: .integer(4))))
        .contains("asr     w10, w10, #4"))
    #expect(materialise(.shifted(register: 1, shift: ShiftSpec(kind: .ror, amount: .integer(5))))
        .contains("ror     w10, w10, #5"))
}

@Test func shiftByRegisterCoversEveryVariableKind() {
    #expect(materialise(.shifted(register: 1, shift: ShiftSpec(kind: .lsl, amountRegister: 2)))
        .contains("lslv    w10, w10, w11"))
    #expect(materialise(.shifted(register: 1, shift: ShiftSpec(kind: .asr, amountRegister: 2)))
        .contains("asrv    w10, w10, w11"))
    #expect(materialise(.shifted(register: 1, shift: ShiftSpec(kind: .ror, amountRegister: 2)))
        .contains("rorv    w10, w10, w11"))
}

@Test func rrxIsDiagnosedNotLowered() {
    // Spec §7.4's RRX row defers to §9 D1, which never defines the sequence. A
    // real implementation must refuse via E036, not guess and emit wrong output —
    // so this checks the diagnostic itself, not just "no crash".
    var builder = AssemblyBuilder()
    var bag = DiagnosticBag()
    let range = SourceRange(line: 3, column: 5, length: 1)
    Lowering.materialiseOperand2(
        .shifted(register: 1, shift: ShiftSpec(kind: .rrx)),
        symbols: SymbolTable(), address: 0, range: range,
        into: &builder, diagnostics: &bag
    )
    #expect(bag.hasErrors)
    let diagnostic = bag.diagnostics.first { $0.code == "E036" }
    #expect(diagnostic?.severity == .error)
    #expect(diagnostic?.range == range)
    // Spec §7.4's RRX row defers to §9 D1 (shifter-carry), not §12 ("Alternatives
    // considered") — pin the correct cross-reference so a copy-paste slip regresses loudly.
    #expect(diagnostic?.note == "Spec §7.4 leaves the RRX sequence undefined; see Spec §9 D1")
    // The register load still happens before the diagnosis; no shift instruction follows.
    #expect(builder.text.contains("ldr     w10, [x27, #4]"))
    #expect(!builder.text.contains("rrx"))
}

@Test func padColumnAlignsMnemonicsUnderEightCharacters() {
    // Every real mnemonic pad() sees here (lsl/lsr/asr/ror, and their v-suffixed
    // register forms) is under 8 characters, so this is the width that matters.
    #expect(Lowering.pad("lsl") == "lsl     ")
    #expect(Lowering.pad("lslv") == "lslv    ")
    #expect(Lowering.pad("lsl").count == 8)
    #expect(Lowering.pad("lslv").count == 8)
}

@Test func padLeavesEightCharacterMnemonicsUnpaddedButNoRealMnemonicReachesThat() {
    // `padding(toLength: max(count, 8), ...)` never truncates, but for a mnemonic
    // already >= 8 characters it also adds no separating space — the next token
    // would run straight into it. Document that limitation, and confirm no shift
    // mnemonic this file ever emits is long enough to trigger it.
    #expect(Lowering.pad("abcdefgh") == "abcdefgh")
    for kind in ShiftKind.allCases {
        #expect(kind.rawValue.count < 8)
        #expect(kind.variableMnemonic.count < 8)
    }
}
