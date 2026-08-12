/// Spec §7.1–7.3, §7.7, §7.9. Host register roles are normative:
/// x27 = register file, x28 = ARM7 memory base, w9–w12 scratch.
enum Emitter {
    static let cpsrOffset = 0x40

    static func armLabel(_ name: String) -> String { "Larm7_\(name)" }

    // MARK: - Register file (Spec §7.2)

    static func loadRegister(_ number: Int, into hostRegister: String, into builder: inout AssemblyBuilder) {
        builder.instruction("ldr     \(hostRegister), [x27, #\(number * 4)]")
    }

    static func storeRegister(_ number: Int, from hostRegister: String, into builder: inout AssemblyBuilder) {
        builder.instruction("str     \(hostRegister), [x27, #\(number * 4)]")
    }

    // MARK: - Immediates (Spec §7.4)

    /// movz/movk unconditionally: always two instructions, always correct.
    /// ARM7-side legality is a separate diagnostic, enforced in Task 11.
    static func materialiseImmediate(_ value: UInt32, into hostRegister: String, into builder: inout AssemblyBuilder) {
        let low = value & 0xFFFF
        let high = value >> 16
        builder.instruction("movz    \(hostRegister), #0x\(String(low, radix: 16))")
        if high != 0 {
            builder.instruction("movk    \(hostRegister), #0x\(String(high, radix: 16)), lsl #16")
        }
    }

    // MARK: - Flags (Spec §7.3)

    static func saveFlags(into builder: inout AssemblyBuilder) {
        builder.instruction("mrs     x9, nzcv")
        builder.instruction("str     w9, [x27, #\(cpsrOffset)]")
    }

    static func restoreFlags(into builder: inout AssemblyBuilder) {
        builder.instruction("ldr     w9, [x27, #\(cpsrOffset)]")
        builder.instruction("msr     nzcv, x9")
    }

    // MARK: - Trace (Spec §7.7)

    /// `storeAddressRegister` is the scratch register still holding the effective
    /// ARM7 address of a store, or nil when the instruction performs no store.
    ///
    /// The source line index and store width are debugging metadata (not encoded
    /// operand bits), so they are materialised in decimal — `movz w0, #7`, not
    /// `movz w0, #0x7` — with `movk` only for line indices >= 65536.
    static func trace(
        line: Int,
        storeAddressRegister: String?,
        storeWidth: Int,
        into builder: inout AssemblyBuilder
    ) {
        materialiseDecimalImmediate(UInt32(line), into: "w0", into: &builder)
        if let storeAddressRegister {
            builder.instruction("mov     w1, \(storeAddressRegister)")
            materialiseDecimalImmediate(UInt32(storeWidth), into: "w2", into: &builder)
        } else {
            builder.instruction("mov     w1, wzr")
            builder.instruction("mov     w2, wzr")
        }
        builder.instruction("bl      _armd_trace")
    }

    private static func materialiseDecimalImmediate(
        _ value: UInt32,
        into hostRegister: String,
        into builder: inout AssemblyBuilder
    ) {
        let low = value & 0xFFFF
        let high = value >> 16
        builder.instruction("movz    \(hostRegister), #\(low)")
        if high != 0 {
            builder.instruction("movk    \(hostRegister), #\(high), lsl #16")
        }
    }

    // MARK: - Program frame (Spec §7.9)

    static func prologue(entryLabel: String, into builder: inout AssemblyBuilder) {
        builder.directive(".section __TEXT,__text")
        builder.directive(".globl _main")
        builder.directive(".p2align 2")
        builder.label("_main")
        builder.instruction("stp     x29, x30, [sp, #-16]!")
        builder.instruction("stp     x27, x28, [sp, #-16]!")
        builder.instruction("bl      _armd_init")
        builder.instruction("mov     x28, x0")
        builder.instruction("adrp    x27, _armd_state@PAGE")
        builder.instruction("add     x27, x27, _armd_state@PAGEOFF")
        builder.instruction("b       \(entryLabel)")
        builder.blankLine()
    }

    static func epilogue(into builder: inout AssemblyBuilder) {
        builder.blankLine()
        builder.label("Larmd_exit")
        builder.instruction("bl      _armd_fini")
        builder.instruction("mov     w0, #0")
        builder.instruction("ldp     x27, x28, [sp], #16")
        builder.instruction("ldp     x29, x30, [sp], #16")
        builder.instruction("ret")
    }
}
