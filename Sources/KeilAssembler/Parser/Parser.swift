import Foundation

/// Spec §4.1, §5, §6. Preserves what the source says; normalisation happens in the Analyser.
struct Parser {
    private let tokens: [Token]
    private var index = 0

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    // MARK: - Cursor

    private var current: Token { tokens[index] }

    private func peek(_ offset: Int = 0) -> Token.Kind {
        let target = index + offset
        return target < tokens.count ? tokens[target].kind : .endOfFile
    }

    @discardableResult
    private mutating func advance() -> Token {
        let token = tokens[index]
        if index < tokens.count - 1 { index += 1 }
        return token
    }

    private mutating func match(_ kind: Token.Kind) -> Bool {
        guard peek() == kind else { return false }
        advance()
        return true
    }

    private mutating func skipToEndOfLine() {
        while peek() != .endOfLine, peek() != .endOfFile { advance() }
    }

    // MARK: - Entry point

    mutating func parse(into diagnostics: inout DiagnosticBag) -> Program {
        PerfLog.mark("parse-start")
        var bag = diagnostics
        var lines: [Line] = []

        PerfLog.measure("parse") {
            while peek() != .endOfFile {
                if match(.endOfLine) { continue }   // blank or comment-only line
                if let line = parseLine(into: &bag) { lines.append(line) }
                if peek() != .endOfFile { _ = match(.endOfLine) }
            }
        }

        diagnostics = bag
        PerfLog.info("parsed \(lines.count) statements")
        return Program(lines: lines)
    }

    private mutating func parseLine(into diagnostics: inout DiagnosticBag) -> Line? {
        let startRange = current.range
        var label: String?

        // Spec §4.1: a label begins in column 1. Spec §11 Q2: the lab source puts
        // mnemonics there too, so a column-1 word that names a mnemonic or a directive
        // is treated as a statement, with W001.
        if case .symbol(let text) = peek(), current.range.column == 0 {
            if Mnemonic(parsingSuffixesOf: text) != nil || Self.directiveNames.contains(text.uppercased()) {
                diagnostics.emit(Diagnostic(
                    severity: .warning,
                    code: "W001",
                    message: "'\(text)' is in the label column but names an instruction or directive",
                    range: current.range,
                    note: "indent the statement so column 1 stays free for labels"
                ))
            } else {
                label = text
                advance()
            }
        }

        if peek() == .endOfLine || peek() == .endOfFile {
            guard label != nil else { return nil }
            return Line(label: label, statement: nil, range: startRange)
        }

        let statement = parseStatement(label: label, into: &diagnostics)
        return Line(label: label, statement: statement, range: startRange)
    }

    /// Filled in by Tasks 6–8. Returns nil and consumes the line when nothing parses.
    /// `label` is the column-1 symbol `parseLine` already consumed, if any — `EQU` needs it
    /// (`SIZE EQU 4`: the symbol being defined is the label, not part of the directive body).
    private mutating func parseStatement(label: String?, into diagnostics: inout DiagnosticBag) -> Statement? {
        guard case .symbol(let text) = peek() else {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E006",
                message: "expected an instruction or directive",
                range: current.range, note: nil
            ))
            skipToEndOfLine()
            return nil
        }

        if Self.directiveNames.contains(text.uppercased()) {
            return parseDirective(label: label, into: &diagnostics)
        }
        if Mnemonic(parsingSuffixesOf: text) != nil {
            return parseInstruction(into: &diagnostics)
        }

        diagnostics.emit(Diagnostic(
            severity: .error, code: "E013",
            message: "instruction '\(text)' is not supported in this subset",
            range: current.range,
            note: "see Spec §6.3 for the supported instruction set"
        ))
        skipToEndOfLine()
        return nil
    }

    static let directiveNames: Set<String> = [
        "AREA", "ENTRY", "END", "EQU", "ALIGN",
        "DCB", "DCW", "DCD", "SPACE", "LTORG", "EXPORT", "GLOBAL",
    ]

    // MARK: - Directives (Spec §5)

    private mutating func parseDirective(label: String?, into diagnostics: inout DiagnosticBag) -> Statement? {
        guard case .symbol(let text) = peek() else { return nil }
        let range = current.range
        advance()

        switch text.uppercased() {
        case "ENTRY":  return .directive(.entry)
        case "END":    return .directive(.end)
        case "LTORG":  return .directive(.ltorg)

        case "EQU":
            guard let symbol = label else {
                diagnostics.emit(Diagnostic(
                    severity: .error, code: "E017",
                    message: "EQU requires a preceding label",
                    range: range, note: "write `SYM EQU expr`"
                ))
                skipToEndOfLine()
                return nil
            }
            guard let value = parseExpression(into: &diagnostics) else { return nil }
            return .directive(.equ(symbol: symbol, value: value))

        case "EXPORT", "GLOBAL":
            guard case .symbol(let name) = peek() else {
                diagnostics.emit(Diagnostic(
                    severity: .error, code: "E007",
                    message: "EXPORT expects a symbol name",
                    range: current.range, note: nil
                ))
                skipToEndOfLine()
                return nil
            }
            advance()
            return .directive(.export(name))

        case "AREA":
            return parseArea(range: range, into: &diagnostics)

        case "ALIGN":
            if peek() == .endOfLine || peek() == .endOfFile { return .directive(.align(nil)) }
            return .directive(.align(parseExpression(into: &diagnostics)))

        case "SPACE":
            guard let size = parseExpression(into: &diagnostics) else { return nil }
            return .directive(.space(size))

        case "DCB":
            return .directive(.defineBytes(parseDataList(range: range, into: &diagnostics)))
        case "DCW":
            return .directive(.defineHalfwords(parseDataList(range: range, into: &diagnostics)))
        case "DCD":
            return .directive(.defineWords(parseDataList(range: range, into: &diagnostics)))

        default:
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E010",
                message: "directive '\(text)' is not supported in this subset",
                range: range, note: "see Spec §5 for the supported directives"
            ))
            skipToEndOfLine()
            return nil
        }
    }

    private mutating func parseArea(
        range: SourceRange,
        into diagnostics: inout DiagnosticBag
    ) -> Statement? {
        guard case .symbol(let name) = peek() else {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E008",
                message: "AREA expects a section name",
                range: current.range, note: nil
            ))
            skipToEndOfLine()
            return nil
        }
        advance()

        var kind = AreaKind.code
        var readOnly = true
        var alignment = 2                   // AREA alignment is a power of two; 2 => 4 bytes

        while match(.comma) {
            guard case .symbol(let attribute) = peek() else { break }
            let attributeRange = current.range
            advance()
            switch attribute.uppercased() {
            case "CODE":      kind = .code
            case "DATA":      kind = .data
            case "READONLY":  readOnly = true
            case "READWRITE": readOnly = false
            case "ALIGN":
                if match(.equals) {
                    if case .integer(let value) = peek() {
                        advance()
                        alignment = Int(value)
                    } else {
                        // Without this, `match(.equals)` has already consumed '=',
                        // but the non-integer value is left completely unconsumed:
                        // the attribute loop only re-enters on a comma, so it exits
                        // here, and the top-level parse loop re-dispatches the
                        // stray token (e.g. `FOO` in `ALIGN=FOO`) as a bogus second
                        // statement — "E013: instruction 'FOO' is not supported",
                        // naming the wrong problem entirely.
                        diagnostics.emit(Diagnostic(
                            severity: .warning, code: "W003",
                            message: "AREA attribute 'ALIGN' has a malformed value and is ignored",
                            range: current.range,
                            note: "write ALIGN=n, where n is an integer"
                        ))
                        if peek() != .endOfLine, peek() != .endOfFile { advance() }
                    }
                }
            default:
                diagnostics.emit(Diagnostic(
                    severity: .warning, code: "W003",
                    message: "AREA attribute '\(attribute)' is ignored",
                    range: attributeRange, note: nil
                ))
            }
        }

        return .directive(.area(name: name, kind: kind, readOnly: readOnly, alignment: alignment))
    }

    /// Spec §11 Q1: the lab source writes `VALUE1 DCD, &00000012`. The leading comma is
    /// not canonical ARMASM, so it is consumed with W002 rather than rejected.
    private mutating func parseDataList(
        range: SourceRange,
        into diagnostics: inout DiagnosticBag
    ) -> [Expression] {
        if peek() == .comma {
            diagnostics.emit(Diagnostic(
                severity: .warning, code: "W002",
                message: "unexpected ',' directly after the data directive",
                range: current.range,
                note: "write `DCD value`, not `DCD, value`"
            ))
            advance()
        }

        var values: [Expression] = []
        repeat {
            if case .string(let text) = peek() {
                advance()
                values.append(contentsOf: text.unicodeScalars.map { .integer(UInt32($0.value)) })
                continue
            }
            guard let expression = parseExpression(into: &diagnostics) else { break }
            values.append(expression)
        } while match(.comma)

        // The loop above only re-enters on a comma. If it stopped for any other reason
        // while there is still more on the line, a value was silently dropped (e.g.
        // `DCD 1 2` parses `1`, sees `2` isn't a comma, and would otherwise exit clean).
        // Diagnose it and consume the rest of the line so the orphan isn't re-dispatched
        // as a bogus top-level statement.
        if peek() != .endOfLine, peek() != .endOfFile {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E039",
                message: "expected ',' between data-list values",
                range: current.range,
                note: "separate values with ','"
            ))
            skipToEndOfLine()
        }

        if values.isEmpty {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E009",
                message: "data directive needs at least one value",
                range: range, note: nil
            ))
        }
        return values
    }

    // MARK: - Expressions (Spec §5.1)

    mutating func parseExpression(into diagnostics: inout DiagnosticBag) -> Expression? {
        parseLogical(into: &diagnostics)
    }

    private mutating func parseLogical(into diagnostics: inout DiagnosticBag) -> Expression? {
        guard var left = parseShift(into: &diagnostics) else { return nil }
        while case .operatorWord(let word) = peek(),
              let op = Self.logicalOperators[word] {
            advance()
            guard let right = parseShift(into: &diagnostics) else { return nil }
            left = .binary(op, left, right)
        }
        return left
    }

    private mutating func parseShift(into diagnostics: inout DiagnosticBag) -> Expression? {
        guard var left = parseAdditive(into: &diagnostics) else { return nil }
        while case .operatorWord(let word) = peek(),
              let op = Self.shiftOperators[word] {
            advance()
            guard let right = parseAdditive(into: &diagnostics) else { return nil }
            left = .binary(op, left, right)
        }
        return left
    }

    private mutating func parseAdditive(into diagnostics: inout DiagnosticBag) -> Expression? {
        guard var left = parseMultiplicative(into: &diagnostics) else { return nil }
        while true {
            if match(.plus) {
                guard let right = parseMultiplicative(into: &diagnostics) else { return nil }
                left = .binary(.add, left, right)
            } else if match(.minus) {
                guard let right = parseMultiplicative(into: &diagnostics) else { return nil }
                left = .binary(.subtract, left, right)
            } else {
                return left
            }
        }
    }

    private mutating func parseMultiplicative(into diagnostics: inout DiagnosticBag) -> Expression? {
        guard var left = parseUnary(into: &diagnostics) else { return nil }
        while true {
            if match(.star) {
                guard let right = parseUnary(into: &diagnostics) else { return nil }
                left = .binary(.multiply, left, right)
            } else if match(.slash) {
                guard let right = parseUnary(into: &diagnostics) else { return nil }
                left = .binary(.divide, left, right)
            } else if case .operatorWord("MOD") = peek() {
                advance()
                guard let right = parseUnary(into: &diagnostics) else { return nil }
                left = .binary(.modulo, left, right)
            } else {
                return left
            }
        }
    }

    private mutating func parseUnary(into diagnostics: inout DiagnosticBag) -> Expression? {
        if match(.minus) {
            guard let operand = parseUnary(into: &diagnostics) else { return nil }
            return .unary(.minus, operand)
        }
        if match(.plus) { return parseUnary(into: &diagnostics) }
        if match(.caret) {
            guard let operand = parseUnary(into: &diagnostics) else { return nil }
            return .unary(.not, operand)
        }
        return parsePrimary(into: &diagnostics)
    }

    private mutating func parsePrimary(into diagnostics: inout DiagnosticBag) -> Expression? {
        switch peek() {
        case .integer(let value):
            advance()
            return .integer(value)
        case .symbol(let name):
            advance()
            return .symbol(name)
        case .dot:
            advance()
            return .here
        case .leftParen:
            advance()
            guard let inner = parseExpression(into: &diagnostics) else { return nil }
            if !match(.rightParen) {
                diagnostics.emit(Diagnostic(
                    severity: .error, code: "E015",
                    message: "expected ')'",
                    range: current.range, note: nil
                ))
                return nil
            }
            return inner
        default:
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E016",
                message: "expected a value",
                range: current.range, note: nil
            ))
            skipToEndOfLine()
            return nil
        }
    }

    private static let logicalOperators: [String: BinaryOperator] = [
        "AND": .and, "OR": .or, "EOR": .exclusiveOr,
    ]
    private static let shiftOperators: [String: BinaryOperator] = [
        "SHL": .shiftLeft, "SHR": .shiftRight,
    ]

    // MARK: - Instructions (Spec §6)

    private mutating func parseInstruction(into diagnostics: inout DiagnosticBag) -> Statement? {
        guard case .symbol(let text) = peek(),
              let parts = Mnemonic.decompose(text) else { return nil }
        let range = current.range
        advance()

        var operands: [Operand] = []
        if peek() != .endOfLine, peek() != .endOfFile {
            repeat {
                guard let operand = parseOperand(for: parts.mnemonic, into: &diagnostics) else {
                    skipToEndOfLine()
                    break
                }
                operands.append(operand)
            } while match(.comma)
        }

        // The loop above only re-enters on a comma. If it stopped for any other reason while
        // there is still more on the line, an operand was silently dropped (e.g. `MOV R1 R2`
        // parses `R1`, sees `R2` isn't a comma, and would otherwise exit clean). Diagnose it
        // and consume the rest of the line so the orphan isn't re-dispatched as a bogus
        // top-level statement.
        if peek() != .endOfLine, peek() != .endOfFile {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E040",
                message: "expected ',' or end of line after operand",
                range: current.range, note: nil
            ))
            skipToEndOfLine()
        }

        return .instruction(Instruction(
            mnemonic: parts.mnemonic,
            condition: parts.condition,
            setsFlags: parts.setsFlags,
            operands: operands,
            range: range
        ))
    }

    private mutating func parseOperand(
        for mnemonic: Mnemonic,
        into diagnostics: inout DiagnosticBag
    ) -> Operand? {
        // `LDR Rd, =expr` — Spec §7.6 pseudo-instruction.
        if match(.equals) {
            guard let value = parseExpression(into: &diagnostics) else { return nil }
            return .immediateValue(value)
        }

        // `[Rn, ...]` and `[Rn], #off` — Task 8.
        if peek() == .leftBracket {
            guard let mode = parseAddressMode(into: &diagnostics) else { return nil }
            return .address(mode)
        }

        // `{r1, r4}` register list — Task 8.
        if peek() == .leftBrace {
            guard let list = parseRegisterList(into: &diagnostics) else { return nil }
            return .registerList(list)
        }

        // A bare register is either a destination/source register (more operands follow) or
        // Operand2 itself — the trailing operand, which may carry a `, <shift> ...` clause
        // (Spec §6.2). `registerIsTrailingOperand2` tells those apart; `parseOperand2` reads
        // whichever of immediate/register/shifted-register it turns out to be.
        if case .register(let number) = peek() {
            if registerIsTrailingOperand2() {
                guard let operand2 = parseOperand2(into: &diagnostics) else { return nil }
                return .operand2(operand2)
            }
            let registerRange = current.range
            advance()
            // `Rn!` outside `[...]` is only meaningful for `STMFD`/`LDMFD`'s base
            // register — e.g. `STMFD SP!, {R1, R4}` (Spec §6.3), the only
            // spec-legal spelling of the writeback form; Lowering hardcodes R13 as
            // SP regardless of what's written here, so the register is
            // informational but the `!` still has to parse. Scoped to exactly
            // those two mnemonics: consuming it unconditionally would silently
            // swallow a stray `!` after *any* mnemonic's non-trailing bare
            // register (e.g. `ADD R1!, R2, R3`), discarding the E040 that
            // `parseInstruction`'s post-loop check exists to catch.
            if mnemonic == .stmfd || mnemonic == .ldmfd {
                let hasWriteback = match(.bang)
                // Spec §6.3: "General LDM/STM addressing modes: E012, not in this
                // subset" — only `SP!` is supported. A different base register, or
                // a missing `!`, is the general form; Lowering hardcodes R13 and
                // always writes back regardless of what was parsed here, so
                // silently accepting either would store at the wrong register (or
                // the right one without ever announcing the writeback) with no
                // diagnostic at all.
                if number != 13 || !hasWriteback {
                    diagnostics.emit(Diagnostic(
                        severity: .error, code: "E012",
                        message: "general LDM/STM is not supported in this subset",
                        range: registerRange,
                        note: "write `STMFD SP!, {...}` / `LDMFD SP!, {...}`"
                    ))
                }
            }
            return .register(number)
        }

        if peek() == .hash {
            guard let operand2 = parseOperand2(into: &diagnostics) else { return nil }
            return .operand2(operand2)
        }

        // A bare symbol: `B label`, `BL label`, `ADR Rd, label`, `LDR Rd, label`.
        if case .symbol(let name) = peek() {
            advance()
            switch mnemonic {
            case .b, .bl, .adr:
                return .labelReference(name)
            case .ldr, .str, .ldrb, .strb, .ldrh, .strh:
                return .address(.label(name))
            default:
                return .labelReference(name)
            }
        }

        diagnostics.emit(Diagnostic(
            severity: .error, code: "E038",
            message: "expected an operand",
            range: current.range, note: nil
        ))
        return nil
    }

    /// True when the register at the cursor is Operand2 itself (Spec §6.2) rather than a
    /// preceding destination/base register. Operand2's own shift clause is introduced by a
    /// comma (`R1, LSL #2`), the same token that separates two distinct operands (`R1, R2`),
    /// so this looks one token past that comma to tell which case it is. With no comma at
    /// all, the register is the last token in the operand list, so it is Operand2 too
    /// (`ADD R4, R1, R2`'s trailing `R2`, or a bare `MOV Rd, Rm`).
    private func registerIsTrailingOperand2() -> Bool {
        switch peek(1) {
        case .comma:
            guard case .symbol(let word) = peek(2) else { return false }
            return ShiftKind(text: word) != nil
        case .symbol(let word):
            return ShiftKind(text: word) != nil
        case .endOfLine, .endOfFile:
            return true
        default:
            // Some other token follows directly with no comma — e.g. `MOV R1 R2`. That is
            // a missing-comma error, not a trailing operand; `parseInstruction`'s post-loop
            // check (E040) is what actually diagnoses it. Returning false here just makes
            // this register a plain one so the mis-following token is left for that check
            // to see, rather than being silently absorbed as Operand2.
            return false
        }
    }

    /// Spec §6.2.
    mutating func parseOperand2(into diagnostics: inout DiagnosticBag) -> Operand2? {
        if match(.hash) {
            guard let value = parseExpression(into: &diagnostics) else { return nil }
            return .immediate(value)
        }

        guard case .register(let number) = peek() else {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E018",
                message: "expected a register or an immediate",
                range: current.range, note: nil
            ))
            return nil
        }
        advance()

        // `Rm, <shift> ...` — the comma before a shift clause (Spec §6.2). Only consumed
        // when a shift keyword actually follows, so a plain trailing register (no shift)
        // never eats a comma that belongs to something else.
        if case .comma = peek(), case .symbol(let word) = peek(1), ShiftKind(text: word) != nil {
            advance()
        }

        guard case .symbol(let word) = peek(), let kind = ShiftKind(text: word) else {
            return .register(number)
        }
        advance()

        if kind == .rrx {
            return .shifted(register: number, shift: ShiftSpec(kind: .rrx))
        }
        if match(.hash) {
            guard let amount = parseExpression(into: &diagnostics) else { return nil }
            return .shifted(register: number, shift: ShiftSpec(kind: kind, amount: amount))
        }
        if case .register(let shiftRegister) = peek() {
            advance()
            return .shifted(register: number, shift: ShiftSpec(kind: kind, amountRegister: shiftRegister))
        }

        diagnostics.emit(Diagnostic(
            severity: .error, code: "E019",
            message: "\(word.uppercased()) needs a shift amount",
            range: current.range,
            note: "write `\(word.uppercased()) #n` or `\(word.uppercased()) Rs`"
        ))
        return nil
    }

    // MARK: - Addressing modes and register lists (Spec §6.3)

    /// Spec §6.3 addressing modes.
    private mutating func parseAddressMode(into diagnostics: inout DiagnosticBag) -> AddressMode? {
        guard match(.leftBracket) else { return nil }

        guard case .register(let base) = peek() else {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E022",
                message: "expected a base register after '['",
                range: current.range, note: nil
            ))
            return nil
        }
        advance()

        // `[Rn]` and `[Rn], #off`
        if match(.rightBracket) {
            guard match(.comma) else {
                return .immediateOffset(base: base, offset: nil, negated: false, writeBack: false)
            }
            // The sign lives inside the immediate, after '#' (`#-8`), not before it — unlike
            // the register-offset form (`-Rm`), where it is the only place a sign can go
            // since a register token cannot carry one itself.
            guard match(.hash) else {
                diagnostics.emit(Diagnostic(
                    severity: .error, code: "E023",
                    message: "expected a post-indexed offset",
                    range: current.range, note: "write `[Rn], #4`"
                ))
                return nil
            }
            let negated = parseOffsetSign()
            guard let offset = parseExpression(into: &diagnostics) else { return nil }
            return .postIndexed(base: base, offset: offset, negated: negated)
        }

        guard match(.comma) else {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E024",
                message: "expected ',' or ']'",
                range: current.range, note: nil
            ))
            return nil
        }

        // `[Rn, #±off]{!}`
        if match(.hash) {
            let negated = parseOffsetSign()
            guard let offset = parseExpression(into: &diagnostics) else { return nil }
            guard match(.rightBracket) else {
                diagnostics.emit(Diagnostic(
                    severity: .error, code: "E025",
                    message: "expected ']'",
                    range: current.range, note: nil
                ))
                return nil
            }
            let writeBack = match(.bang)
            return .immediateOffset(base: base, offset: offset, negated: negated, writeBack: writeBack)
        }

        // `[Rn, ±Rm{, <shift> #k}]{!}` — the sign, if any, precedes the register directly.
        let negated = parseOffsetSign()
        guard case .register(let offsetRegister) = peek() else {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E026",
                message: "expected an offset register or '#'",
                range: current.range, note: nil
            ))
            return nil
        }
        advance()

        var shift: ShiftSpec?
        if match(.comma) {
            guard case .symbol(let word) = peek(), let kind = ShiftKind(text: word) else {
                diagnostics.emit(Diagnostic(
                    severity: .error, code: "E027",
                    message: "expected a shift after the offset register",
                    range: current.range, note: nil
                ))
                return nil
            }
            advance()
            if kind == .rrx {
                shift = ShiftSpec(kind: .rrx)
            } else {
                guard match(.hash), let amount = parseExpression(into: &diagnostics) else {
                    diagnostics.emit(Diagnostic(
                        severity: .error, code: "E028",
                        message: "a scaled register offset needs an immediate shift amount",
                        range: current.range, note: "write `[Rn, Rm, LSL #2]`"
                    ))
                    return nil
                }
                shift = ShiftSpec(kind: kind, amount: amount)
            }
        }

        guard match(.rightBracket) else {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E025",
                message: "expected ']'",
                range: current.range, note: nil
            ))
            return nil
        }
        let writeBack = match(.bang)
        return .registerOffset(
            base: base, offset: offsetRegister, negated: negated,
            shift: shift, writeBack: writeBack
        )
    }

    private mutating func parseOffsetSign() -> Bool {
        if match(.minus) { return true }
        _ = match(.plus)
        return false
    }

    /// `{r1, r4}` register list. Spec §6.3: lists are stored lowest-register-at-lowest-address
    /// regardless of the order written, so the result is sorted before Task 16's lowering
    /// walks it.
    private mutating func parseRegisterList(into diagnostics: inout DiagnosticBag) -> [Int]? {
        guard match(.leftBrace) else { return nil }
        var registers: [Int] = []
        repeat {
            guard case .register(let number) = peek() else {
                diagnostics.emit(Diagnostic(
                    severity: .error, code: "E029",
                    message: "expected a register in the list",
                    range: current.range, note: nil
                ))
                return nil
            }
            advance()
            registers.append(number)
        } while match(.comma)

        // As with data lists (E039) and instruction operands (E040): the loop above only
        // re-enters on a comma, so "the next token isn't a comma" reads as "the list is
        // done." A '}' here means it really is done. Anything else that is itself another
        // register (e.g. `{R1 R4}`, where R4 directly follows R1 with no separating comma)
        // means a register was about to be silently dropped from the list — diagnose that
        // distinctly (E041) rather than letting it fall through to the generic "expected '}'"
        // below, which would misname a missing-comma error as a missing-brace one.
        if case .register = peek() {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E041",
                message: "expected ',' between registers in the list",
                range: current.range, note: nil
            ))
            return nil
        }

        guard match(.rightBrace) else {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E030",
                message: "expected '}'",
                range: current.range, note: nil
            ))
            return nil
        }
        return registers.sorted()
    }
}
