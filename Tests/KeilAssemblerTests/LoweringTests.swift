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

// MARK: - Driver and data-processing lowering (Task 15)

private func lower(_ source: String) -> (String?, DiagnosticBag) {
    var bag = DiagnosticBag()
    let tokens = Lexer(source: source).tokenize(into: &bag)
    var parser = Parser(tokens: tokens)
    let program = parser.parse(into: &bag)
    let analysed = Analyser.analyse(program, into: &bag)
    return (Lowering.lower(analysed, into: &bag), bag)
}

private let preamble = """
    AREA PROGRAM, CODE, READONLY
    ENTRY
MAIN
"""

@Test func lowersAnAddToLoadOperateStore() {
    let (assembly, bag) = lower(preamble + "\n    ADD R4, R1, R2\n")
    #expect(bag.hasErrors == false)
    let text = assembly ?? ""
    #expect(text.contains("ldr     w9, [x27, #4]"))     // R1
    #expect(text.contains("ldr     w10, [x27, #8]"))    // R2
    #expect(text.contains("add     w11, w9, w10"))
    #expect(text.contains("str     w11, [x27, #16]"))   // R4
}

@Test func lowersMvnAndComparisons() {
    #expect((lower(preamble + "\n    MVN R2, R1\n").0 ?? "").contains("mvn     w11, w10"))
    #expect((lower(preamble + "\n    CMP R1, #4\n").0 ?? "").contains("subs    wzr, w9, w10"))
    #expect((lower(preamble + "\n    TST R1, R2\n").0 ?? "").contains("ands    wzr, w9, w10"))
}

@Test func setFlagsVariantsStoreTheCPSR() {
    let text = lower(preamble + "\n    MOVS R3, #0\n").0 ?? ""
    #expect(text.contains("ands    w11, w10, w10"))
    #expect(text.contains("mrs     x9, nzcv"))
    #expect(text.contains("str     w9, [x27, #64]"))
}

@Test func conditionalInstructionsAreGuardedByTheInverseBranch() {
    // Spec §6.1, §7.3.
    let text = lower(preamble + "\n    MOVEQ R3, R1\n").0 ?? ""
    #expect(text.contains("ldr     w9, [x27, #64]"))
    #expect(text.contains("msr     nzcv, x9"))
    #expect(text.contains("b.ne    Lskip_"))
}

@Test func everyInstructionEndsWithATraceCall() {
    let text = lower(preamble + "\n    MOV R1, #0x12\n").0 ?? ""
    #expect(text.contains("bl      _armd_trace"))
}

@Test func loweringRefusesToEmitWhenThereAreErrors() {
    let (assembly, bag) = lower(preamble + "\n    MOV R1, #0x101\n")
    #expect(bag.hasErrors)
    #expect(assembly == nil)      // Spec §8: a build with any error emits no assembly
}

// The brief's own tests above only exercise ADD, MVN, CMP, TST, MOVS and MOVEQ out of
// the ten-row `arithmetic(_:)` table. A wrong row there produces valid-looking assembly
// that computes the wrong answer — no type checker catches a transposed operand order or
// a stray `S`. Each test below pins exactly the row it would catch a regression in.

@Test func rsbAndRscReverseTheirOperands() {
    // Spec §7.5: RSB/RSC lower as `sub`/`sbc` with w10 and w9 swapped, not a distinct
    // A64 instruction. A `.rsb` row that forgot to reverse would emit
    // "sub     w11, w9, w10" (ADD/SUB's order) instead — this pins the swap.
    let rsb = lower(preamble + "\n    RSB R4, R1, R2\n").0 ?? ""
    #expect(rsb.contains("sub     w11, w10, w9"))
    #expect(!rsb.contains("sub     w11, w9, w10"))

    // RSC also restores C before operating (it reads carry), on top of the reversal.
    let rsc = lower(preamble + "\n    RSC R4, R1, R2\n").0 ?? ""
    #expect(rsc.contains("ldr     w9, [x27, #64]"))
    #expect(rsc.contains("msr     nzcv, x9"))
    #expect(rsc.contains("sbc     w11, w10, w9"))
}

@Test func carryConsumingInstructionsRestoreFlagsBeforeOperating() {
    // Spec §7.5: ADC/SBC read C from the CPSR before operating, unlike ADD/SUB. A
    // wrong implementation that treated ADC like ADD (skipping the restore) would
    // still produce plausible-looking `adc` text but read whatever PSTATE.C happens
    // to hold after the preceding `bl _armd_trace` — garbage, not ARM7's C.
    let adc = lower(preamble + "\n    ADC R4, R1, R2\n").0 ?? ""
    #expect(adc.contains("ldr     w9, [x27, #64]"))
    #expect(adc.contains("msr     nzcv, x9"))
    #expect(adc.contains("adc     w11, w9, w10"))

    let sbc = lower(preamble + "\n    SBC R4, R1, R2\n").0 ?? ""
    #expect(sbc.contains("ldr     w9, [x27, #64]"))
    #expect(sbc.contains("msr     nzcv, x9"))
    #expect(sbc.contains("sbc     w11, w9, w10"))

    // ADD does NOT restore flags first — it doesn't read carry. Pinning the absence
    // catches an implementation that restored flags unconditionally for every mnemonic.
    let add = lower(preamble + "\n    ADD R4, R1, R2\n").0 ?? ""
    #expect(!add.contains("msr     nzcv"))
}

@Test func andAndBicUseTheirOwnNativeFlagSettingForms() {
    // Spec §7.5: AND/BIC have native `ands`/`bics` A64 forms, unlike ORR/EOR. A row
    // that copied the ORR/EOR "ands trick" onto AND or BIC would look plausible but
    // emit a redundant/wrong second instruction instead of the native `S` form.
    let and = lower(preamble + "\n    AND R4, R1, R2\n").0 ?? ""
    #expect(and.contains("and     w11, w9, w10"))

    let ands = lower(preamble + "\n    ANDS R4, R1, R2\n").0 ?? ""
    #expect(ands.contains("ands    w11, w9, w10"))
    #expect(ands.contains("mrs     x9, nzcv"))

    let bic = lower(preamble + "\n    BIC R4, R1, R2\n").0 ?? ""
    #expect(bic.contains("bic     w11, w9, w10"))

    let bics = lower(preamble + "\n    BICS R4, R1, R2\n").0 ?? ""
    #expect(bics.contains("bics    w11, w9, w10"))
    #expect(bics.contains("mrs     x9, nzcv"))
}

@Test func orrAndEorHaveNoFlagSettingFormAndUseTheAndsTrick() {
    // Spec §7.5/§7.12: ORR/EOR emit the plain `orr`/`eor` unconditionally (never
    // `orrs`/`eors` — A64 has no such form), and `S` is realised by a *following*
    // `ands w11, w11, w11`. An implementation that emitted `orrs`/`eors` directly
    // would assemble to a different (wrong) opcode; one that omitted the trailing
    // `ands` for the S variant would silently never update N/Z.
    let orr = lower(preamble + "\n    ORR R4, R1, R2\n").0 ?? ""
    #expect(orr.contains("orr     w11, w9, w10"))
    #expect(!orr.contains("orrs"))

    let orrs = lower(preamble + "\n    ORRS R4, R1, R2\n").0 ?? ""
    #expect(orrs.contains("orr     w11, w9, w10"))
    #expect(orrs.contains("ands    w11, w11, w11"))
    #expect(!orrs.contains("orrs"))
    #expect(orrs.contains("mrs     x9, nzcv"))

    let eors = lower(preamble + "\n    EORS R4, R1, R2\n").0 ?? ""
    #expect(eors.contains("eor     w11, w9, w10"))
    #expect(eors.contains("ands    w11, w11, w11"))
    #expect(!eors.contains("eors"))
}

@Test func subUsesTheNativeSubsForm() {
    // Rounds out ADD/SUB (the "native adds/subs" S-suffix shape) — the brief's own
    // tests only cover ADD unsuffixed; this pins SUB and its S-suffixed sibling.
    let sub = lower(preamble + "\n    SUB R4, R1, R2\n").0 ?? ""
    #expect(sub.contains("sub     w11, w9, w10"))

    let subs = lower(preamble + "\n    SUBS R4, R1, R2\n").0 ?? ""
    #expect(subs.contains("subs    w11, w9, w10"))
    #expect(subs.contains("mrs     x9, nzcv"))
}

@Test func cmnAndTeqAlwaysSetFlagsRegardlessOfAnSSuffix() {
    // Spec §6.3: CMP/CMN/TST/TEQ always set flags and have no destination — a fourth
    // shape distinct from both "native S" and the ORR/EOR trick. TEQ additionally has
    // no direct A64 opcode at all: it's synthesised from `eor` + `ands`.
    let cmn = lower(preamble + "\n    CMN R1, R2\n").0 ?? ""
    #expect(cmn.contains("adds    wzr, w9, w10"))
    #expect(cmn.contains("mrs     x9, nzcv"))

    let teq = lower(preamble + "\n    TEQ R1, R2\n").0 ?? ""
    #expect(teq.contains("eor     w11, w9, w10"))
    #expect(teq.contains("ands    wzr, w11, w11"))
    #expect(teq.contains("mrs     x9, nzcv"))
}

@Test func mulAndMlaLowerToTheirA64Forms() {
    // MUL/MLA are their own operand shape entirely (three or four registers, no
    // Operand2), sharing nothing with the arithmetic table — a plausible but wrong
    // implementation could easily swap the multiply-add's operand order.
    let mul = lower(preamble + "\n    MUL R4, R1, R2\n").0 ?? ""
    #expect(mul.contains("ldr     w9, [x27, #4]"))    // R1
    #expect(mul.contains("ldr     w10, [x27, #8]"))   // R2
    #expect(mul.contains("mul     w11, w9, w10"))
    #expect(mul.contains("str     w11, [x27, #16]"))  // R4

    let mla = lower(preamble + "\n    MLA R4, R1, R2, R3\n").0 ?? ""
    #expect(mla.contains("ldr     w9, [x27, #4]"))    // R1 (multiplicand)
    #expect(mla.contains("ldr     w10, [x27, #8]"))   // R2 (multiplier)
    #expect(mla.contains("ldr     w12, [x27, #12]"))  // R3 (addend)
    #expect(mla.contains("madd    w11, w9, w10, w12"))
    #expect(mla.contains("str     w11, [x27, #16]"))  // R4
}

@Test func entryLabelLandsOnTheFirstLineWhenEntryIsFirst() {
    // Confirms §7.9's `b Lentry` target is placed correctly when ENTRY is the very
    // first statement in the program, and that the label appears exactly once — a
    // driver that emitted it once per instruction, or never advanced `entryEmitted`,
    // would either duplicate the label (an assembler error) or omit it entirely.
    let text = lower(preamble + "\n    MOV R1, #1\n").0 ?? ""
    let entryCount = text.components(separatedBy: "Larmd_entry:").count - 1
    #expect(entryCount == 1)
    // The entry label must precede the first lowered instruction's load, not follow it.
    let entryRange = text.range(of: "Larmd_entry:")
    let loadRange = text.range(of: "movz    w10, #0x1")
    #expect(entryRange != nil && loadRange != nil)
    if let entryRange, let loadRange {
        #expect(entryRange.lowerBound < loadRange.lowerBound)
    }
}

@Test func entryLabelLandsAfterEntryWhenItFollowsOtherStatements() {
    // Same guarantee, but for a program where ENTRY is not the first line — the
    // label must still land exactly once, and specifically after the ENTRY
    // directive rather than at the top of the program (which a driver that only
    // checked `index == 0` would get wrong).
    let source = """
        AREA PROGRAM, CODE, READONLY
    BEFORE
        MOV R2, #2
        ENTRY
    MAIN
        MOV R1, #1
    """
    let text = lower(source + "\n").0 ?? ""
    let entryCount = text.components(separatedBy: "Larmd_entry:").count - 1
    #expect(entryCount == 1)

    let entryRange = text.range(of: "Larmd_entry:")
    let firstLoad = text.range(of: "movz    w10, #0x2")   // MOV R2, #2 — before ENTRY
    let secondLoad = text.range(of: "movz    w10, #0x1")  // MOV R1, #1 — after ENTRY
    #expect(entryRange != nil && firstLoad != nil && secondLoad != nil)
    if let entryRange, let firstLoad, let secondLoad {
        #expect(firstLoad.lowerBound < entryRange.lowerBound)
        #expect(entryRange.lowerBound < secondLoad.lowerBound)
    }
}

@Test func skipLabelsAreUniquePerConditionalInstruction() {
    // Spec §18 concern: `skipCounter` must mint a distinct label per conditional
    // instruction. Two conditional instructions in one program that produced the
    // same `Lskip_N` label would be a silent assembler error (duplicate label), not
    // a crash — this test would only pass if both distinct labels are present.
    let text = lower(preamble + "\n    MOVEQ R1, R2\n    MOVNE R3, R4\n").0 ?? ""
    #expect(text.contains("Lskip_0:"))
    #expect(text.contains("Lskip_1:"))
    #expect(!text.contains("Lskip_2"))
}

@Test func unconditionalInstructionsEmitNoGuard() {
    // `Condition.al` returns nil from `inverseBranchSuffix`, so an AL instruction
    // must emit no skip branch at all. An implementation that always emitted a
    // guard (even a `b.al`) would still "work" at runtime but would violate the
    // brief's stated contract and pollute the output with dead branches.
    let text = lower(preamble + "\n    MOV R1, #1\n").0 ?? ""
    #expect(!text.contains("b.al"))
    #expect(!text.contains("Lskip_"))
}

// MARK: - Review fixes (Task 15 review round)

@Test func movPCFromLRLowersToTheReturnSequence() {
    // `MOV PC, LR` is the spec-named function-return idiom (Spec §7.5's "Branch"
    // paragraph; `Analyser.check` explicitly carves it out of E021 since it's a
    // sanctioned write to R15). Task 15 deferred it (E013) because routing it
    // through the ordinary `.mov` case would silently store LR's value into R15's
    // *display slot* instead of returning. Task 16 implements the real lowering:
    // identical to `BX LR` (Spec §7.5) — pop the frame, then `ret` — not a plain
    // register move and not an error anymore.
    let (assembly, bag) = lower(preamble + "\n    MOV PC, LR\n")
    #expect(bag.hasErrors == false)
    let text = assembly ?? ""
    #expect(text.contains("ldp     x29, x30, [sp], #16"))
    #expect(text.contains("ret"))
    // It must not fall through to the ordinary MOV path (which would store into
    // R15's display slot at offset 60 instead of returning).
    #expect(!text.contains("str     w11, [x27, #60]"))
}

@Test func loweringRefusesToEmitWhenAnOperandIsInvalidDuringLowering() {
    // Spec §8: this is a *different* error path than `loweringRefusesToEmitWhenThereAreErrors`
    // above (which pins an error raised during Analysis, before `lower` even runs).
    // `ADD R1, R2, [R3]` passes the Analyser untouched — its operand-checking loop
    // has no `.address` case — and only fails once `Lowering.materialise` reaches
    // its `default:` arm and emits E037. An implementation that only checked
    // `diagnostics.hasErrors` at entry (pre-existing errors) but not after lowering
    // itself accumulates a new one would wrongly return real assembly text here.
    let (assembly, bag) = lower(preamble + "\n    ADD R1, R2, [R3]\n")
    #expect(bag.hasErrors)
    #expect(assembly == nil)
    let diagnostic = bag.diagnostics.first { $0.code == "E037" }
    #expect(diagnostic != nil)
}

@Test func plainMovEmitsMovNotAnds() {
    // Distinguishes unsuffixed MOV from MOVS: a regression that made plain MOV
    // take the `ands`-based MOVS path would still "work" (N/Z would just be an
    // unwanted side effect) but would violate Spec §7.5's row for `MOV Rd, Op2`,
    // and no other test pins the unsuffixed form's exact text.
    let text = lower(preamble + "\n    MOV R1, #1\n").0 ?? ""
    #expect(text.contains("mov     w11, w10"))
    #expect(!text.contains("ands    w11, w10, w10"))
}

@Test func nativeSSuffixRowsEmitTheCorrectSuffixedMnemonic() {
    // Spec §7.5: ADDS is the table's first S-suffixed example; SBCS/RSBS/RSCS
    // round out the carry-consuming/reversed-operand rows that weren't pinned
    // anywhere else. A regression that dropped the `s` in just one arithmetic()
    // case (e.g. `.add` while leaving `.sub` intact) would pass every other test
    // in this file but is caught here.
    #expect((lower(preamble + "\n    ADDS R4, R1, R2\n").0 ?? "").contains("adds    w11, w9, w10"))
    #expect((lower(preamble + "\n    ADCS R4, R1, R2\n").0 ?? "").contains("adc     w11, w9, w10") == false)
    #expect((lower(preamble + "\n    ADCS R4, R1, R2\n").0 ?? "").contains("adcs    w11, w9, w10"))
    #expect((lower(preamble + "\n    SBCS R4, R1, R2\n").0 ?? "").contains("sbcs    w11, w9, w10"))
    #expect((lower(preamble + "\n    RSBS R4, R1, R2\n").0 ?? "").contains("subs    w11, w10, w9"))
    #expect((lower(preamble + "\n    RSCS R4, R1, R2\n").0 ?? "").contains("sbcs    w11, w10, w9"))
}

@Test func unsuffixedEorEmitsPlainEor() {
    // `EORS`'s ands-trick shape is already pinned by
    // `orrAndEorHaveNoFlagSettingFormAndUseTheAndsTrick`, but nothing previously
    // asserted unsuffixed `EOR`'s own text — a regression that only fixed EORS's
    // string but broke plain EOR's `pad("eor")` call would pass every existing test.
    let text = lower(preamble + "\n    EOR R4, R1, R2\n").0 ?? ""
    #expect(text.contains("eor     w11, w9, w10"))
    #expect(!text.contains("ands    w11, w11, w11"))
}

// MARK: - Memory and branch lowering (Task 16)

@Test func indirectLoadGoesThroughTheMemoryBase() {
    // Spec §7.5: ldr w11, [x28, w9, uxtw]
    let text = lower(preamble + "\n    LDR R3, [R1]\n").0 ?? ""
    #expect(text.contains("ldr     w9, [x27, #4]"))
    #expect(text.contains("ldr     w11, [x28, w9, uxtw]"))
    #expect(text.contains("str     w11, [x27, #12]"))
}

@Test func literalLoadReadsTheWordAtTheLabel() {
    // Spec §7.6: LDR Rd, label loads the *contents* of the label.
    let text = lower("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        LDR R1, VALUE
        AREA STORAGE, DATA, READONLY
    VALUE DCD &3000F000
    """).0 ?? ""
    #expect(text.contains("[x28, w9, uxtw]"))
}

@Test func ldrEqualsMaterialisesTheValueWithNoMemoryAccess() {
    // Spec §7.6: LDR Rd, =expr is a pseudo-instruction.
    let text = lower(preamble + "\n    LDR R1, =0x3000F000\n").0 ?? ""
    #expect(text.contains("movz    w11, #0xf000"))
    #expect(text.contains("movk    w11, #0x3000, lsl #16"))
    #expect(text.contains("[x28,") == false)
}

@Test func storesPassTheirEffectiveAddressToTheTrace() {
    // Spec §7.7 as corrected: the address comes from w9, not an immediate.
    let text = lower(preamble + "\n    STR R3, [R1]\n").0 ?? ""
    #expect(text.contains("str     w11, [x28, w9, uxtw]"))
    #expect(text.contains("mov     w1, w9"))
    #expect(text.contains("movz    w2, #4"))
}

@Test func postIndexedAccessHappensExactlyOnceThenWritesBack() {
    let text = lower(preamble + "\n    LDR R3, [R1], #4\n").0 ?? ""
    // One access, not two: the address mode computes, the shared block accesses.
    #expect(text.components(separatedBy: "[x28, w9, uxtw]").count - 1 == 1)
    #expect(text.contains("add     w12, w9, w12"))
    #expect(text.contains("str     w12, [x27, #4]"))     // R1 written back
}

@Test func pushAndPopMoveTheARM7StackPointer() {
    let text = lower(preamble + "\n    PUSH {R1, R4}\n").0 ?? ""
    #expect(text.contains("ldr     w9, [x27, #52]"))   // R13
    #expect(text.contains("str     w11, [x28, w9, uxtw]"))
    #expect(text.contains("str     w9, [x27, #52]"))
}

// The brief's own PUSH/POP tests above only exercise PUSH. An off-by-one in the
// slot offsets, or a POP that adjusts SP before rather than after reading, would
// corrupt the stack silently — with no test failure until Task 18 runs a program.
// Round-trip PUSH then POP on the same register list and pin that POP reads slot 0
// (the lowest register) straight through w9, exactly where PUSH wrote it, and that
// SP is restored only after every register has been read back.

@Test func popMirrorsPushWithLowestRegisterAtTheLowestAddress() {
    let text = lower(preamble + "\n    PUSH {R1, R4}\n    POP {R1, R4}\n").0 ?? ""
    // POP's slot-0 read (R1, the lowest register) goes straight through w9, just
    // like PUSH's slot-0 write did — no offset arithmetic needed for either.
    let popSlot0 = text.range(of: "ldr     w11, [x28, w9, uxtw]")
    let popStoreR1 = text.range(of: "str     w11, [x27, #4]")     // R1
    #expect(popSlot0 != nil && popStoreR1 != nil)
    if let popSlot0, let popStoreR1 { #expect(popSlot0.lowerBound < popStoreR1.lowerBound) }

    // Slot 1 (R4) needs the +4 offset, computed into w12.
    #expect(text.contains("add     w12, w9, #4"))
    #expect(text.contains("ldr     w11, [x28, w12, uxtw]"))
    #expect(text.contains("str     w11, [x27, #16]"))            // R4

    // SP (R13) is restored only after both registers are read back, and by the
    // count of registers popped (2 * 4 = 8) — not before, and not by the wrong amount.
    let lastRegisterRead = text.range(of: "str     w11, [x27, #16]")
    let spRestored = text.range(of: "add     w9, w9, #8")
    #expect(lastRegisterRead != nil && spRestored != nil)
    if let lastRegisterRead, let spRestored { #expect(lastRegisterRead.lowerBound < spRestored.lowerBound) }
    #expect(text.contains("str     w9, [x27, #52]"))             // R13 written back
}

// `accessWidth` and `widthSuffix` must agree, or a byte/halfword access silently
// reads/writes the wrong number of bytes and records the wrong width in the trace —
// corrupting neighbouring memory with no diagnostic anywhere.

@Test func byteAndHalfwordAccessesUseMatchingWidthSuffixesAndTraceWidths() {
    let strb = lower(preamble + "\n    STRB R3, [R1]\n").0 ?? ""
    #expect(strb.contains("strb    w11, [x28, w9, uxtw]"))
    #expect(strb.contains("movz    w2, #1"))

    let ldrb = lower(preamble + "\n    LDRB R3, [R1]\n").0 ?? ""
    #expect(ldrb.contains("ldrb    w11, [x28, w9, uxtw]"))
    #expect(ldrb.contains("mov     w1, wzr"))   // a load performs no store

    let strh = lower(preamble + "\n    STRH R3, [R1]\n").0 ?? ""
    #expect(strh.contains("strh    w11, [x28, w9, uxtw]"))
    #expect(strh.contains("movz    w2, #2"))

    let ldrh = lower(preamble + "\n    LDRH R3, [R1]\n").0 ?? ""
    #expect(ldrh.contains("ldrh    w11, [x28, w9, uxtw]"))
}

// Spec §7.5: "Pre-index writes w9 back to Rn before the access" — the opposite
// order from post-index (Rn+offset, then write back after). A driver that got this
// backwards would still pass a bare `contains` check on each instruction; only the
// ordering exposes it.

@Test func preIndexedWriteBackHappensBeforeTheAccess() {
    let text = lower(preamble + "\n    STR R3, [R1, #4]!\n").0 ?? ""
    let writeBack = text.range(of: "str     w9, [x27, #4]")       // R1 written back
    let access = text.range(of: "str     w11, [x28, w9, uxtw]")   // the actual store
    #expect(writeBack != nil && access != nil)
    if let writeBack, let access { #expect(writeBack.lowerBound < access.lowerBound) }
}

// Spec §7.5: every BL target opens a frame so its return sequence (BX LR / MOV PC,
// LR's `ldp`/`ret`) has something to pop, and BL/B trace *before* branching so the
// branch stays the block's last instruction.

@Test func blTargetsGetAFramePrologueAndTraceBeforeTheBranch() {
    let text = lower("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        BL CALLEE
        MOV R1, #1
    CALLEE
        MOV PC, LR
    """).0 ?? ""
    #expect(text.contains("Larm7_CALLEE:\n        stp     x29, x30, [sp, #-16]!"))
    let traceCall = text.range(of: "bl      _armd_trace")
    let branch = text.range(of: "\(Lowering.pad("bl"))Larm7_CALLEE")
    #expect(traceCall != nil && branch != nil)
    if let traceCall, let branch { #expect(traceCall.lowerBound < branch.lowerBound) }
}

// MARK: - Task 16 review round (Critical findings)

@Test func malformedBXProducesADiagnosticInsteadOfSilentlyReturning() {
    // Critical 1: the `.bx` case performed no operand-shape check at all, unlike
    // every other case in this file. `Analyser.check`'s E014 guard only fires for
    // `.operand2(.register(n))` with n != 14 — any *other* shape (a bare `BX` with
    // no operand, `BX #5`, ...) matched nothing there either, so it silently
    // lowered to a valid `ldp`/`ret` exactly as though the source said `BX LR`.
    // Before Task 16 these fell to `default:` -> E013; this pins that they still
    // error now that `.bx` is a real case, just via a different guard.
    let immediate = lower(preamble + "\n    BX #5\n")
    #expect(immediate.1.hasErrors)
    #expect(immediate.0 == nil)
    #expect(immediate.1.diagnostics.map(\.code).contains("E013"))

    let bare = lower(preamble + "\n    BX\n")
    #expect(bare.1.hasErrors)
    #expect(bare.0 == nil)
    #expect(bare.1.diagnostics.map(\.code).contains("E013"))
}

@Test func addressModeRRXIsDiagnosedNotSilentlyDropped() {
    // Critical 2: `registerOffset`'s shift handling was gated on
    // `let amountExpression = shift.amount` — but RRX never carries `#k` (the
    // parser permits exactly that), so `shift.amount` is always nil for RRX and
    // the entire shift block, rotate included, was skipped in total silence:
    // `STR R3, [R1, R2, RRX]` computed address = R1+R2 with the rotate dropped
    // and emitted no diagnostic anywhere. `materialiseOperand2` one function away
    // already gets this right (E036) — mirror it here.
    let (assembly, bag) = lower(preamble + "\n    STR R3, [R1, R2, RRX]\n")
    #expect(bag.hasErrors)
    #expect(assembly == nil)
    let diagnostic = bag.diagnostics.first { $0.code == "E036" }
    #expect(diagnostic != nil)
    #expect(diagnostic?.note == "Spec §7.4 leaves the RRX sequence undefined; see Spec §9 D1")
}

@Test func bxLrLowersToTheReturnSequence() {
    // Important 4: `BX LR` had no dedicated Lowering test even though it's one of
    // the two return-sequence idioms named in the brief — exactly where Critical 1
    // lived. Positive companion to `malformedBXProducesADiagnosticInsteadOfSilentlyReturning`.
    let (assembly, bag) = lower(preamble + "\n    BX LR\n")
    #expect(bag.hasErrors == false)
    let text = assembly ?? ""
    #expect(text.contains("ldp     x29, x30, [sp], #16"))
    #expect(text.contains("ret"))
}

@Test func adrMaterialisesTheLabelAddressNotItsContents() {
    // Important 4: `ADR` had no dedicated Lowering test. Spec §7.6: `ADR Rd, label`
    // is the label's *address*; `LDR Rd, label` is its *contents* — a regression
    // that collapsed ADR onto the LDR-label path would still assemble (valid A64)
    // but silently read through memory instead of just materialising the address.
    let text = lower("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        ADR R1, VALUE
        AREA STORAGE, DATA, READONLY
    VALUE DCD &3000F000
    """).0 ?? ""
    #expect(text.contains("str     w11, [x27, #4]"))   // R1
    #expect(!text.contains("[x28,"))                    // no memory access at all
}

@Test func stmfdWithExplicitStackPointerWritebackParses() {
    // Important 3: `STMFD SP!, {reglist}` is the spec-legal spelling (§6.3), but
    // `parseOperand` only consumed a `!` writeback marker inside `[...]` — a bare
    // `SP!` outside brackets fell through to the missing-comma check and produced
    // E040, never reaching Lowering at all. STMFD/LDMFD's lowering already
    // hardcodes R13 as the base, so the parsed base register is informational —
    // but the spelling itself must parse and reach Lowering.
    let text = lower(preamble + "\n    STMFD SP!, {R1, R4}\n").0 ?? ""
    #expect(text.contains("ldr     w9, [x27, #52]"))    // R13
    #expect(text.contains("str     w11, [x28, w9, uxtw]"))
}
