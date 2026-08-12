import Foundation

/// A run of bytes destined for a fixed ARM7 address. Spec §5.3.
struct ImageBlob: Sendable, Equatable {
    let address: UInt32
    let bytes: [UInt8]
}

struct AnalysedProgram: Sendable {
    let program: Program
    let symbols: SymbolTable
    let dataImage: [ImageBlob]
    let entryLineIndex: Int?
    /// Index into `program.lines` → the ARM7 address of that line's instruction.
    let addresses: [Int: UInt32]
}

/// Spec §5.2. Two passes: lay out and bind every label, then evaluate the data.
enum Analyser {
    /// Spec §5.2 `ARM7_ORIGIN`.
    static let origin: UInt32 = 0x0000_8000
    /// Spec §7.8 `ARM7_STACK_TOP`.
    static let stackTop: UInt32 = 0x0010_0000

    static func analyse(_ program: Program, into diagnostics: inout DiagnosticBag) -> AnalysedProgram {
        PerfLog.mark("analyse-start")
        var bag = diagnostics
        let result = PerfLog.measure("analyse") { () -> AnalysedProgram in
            var symbols = SymbolTable()
            var addresses: [Int: UInt32] = [:]
            /// Instructions collected during pass 1, checked once symbols are fully
            /// bound (after pass 1b) — see `check` below.
            var checkQueue: [(Instruction, UInt32)] = []
            /// Index into `program.lines` → the ARM7 address of that line's data.
            /// Recorded here in pass 1 so pass 2 never has to re-derive the layout,
            /// and so unlabelled data directives are addressable too.
            var dataAddresses: [Int: UInt32] = [:]
            var entryLineIndex: Int?
            var seenAreaNames: Set<String> = []
            var position = origin
            var inCodeArea = true

            // Population sites for `symbols`. `SymbolTable.lookup` resolves constants
            // before labels and cannot itself signal a name defined in both dictionaries
            // (see the doc comment on SymbolTable) — that obligation falls here, at every
            // site that writes into `.labels` or `.constants`. A name colliding with the
            // *other* dictionary, or a duplicate within the *same* dictionary, is E042;
            // the first definition wins and keeps its address/value, the second is
            // diagnosed and dropped.
            func bindLabel(_ name: String, at address: UInt32, range: SourceRange) {
                if symbols.constants[name] != nil {
                    bag.emit(Diagnostic(
                        severity: .error, code: "E042",
                        message: "'\(name)' is defined as both a label and an EQU constant",
                        range: range,
                        note: "rename one of them; the label's address is otherwise unreachable"
                    ))
                    return
                }
                if symbols.labels[name] != nil {
                    bag.emit(Diagnostic(
                        severity: .error, code: "E042",
                        message: "label '\(name)' is defined more than once",
                        range: range,
                        note: "rename one of the duplicate labels"
                    ))
                    return
                }
                symbols.labels[name] = address
            }

            func bindConstant(_ name: String, value: UInt32, range: SourceRange) {
                if symbols.labels[name] != nil {
                    bag.emit(Diagnostic(
                        severity: .error, code: "E042",
                        message: "'\(name)' is defined as both a label and an EQU constant",
                        range: range,
                        note: "rename one of them; the label's address is otherwise unreachable"
                    ))
                    return
                }
                if symbols.constants[name] != nil {
                    bag.emit(Diagnostic(
                        severity: .error, code: "E042",
                        message: "EQU symbol '\(name)' is defined more than once",
                        range: range,
                        note: "rename one of the duplicate EQU definitions"
                    ))
                    return
                }
                symbols.constants[name] = value
            }

            // Pass 0 — EQU pre-pass. SPACE's size and ALIGN's amount must be known
            // during pass 1 to keep laying out what follows, but `symbols.constants`
            // is otherwise only populated in pass 1b, after pass 1 finishes — so a
            // completely ordinary backward reference like `SIZE EQU 4` / `BUF SPACE
            // SIZE` would misreport SIZE as undefined. Give constants a chance to
            // resolve first: evaluate every EQU into a scratch bag that is discarded,
            // not the real one, because an EQU that references a label (which cannot
            // resolve yet — no layout has happened) is not an error at this point, it
            // is simply not resolvable *yet*. Pass 1b re-evaluates every EQU again
            // against the real bag once every label is bound, so anything depending
            // on a label still gets its correct value and, if genuinely undefined,
            // its real diagnostic there. This is a third linear pass, not a fixpoint:
            // it runs once, over EQUs only, and never re-visits anything.
            var scratch = DiagnosticBag(logging: false)
            for line in program.lines {
                if case .directive(.equ(let symbol, let value))? = line.statement {
                    if let resolved = ExpressionEvaluator.evaluate(value, symbols: symbols, here: 0, range: line.range, diagnostics: &scratch) {
                        symbols.constants[symbol] = resolved
                    }
                }
            }

            // Pass 1 — layout. Sizes are known without evaluating any expression:
            // an instruction is 4 bytes and a data directive's size is its element
            // count, so forward references resolve in pass 2 without a fixpoint.
            for (index, line) in program.lines.enumerated() {
                if case .directive(let directive)? = line.statement {
                    switch directive {
                    case .area(let name, let kind, _, let alignment):
                        if !seenAreaNames.insert(name).inserted {
                            bag.emit(Diagnostic(
                                severity: .warning, code: "W004",
                                message: "AREA '\(name)' is declared more than once",
                                range: line.range,
                                note: "canonical ARMASM requires distinct names; treated as separate areas"
                            ))
                        }
                        inCodeArea = (kind == .code)
                        position = align(position, to: UInt32(1) << UInt32(alignment))

                    case .entry:
                        if entryLineIndex != nil {
                            bag.emit(Diagnostic(
                                severity: .error, code: "E034",
                                message: "more than one ENTRY directive",
                                range: line.range, note: nil
                            ))
                        }
                        entryLineIndex = index

                    case .align(let amount):
                        let boundary = amount.flatMap {
                            ExpressionEvaluator.evaluate($0, symbols: symbols, here: position, range: line.range, diagnostics: &bag)
                        } ?? 4
                        position = align(position, to: max(1, boundary))

                    case .defineBytes(let values):
                        if let label = line.label { bindLabel(label, at: position, range: line.range) }
                        dataAddresses[index] = position
                        position &+= UInt32(values.count)
                        continue

                    case .defineHalfwords(let values):
                        position = align(position, to: 2)
                        if let label = line.label { bindLabel(label, at: position, range: line.range) }
                        dataAddresses[index] = position
                        position &+= UInt32(values.count * 2)
                        continue

                    case .defineWords(let values):
                        position = align(position, to: 4)
                        if let label = line.label { bindLabel(label, at: position, range: line.range) }
                        dataAddresses[index] = position
                        position &+= UInt32(values.count * 4)
                        continue

                    case .space(let size):
                        if let label = line.label { bindLabel(label, at: position, range: line.range) }
                        dataAddresses[index] = position
                        if let count = ExpressionEvaluator.evaluate(size, symbols: symbols, here: position, range: line.range, diagnostics: &bag) {
                            position &+= count
                        }
                        continue

                    case .equ:
                        // The "label" here (Line.label, same field every statement carries)
                        // names a compile-time constant, not a position. Bound in pass 1b
                        // instead — falling through to the generic label bind below would
                        // wrongly register it in `symbols.labels` at whatever `position`
                        // happens to be, and every ordinary EQU would then read back as a
                        // self-collision against the very check above.
                        continue

                    case .end, .ltorg, .export:
                        break
                    }
                }

                if let label = line.label {
                    bindLabel(label, at: position, range: line.range)
                }

                if case .instruction(let instruction)? = line.statement {
                    guard inCodeArea else {
                        bag.emit(Diagnostic(
                            severity: .error, code: "E035",
                            message: "instruction appears in a DATA area",
                            range: line.range, note: nil
                        ))
                        continue
                    }
                    addresses[index] = position
                    checkQueue.append((instruction, position))
                    position &+= 4
                }
            }

            if entryLineIndex == nil {
                bag.emit(Diagnostic(
                    severity: .error, code: "E033",
                    message: "no ENTRY directive",
                    range: program.lines.first?.range ?? SourceRange(line: 0, column: 0, length: 0),
                    note: "mark the entry point with ENTRY"
                ))
            }

            // Discard pass 0's provisional constants before pass 1b runs its own,
            // authoritative binding. Without this, every constant pass 0 already
            // resolved would appear to `bindConstant` as pre-existing, and pass 1b
            // would misreport every ordinary EQU as a duplicate of itself.
            symbols.constants = [:]

            // Pass 1b — EQU constants, now that every label is bound.
            for line in program.lines {
                if case .directive(.equ(let symbol, let value))? = line.statement {
                    // Spec §5.1: '.' is "the current position" — meaningful for a data
                    // directive laid out at a specific address (DCB/DCW/DCD/SPACE each
                    // record their own position in pass 1), but EQU has no position of
                    // its own: nothing tracks one for it, so every EQU is evaluated with
                    // `here: 0` below. `X EQU . + 4` would therefore silently resolve
                    // against a bogus address 0 rather than anything an implementer
                    // reading the source would expect. Reject it outright instead.
                    if expressionReferencesHere(value) {
                        bag.emit(Diagnostic(
                            severity: .error, code: "E043",
                            message: "'.' is not valid inside an EQU expression",
                            range: line.range,
                            note: "EQU has no position of its own; reference a label instead"
                        ))
                        continue
                    }
                    if let resolved = ExpressionEvaluator.evaluate(value, symbols: symbols, here: 0, range: line.range, diagnostics: &bag) {
                        bindConstant(symbol, value: resolved, range: line.range)
                    }
                }
            }

            // Semantic diagnostics — every symbol is bound now, so instructions queued
            // during pass 1 can be checked for real (Spec §6.2, §9 D1/D2/D8).
            for (instruction, address) in checkQueue {
                check(instruction, symbols: symbols, address: address, diagnostics: &bag)
            }

            // Pass 2 — evaluate data.
            var dataImage: [ImageBlob] = []
            for (index, line) in program.lines.enumerated() {
                guard case .directive(let directive)? = line.statement,
                      let address = dataAddresses[index]
                else { continue }

                switch directive {
                case .defineBytes(let values):
                    dataImage.append(ImageBlob(
                        address: address,
                        bytes: values.compactMap { expression in
                            ExpressionEvaluator.evaluate(expression, symbols: symbols, here: address, range: line.range, diagnostics: &bag)
                                .map { UInt8(truncatingIfNeeded: $0) }
                        }
                    ))
                case .defineHalfwords(let values):
                    var bytes: [UInt8] = []
                    for expression in values {
                        guard let value = ExpressionEvaluator.evaluate(expression, symbols: symbols, here: address, range: line.range, diagnostics: &bag) else { continue }
                        bytes.append(UInt8(truncatingIfNeeded: value))
                        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
                    }
                    dataImage.append(ImageBlob(address: address, bytes: bytes))
                case .defineWords(let values):
                    var bytes: [UInt8] = []
                    for expression in values {
                        guard let value = ExpressionEvaluator.evaluate(expression, symbols: symbols, here: address, range: line.range, diagnostics: &bag) else { continue }
                        for shift in stride(from: 0, through: 24, by: 8) {
                            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
                        }
                    }
                    dataImage.append(ImageBlob(address: address, bytes: bytes))
                case .space(let size):
                    if let count = ExpressionEvaluator.evaluate(size, symbols: symbols, here: address, range: line.range, diagnostics: &bag) {
                        dataImage.append(ImageBlob(address: address, bytes: Array(repeating: 0, count: Int(count))))
                    }
                default:
                    break
                }
            }

            PerfLog.info("laid out \(addresses.count) instructions, \(dataImage.count) data blobs")
            return AnalysedProgram(
                program: program, symbols: symbols, dataImage: dataImage,
                entryLineIndex: entryLineIndex, addresses: addresses
            )
        }
        diagnostics = bag
        return result
    }

    /// Spec §5.1: true when `.` (the current position) appears anywhere in the
    /// expression tree, including nested inside a unary/binary operator — used
    /// to reject '.' inside an EQU expression (EQU has no position of its own).
    private static func expressionReferencesHere(_ expression: Expression) -> Bool {
        switch expression {
        case .here: return true
        case .integer, .symbol: return false
        case .unary(_, let operand): return expressionReferencesHere(operand)
        case .binary(_, let left, let right):
            return expressionReferencesHere(left) || expressionReferencesHere(right)
        }
    }

    /// A boundary of 0 or 1 is a no-op (nothing is unaligned relative to it); guarding
    /// it here — rather than trusting every call site — is what keeps `ALIGN 0` from
    /// source safe, since `%` by zero traps.
    private static func align(_ value: UInt32, to boundary: UInt32) -> UInt32 {
        guard boundary > 1 else { return value }
        let remainder = value % boundary
        return remainder == 0 ? value : value &+ (boundary - remainder)
    }
}

extension Analyser {
    /// Spec §6.2 / [ARMARM]: an 8-bit value rotated right by an even amount.
    /// Enforced as a diagnostic even though the emitted AArch64 has no such
    /// restriction — the transpiler must not accept what real armasm rejects.
    ///
    /// `rotation` only ever ranges 0...30, so `32 - rotation` only ever ranges
    /// 2...32; the `% 32` folds the rotation-0 case's would-be `>> 32` down to
    /// `>> 0` before it happens, so this never shifts by the type's own bit width
    /// (which Swift's smart shift operators define as 0, not a trap, but the
    /// point is this function never relies on that). The loop is a bounded
    /// `stride`, not a manual counter, so it cannot spin.
    static func isEncodableModifiedImmediate(_ value: UInt32) -> Bool {
        for rotation in stride(from: 0, to: 32, by: 2) {
            let rotated = value << UInt32(rotation) | value >> UInt32((32 - rotation) % 32)
            if rotated & ~0xFF == 0 { return true }
        }
        return false
    }

    /// Spec §6.2, §9 D1, §9 D2, §9 D8.
    static func check(
        _ instruction: Instruction,
        symbols: SymbolTable,
        address: UInt32,
        diagnostics: inout DiagnosticBag
    ) {
        // Spec §7.5: `MOV PC, LR` is, alongside `BX LR`, the one sanctioned way to
        // write R15 — the backend lowers both as a function return. R15 there is
        // a destination, not a value being *read* as data, so D2's rule doesn't
        // apply to it. Every other data-processing/multiply mnemonic puts the
        // destination register at operands[0] too (Spec §6.3: "Rd, Rn, Operand2, or
        // Rd, Operand2 for MOV/MVN"), so dropping just this one exact pattern from
        // the loop below — rather than exempting operand[0] in general — keeps
        // `CMP R15, ...`, `ADD R15, R1, #4`, etc. flagged as before.
        // `MOVS PC, LR` is deliberately excluded from the carve-out: Spec §7.5 names
        // only the unsuffixed form as the lowered idiom. On real ARM7 the `S` also
        // restores CPSR from SPSR, and Spec §9 D6 models no banked registers/SPSR —
        // so `MOVS PC, LR` must fall through to E021 rather than being waved past as
        // a plain return that silently drops the restore.
        let isMovPCFromLR = instruction.mnemonic == .mov
            && !instruction.setsFlags
            && instruction.operands.count == 2
            && instruction.operands[0] == .register(15)
            && instruction.operands[1] == .operand2(.register(14))
        let operandsToCheck = isMovPCFromLR ? Array(instruction.operands.dropFirst()) : instruction.operands

        for operand in operandsToCheck {
            switch operand {
            case .register(15):
                diagnostics.emit(Diagnostic(
                    severity: .error, code: "E021",
                    message: "R15 cannot be used as a data operand",
                    range: instruction.range,
                    note: "Spec §9 D2: R15 holds a synthetic address for display only"
                ))

            case .operand2(.immediate(let expression)):
                var scratch = diagnostics
                if let value = ExpressionEvaluator.evaluate(
                    expression, symbols: symbols, here: address,
                    range: instruction.range, diagnostics: &scratch
                ), !isEncodableModifiedImmediate(value) {
                    diagnostics = scratch
                    diagnostics.emit(Diagnostic(
                        severity: .error, code: "E020",
                        message: "immediate #0x\(String(value, radix: 16, uppercase: true)) cannot be encoded",
                        range: instruction.range,
                        note: "ARM7 immediates are an 8-bit value rotated right by an even amount; use LDR Rd, =value"
                    ))
                } else {
                    diagnostics = scratch
                }

            case .operand2(.register(15)):
                diagnostics.emit(Diagnostic(
                    severity: .error, code: "E021",
                    message: "R15 cannot be used as a data operand",
                    range: instruction.range,
                    note: "Spec §9 D2: R15 holds a synthetic address for display only"
                ))

            case .operand2(.shifted(let register, let shift)):
                // D2 is a blanket rule on *reading* R15 as data — the shifted
                // operand's base register is read before the shift is applied, same
                // as the bare-register and immediate forms above. A register-
                // specified shift *count* (`Rm, LSL Rs`) is the same kind of read:
                // `shift.amountRegister` is consulted to compute the shift, so R15
                // there is read as data too, not just as the base.
                if register == 15 || shift.amountRegister == 15 {
                    diagnostics.emit(Diagnostic(
                        severity: .error, code: "E021",
                        message: "R15 cannot be used as a data operand",
                        range: instruction.range,
                        note: "Spec §9 D2: R15 holds a synthetic address for display only"
                    ))
                }
                // Spec §9 D1 names an exact set: MOVS, ANDS, ORRS, EORS, BICS, TST, TEQ
                // source C from the shifter. ADDS/SUBS/CMP/CMN are explicitly excluded
                // — their C/V come from the ALU's add/subtract and are unaffected, even
                // though `mnemonic.isComparison` (cmp/cmn/tst/teq) would otherwise lump
                // CMP/CMN in here too.
                let sourcesCarryFromShifter: Bool
                switch instruction.mnemonic {
                case .tst, .teq: sourcesCarryFromShifter = true
                case .mov, .mvn, .and, .orr, .eor, .bic: sourcesCarryFromShifter = instruction.setsFlags
                default: sourcesCarryFromShifter = false
                }
                if sourcesCarryFromShifter {
                    diagnostics.emit(Diagnostic(
                        severity: .warning, code: "W010",
                        message: "carry flag result of the barrel shifter is not modelled; C is unchanged",
                        range: instruction.range,
                        note: "Spec §9 D1. N and Z are correct."
                    ))
                }
                if let amount = shift.amount {
                    var scratch = diagnostics
                    let value = ExpressionEvaluator.evaluate(
                        amount, symbols: symbols, here: address,
                        range: instruction.range, diagnostics: &scratch
                    )
                    diagnostics = scratch
                    if let value, value >= 32 {
                        diagnostics.emit(Diagnostic(
                            severity: .warning, code: "W012",
                            message: "shift amount \(value) is 32 or greater",
                            range: instruction.range,
                            note: "Spec §9 D8: ARM7 saturates, A64 wraps at 32"
                        ))
                    }
                }

            case .registerList(let registers):
                // Spec §6.3: PUSH/STMFD *read* every register in the list (to store
                // its value) — the same kind of read D2 already forbids for every
                // other operand shape above, so R15 in a PUSH/STMFD list gets the
                // identical E021. POP/LDMFD is the opposite direction (R15 there is
                // *written*, the canonical subroutine-return idiom `POP {..., PC}`
                // that pairs with `PUSH {..., LR}`) — Lowering handles that as the
                // real function return (Spec §7.5), so it is deliberately not
                // diagnosed here.
                let isPush = instruction.mnemonic == .push || instruction.mnemonic == .stmfd
                if isPush, registers.contains(15) {
                    diagnostics.emit(Diagnostic(
                        severity: .error, code: "E021",
                        message: "R15 cannot be used as a data operand",
                        range: instruction.range,
                        note: "Spec §9 D2: R15 holds a synthetic address for display only; PUSH/STMFD read the register's value"
                    ))
                }

            default:
                break
            }
        }

        // Spec §7.5: `BX Rm` where `Rm` isn't LR is not lowered — only `BX LR` (a
        // function return) is supported. A single-operand instruction's sole
        // register always parses as the *trailing* Operand2 form
        // (`Parser.registerIsTrailingOperand2` returns true at end-of-line), so it
        // reaches here as `.operand2(.register(_))`, never bare `.register(_)`.
        if instruction.mnemonic == .bx,
           case .operand2(.register(let register))? = instruction.operands.first,
           register != 14 {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E014",
                message: "computed branch through R\(register) is not supported",
                range: instruction.range,
                note: "Spec §7.5: only BX LR is lowered"
            ))
        }
    }
}
