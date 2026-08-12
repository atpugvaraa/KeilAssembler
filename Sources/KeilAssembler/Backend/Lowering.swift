import Foundation

/// Spec §7.4–7.7.
enum Lowering {
    /// Spec §7.4. Operand2 is always materialised into w10, then the plain register
    /// form of the A64 instruction is emitted. Uniform, and it sidesteps every A64
    /// operand-encoding restriction.
    static func materialiseOperand2(
        _ operand2: Operand2,
        symbols: SymbolTable,
        address: UInt32,
        range: SourceRange,
        into builder: inout AssemblyBuilder,
        diagnostics: inout DiagnosticBag
    ) {
        switch operand2 {
        case .immediate(let expression):
            let value = ExpressionEvaluator.evaluate(
                expression, symbols: symbols, here: address,
                range: range, diagnostics: &diagnostics
            ) ?? 0
            Emitter.materialiseImmediate(value, into: "w10", into: &builder)

        case .register(let number):
            Emitter.loadRegister(number, into: "w10", into: &builder)

        case .shifted(let number, let shift):
            Emitter.loadRegister(number, into: "w10", into: &builder)

            if shift.kind == .rrx {
                diagnostics.emit(Diagnostic(
                    severity: .error, code: "E036",
                    message: "RRX is not lowered in this milestone",
                    range: range,
                    note: "Spec §7.4 leaves the RRX sequence undefined; see Spec §9 D1"
                ))
                return
            }

            if let amountRegister = shift.amountRegister {
                Emitter.loadRegister(amountRegister, into: "w11", into: &builder)
                builder.instruction("\(pad(shift.kind.variableMnemonic))w10, w10, w11")
                return
            }

            guard let amountExpression = shift.amount,
                  let amount = ExpressionEvaluator.evaluate(
                    amountExpression, symbols: symbols, here: address,
                    range: range, diagnostics: &diagnostics
                  ) else { return }
            builder.instruction("\(pad(shift.kind.rawValue))w10, w10, #\(amount)")
        }
    }

    /// Column-aligns a mnemonic so the emitted assembly stays readable.
    static func pad(_ mnemonic: String) -> String {
        mnemonic.padding(toLength: max(mnemonic.count, 8), withPad: " ", startingAt: 0)
    }
}

extension Lowering {
    static func lower(_ analysed: AnalysedProgram, into diagnostics: inout DiagnosticBag) -> String? {
        PerfLog.mark("lower-start")
        guard !diagnostics.hasErrors else {
            PerfLog.error("skipping lowering: \(diagnostics.diagnostics.filter { $0.severity == .error }.count) errors")
            return nil
        }

        var bag = diagnostics
        let text = PerfLog.measure("lower") { () -> String in
            var builder = AssemblyBuilder()
            let entryLabel = "Larmd_entry"
            Emitter.prologue(entryLabel: entryLabel, into: &builder)

            var skipCounter = 0
            var entryEmitted = false

            // Spec §7.5: every `BL` target opens a frame (`stp x29, x30, [sp, #-16]!`)
            // so the matching `BX LR` / `MOV PC, LR` at the end of the callee can pop
            // it with `ldp`/`ret`. Collected up front so the label-emission loop below
            // can check membership with no lookahead.
            let callTargets: Set<String> = Set(analysed.program.lines.compactMap { line in
                guard case .instruction(let instruction)? = line.statement,
                      instruction.mnemonic == .bl,
                      case .labelReference(let name)? = instruction.operands.first else { return nil }
                return name
            })

            for (index, line) in analysed.program.lines.enumerated() {
                if let label = line.label, analysed.symbols.labels[label] != nil {
                    builder.label(Emitter.armLabel(label))
                    if callTargets.contains(label) {
                        builder.instruction("stp     x29, x30, [sp, #-16]!")
                    }
                }

                guard case .instruction(let instruction)? = line.statement else { continue }

                if !entryEmitted, let entryIndex = analysed.entryLineIndex, index > entryIndex {
                    builder.label(entryLabel)
                    entryEmitted = true
                }

                let address = analysed.addresses[index] ?? Analyser.origin
                builder.comment("line \(instruction.range.line + 1): \(instruction.mnemonic.rawValue.uppercased())")

                var skipLabel: String?
                if let inverse = instruction.condition.inverseBranchSuffix {
                    Emitter.restoreFlags(into: &builder)
                    let label = "Lskip_\(skipCounter)"
                    skipCounter += 1
                    builder.instruction("\(pad("b." + inverse))\(label)")
                    skipLabel = label
                }

                emit(
                    instruction, address: address, sourceLine: instruction.range.line,
                    symbols: analysed.symbols, into: &builder, diagnostics: &bag
                )

                if let skipLabel { builder.label(skipLabel) }
            }

            if !entryEmitted { builder.label(entryLabel) }
            Emitter.epilogue(into: &builder)
            return builder.text
        }

        diagnostics = bag
        guard !diagnostics.hasErrors else { return nil }
        PerfLog.info("lowered \(analysed.addresses.count) instructions")
        return text
    }

    /// Spec §7.5.
    static func emit(
        _ instruction: Instruction,
        address: UInt32,
        sourceLine: Int,
        symbols: SymbolTable,
        into builder: inout AssemblyBuilder,
        diagnostics: inout DiagnosticBag
    ) {
        let range = instruction.range

        switch instruction.mnemonic {
        case .nop:
            builder.instruction("nop")

        case .mov, .mvn:
            guard case .register(let destination)? = instruction.operands.first,
                  let source = instruction.operands.dropFirst().first else {
                unsupported(instruction, into: &diagnostics); return
            }
            // Spec §7.5 names `MOV PC, LR` alongside `BX LR` as the sanctioned
            // function-return idiom, lowered identically: pop the frame pushed by
            // the callee's prologue (call-target handling in `lower` above), then
            // `ret`. Falling through to the ordinary MOV path below would silently
            // store LR's value into R15's *display slot* instead of returning —
            // valid-looking assembly, wrong control flow, and no diagnostic.
            if instruction.mnemonic == .mov, !instruction.setsFlags,
               destination == 15, source == .operand2(.register(14)) {
                Emitter.trace(line: sourceLine, storeAddressRegister: nil, storeWidth: 0, into: &builder)
                builder.instruction("ldp     x29, x30, [sp], #16")
                builder.instruction("ret")
                return
            }
            materialise(source, symbols: symbols, address: address, range: range, into: &builder, diagnostics: &diagnostics)
            if instruction.mnemonic == .mvn {
                builder.instruction("mvn     w11, w10")
                if instruction.setsFlags { builder.instruction("ands    w11, w11, w11") }
            } else if instruction.setsFlags {
                builder.instruction("ands    w11, w10, w10")
            } else {
                builder.instruction("mov     w11, w10")
            }
            Emitter.storeRegister(destination, from: "w11", into: &builder)
            if instruction.setsFlags { Emitter.saveFlags(into: &builder) }

        case .add, .adc, .sub, .sbc, .rsb, .rsc, .and, .orr, .eor, .bic:
            guard case .register(let destination)? = instruction.operands.first,
                  case .register(let first)? = instruction.operands.dropFirst().first,
                  let second = instruction.operands.dropFirst(2).first else {
                unsupported(instruction, into: &diagnostics); return
            }
            Emitter.loadRegister(first, into: "w9", into: &builder)
            materialise(second, symbols: symbols, address: address, range: range, into: &builder, diagnostics: &diagnostics)
            if carryConsuming.contains(instruction.mnemonic) { Emitter.restoreFlags(into: &builder) }
            builder.instruction(arithmetic(instruction))
            if needsExplicitFlagSet(instruction) { builder.instruction("ands    w11, w11, w11") }
            Emitter.storeRegister(destination, from: "w11", into: &builder)
            if instruction.setsFlags { Emitter.saveFlags(into: &builder) }

        case .cmp, .cmn, .tst, .teq:
            guard case .register(let first)? = instruction.operands.first,
                  let second = instruction.operands.dropFirst().first else {
                unsupported(instruction, into: &diagnostics); return
            }
            Emitter.loadRegister(first, into: "w9", into: &builder)
            materialise(second, symbols: symbols, address: address, range: range, into: &builder, diagnostics: &diagnostics)
            switch instruction.mnemonic {
            case .cmp: builder.instruction("subs    wzr, w9, w10")
            case .cmn: builder.instruction("adds    wzr, w9, w10")
            case .tst: builder.instruction("ands    wzr, w9, w10")
            default:
                builder.instruction("eor     w11, w9, w10")
                builder.instruction("ands    wzr, w11, w11")
            }
            Emitter.saveFlags(into: &builder)

        case .mul, .mla:
            // Rm/Rs/Rn here are read as data, never a destination, so each one may
            // parse as either a bare `.register` (an interior operand, still
            // followed by a comma) or `.operand2(.register(_))` (the trailing
            // operand — `Parser.registerIsTrailingOperand2` wraps whichever
            // register ends the operand list, which for `MUL Rd, Rm, Rs` is `Rs`,
            // and for `MLA Rd, Rm, Rs, Rn` is `Rn`). Matching only the bare form
            // here made every plain `MUL` fail with E013, and made `MLA` silently
            // drop its accumulator and degrade to a plain multiply — `registerOperand`
            // accepts both spellings so neither the whole-instruction rejection
            // nor the silent wrong answer can happen.
            guard let destination = registerOperand(instruction.operands.first),
                  let multiplicand = registerOperand(instruction.operands.dropFirst().first),
                  let multiplier = registerOperand(instruction.operands.dropFirst(2).first) else {
                unsupported(instruction, into: &diagnostics); return
            }
            Emitter.loadRegister(multiplicand, into: "w9", into: &builder)
            Emitter.loadRegister(multiplier, into: "w10", into: &builder)
            if instruction.mnemonic == .mla {
                guard let addend = registerOperand(instruction.operands.dropFirst(3).first) else {
                    unsupported(instruction, into: &diagnostics); return
                }
                Emitter.loadRegister(addend, into: "w12", into: &builder)
                builder.instruction("madd    w11, w9, w10, w12")
            } else {
                builder.instruction("mul     w11, w9, w10")
            }
            Emitter.storeRegister(destination, from: "w11", into: &builder)
            if instruction.setsFlags {
                builder.instruction("ands    w11, w11, w11")
                Emitter.saveFlags(into: &builder)
            }

        case .ldr, .str, .ldrb, .strb, .ldrh, .strh:
            guard case .register(let dataRegister)? = instruction.operands.first,
                  let source = instruction.operands.dropFirst().first else {
                unsupported(instruction, into: &diagnostics); return
            }

            // `LDR Rd, =expr` — Spec §7.6, no memory access at all.
            if case .immediateValue(let expression) = source {
                let value = ExpressionEvaluator.evaluate(
                    expression, symbols: symbols, here: address, range: range, diagnostics: &diagnostics
                ) ?? 0
                Emitter.materialiseImmediate(value, into: "w11", into: &builder)
                Emitter.storeRegister(dataRegister, from: "w11", into: &builder)
                Emitter.trace(line: sourceLine, storeAddressRegister: nil, storeWidth: 0, into: &builder)
                return
            }

            guard case .address(let mode) = source else {
                unsupported(instruction, into: &diagnostics); return
            }

            let width = accessWidth(instruction.mnemonic)
            let isStore = [Mnemonic.str, .strb, .strh].contains(instruction.mnemonic)
            /// Set only by post-indexed addressing; the base register whose updated
            /// value sits in w12 and must be written back after the access.
            var postIndexBase: Int?

            // Effective ARM7 address into w9.
            switch mode {
            case .label(let name):
                guard let labelAddress = symbols.labels[name] else {
                    diagnostics.emit(Diagnostic(
                        severity: .error, code: "E031",
                        message: "'\(name)' is not defined",
                        range: range, note: nil
                    ))
                    return
                }
                Emitter.materialiseImmediate(labelAddress, into: "w9", into: &builder)

            case .immediateOffset(let base, let offset, let negated, let writeBack):
                Emitter.loadRegister(base, into: "w9", into: &builder)
                if let offset {
                    let value = ExpressionEvaluator.evaluate(
                        offset, symbols: symbols, here: address, range: range, diagnostics: &diagnostics
                    ) ?? 0
                    Emitter.materialiseImmediate(value, into: "w12", into: &builder)
                    builder.instruction("\(pad(negated ? "sub" : "add"))w9, w9, w12")
                }
                if writeBack { Emitter.storeRegister(base, from: "w9", into: &builder) }

            case .registerOffset(let base, let offsetRegister, let negated, let shift, let writeBack):
                Emitter.loadRegister(base, into: "w9", into: &builder)
                Emitter.loadRegister(offsetRegister, into: "w12", into: &builder)
                if let shift, let amountExpression = shift.amount, shift.kind != .rrx {
                    let amount = ExpressionEvaluator.evaluate(
                        amountExpression, symbols: symbols, here: address, range: range, diagnostics: &diagnostics
                    ) ?? 0
                    builder.instruction("\(pad(shift.kind.rawValue))w12, w12, #\(amount)")
                }
                builder.instruction("\(pad(negated ? "sub" : "add"))w9, w9, w12")
                if writeBack { Emitter.storeRegister(base, from: "w9", into: &builder) }

            case .postIndexed(let base, let offset, let negated):
                Emitter.loadRegister(base, into: "w9", into: &builder)
                let value = ExpressionEvaluator.evaluate(
                    offset, symbols: symbols, here: address, range: range, diagnostics: &diagnostics
                ) ?? 0
                // The access uses the original base, still in w9. w12 carries the
                // updated base and is written back only after the shared access
                // below — post-indexing must not emit an access of its own.
                Emitter.materialiseImmediate(value, into: "w12", into: &builder)
                builder.instruction("\(pad(negated ? "sub" : "add"))w12, w9, w12")
                postIndexBase = base
            }

            if isStore {
                Emitter.loadRegister(dataRegister, into: "w11", into: &builder)
                builder.instruction("\(pad("str" + widthSuffix(width)))w11, [x28, w9, uxtw]")
                if let postIndexBase { Emitter.storeRegister(postIndexBase, from: "w12", into: &builder) }
                Emitter.trace(line: sourceLine, storeAddressRegister: "w9", storeWidth: width, into: &builder)
            } else {
                builder.instruction("\(pad("ldr" + widthSuffix(width)))w11, [x28, w9, uxtw]")
                Emitter.storeRegister(dataRegister, from: "w11", into: &builder)
                if let postIndexBase { Emitter.storeRegister(postIndexBase, from: "w12", into: &builder) }
                Emitter.trace(line: sourceLine, storeAddressRegister: nil, storeWidth: 0, into: &builder)
            }
            return

        case .push, .stmfd, .pop, .ldmfd:
            guard case .registerList(let registers)? = instruction.operands.last, !registers.isEmpty else {
                unsupported(instruction, into: &diagnostics); return
            }
            let isPush = instruction.mnemonic == .push || instruction.mnemonic == .stmfd
            Emitter.loadRegister(13, into: "w9", into: &builder)

            if isPush {
                // Full-descending: SP drops by 4 per register, then registers are
                // stored lowest-register-at-lowest-address (Spec §6.3). Slot 0 sits
                // at the updated base itself, so it accesses through w9 directly —
                // every other slot needs its offset added into w12 first.
                builder.instruction("sub     w9, w9, #\(registers.count * 4)")
                Emitter.storeRegister(13, from: "w9", into: &builder)
                for (slot, register) in registers.enumerated() {
                    Emitter.loadRegister(register, into: "w11", into: &builder)
                    if slot == 0 {
                        builder.instruction("str     w11, [x28, w9, uxtw]")
                    } else {
                        builder.instruction("add     w12, w9, #\(slot * 4)")
                        builder.instruction("str     w11, [x28, w12, uxtw]")
                    }
                }
                Emitter.trace(line: sourceLine, storeAddressRegister: "w9", storeWidth: 4, into: &builder)
            } else {
                for (slot, register) in registers.enumerated() {
                    if slot == 0 {
                        builder.instruction("ldr     w11, [x28, w9, uxtw]")
                    } else {
                        builder.instruction("add     w12, w9, #\(slot * 4)")
                        builder.instruction("ldr     w11, [x28, w12, uxtw]")
                    }
                    Emitter.storeRegister(register, from: "w11", into: &builder)
                }
                builder.instruction("add     w9, w9, #\(registers.count * 4)")
                Emitter.storeRegister(13, from: "w9", into: &builder)
                Emitter.trace(line: sourceLine, storeAddressRegister: nil, storeWidth: 0, into: &builder)
            }
            return

        case .adr:
            guard case .register(let destination)? = instruction.operands.first,
                  case .labelReference(let name)? = instruction.operands.dropFirst().first,
                  let labelAddress = symbols.labels[name] else {
                unsupported(instruction, into: &diagnostics); return
            }
            Emitter.materialiseImmediate(labelAddress, into: "w11", into: &builder)
            Emitter.storeRegister(destination, from: "w11", into: &builder)

        case .b, .bl:
            guard case .labelReference(let name)? = instruction.operands.first else {
                unsupported(instruction, into: &diagnostics); return
            }
            if instruction.mnemonic == .bl {
                // Spec §7.5: R14 carries the ARM7 address of the next instruction,
                // for display; the native `bl` provides the real return address.
                Emitter.materialiseImmediate(address &+ 4, into: "w11", into: &builder)
                Emitter.storeRegister(14, from: "w11", into: &builder)
            }
            Emitter.trace(line: sourceLine, storeAddressRegister: nil, storeWidth: 0, into: &builder)
            builder.instruction("\(pad(instruction.mnemonic == .bl ? "bl" : "b"))\(Emitter.armLabel(name))")
            return

        case .bx:
            Emitter.trace(line: sourceLine, storeAddressRegister: nil, storeWidth: 0, into: &builder)
            builder.instruction("ldp     x29, x30, [sp], #16")
            builder.instruction("ret")
            return
        }

        Emitter.trace(line: sourceLine, storeAddressRegister: nil, storeWidth: 0, into: &builder)
    }

    // MARK: - Helpers

    /// Spec §7.5: these read C from the CPSR before operating.
    static let carryConsuming: Set<Mnemonic> = [.adc, .sbc, .rsc]

    /// Spec §7.5: ORR/EOR have no flag-setting A64 form, so S is realised by a
    /// following `ands`, which sets N and Z and leaves C and V — matching ARM7.
    static func needsExplicitFlagSet(_ instruction: Instruction) -> Bool {
        instruction.setsFlags && (instruction.mnemonic == .orr || instruction.mnemonic == .eor)
    }

    static func arithmetic(_ instruction: Instruction) -> String {
        let setsFlags = instruction.setsFlags && !needsExplicitFlagSet(instruction)
        let suffix = setsFlags ? "s" : ""
        switch instruction.mnemonic {
        case .add: return "\(pad("add" + suffix))w11, w9, w10"
        case .adc: return "\(pad("adc" + suffix))w11, w9, w10"
        case .sub: return "\(pad("sub" + suffix))w11, w9, w10"
        case .sbc: return "\(pad("sbc" + suffix))w11, w9, w10"
        case .rsb: return "\(pad("sub" + suffix))w11, w10, w9"
        case .rsc: return "\(pad("sbc" + suffix))w11, w10, w9"
        case .and: return "\(pad("and" + suffix))w11, w9, w10"
        case .bic: return "\(pad("bic" + suffix))w11, w9, w10"
        case .orr: return "\(pad("orr"))w11, w9, w10"
        case .eor: return "\(pad("eor"))w11, w9, w10"
        default:   return "nop"
        }
    }

    /// Spec §7.5/§7.6: LDRB/STRB access one byte, LDRH/STRH access one halfword,
    /// everything else (including the literal-load LDR form) a full word.
    static func accessWidth(_ mnemonic: Mnemonic) -> Int {
        switch mnemonic {
        case .ldrb, .strb: 1
        case .ldrh, .strh: 2
        default: 4
        }
    }

    /// The A64 mnemonic suffix that narrows `ldr`/`str` to the access width above.
    static func widthSuffix(_ width: Int) -> String {
        switch width {
        case 1: "b"
        case 2: "h"
        default: ""
        }
    }

    /// Accepts either spelling the parser produces for a trailing operand:
    /// a bare `.register` or an `.operand2`.
    static func materialise(
        _ operand: Operand,
        symbols: SymbolTable,
        address: UInt32,
        range: SourceRange,
        into builder: inout AssemblyBuilder,
        diagnostics: inout DiagnosticBag
    ) {
        switch operand {
        case .register(let number):
            Emitter.loadRegister(number, into: "w10", into: &builder)
        case .operand2(let operand2):
            materialiseOperand2(operand2, symbols: symbols, address: address, range: range, into: &builder, diagnostics: &diagnostics)
        default:
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E037",
                message: "operand is not valid here",
                range: range, note: nil
            ))
        }
    }

    /// A plain register number regardless of which spelling the parser produced
    /// for it — `.register(n)` for an interior operand, `.operand2(.register(n))`
    /// for whichever operand ends the list (Spec §6.2's Operand2 also permits a
    /// bare `Rm`, so the parser always folds a line-final register into it).
    static func registerOperand(_ operand: Operand?) -> Int? {
        switch operand {
        case .register(let number)?: number
        case .operand2(.register(let number))?: number
        default: nil
        }
    }

    static func unsupported(_ instruction: Instruction, into diagnostics: inout DiagnosticBag) {
        diagnostics.emit(Diagnostic(
            severity: .error, code: "E013",
            message: "\(instruction.mnemonic.rawValue.uppercased()) with these operands is not supported in this subset",
            range: instruction.range,
            note: "see Spec §6.3"
        ))
    }
}
