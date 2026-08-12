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
