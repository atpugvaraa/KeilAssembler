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
                if match(.equals), case .integer(let value) = peek() {
                    advance()
                    alignment = Int(value)
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

    // MARK: - Stub for Task 7

    /// Stub: Task 7 replaces this with real operand parsing. Consumes just the
    /// mnemonic token, builds an `Instruction` with no operands, and skips the
    /// rest of the line.
    private mutating func parseInstruction(into diagnostics: inout DiagnosticBag) -> Statement? {
        guard case .symbol(let text) = peek(),
              let parts = Mnemonic.decompose(text) else { return nil }
        let range = current.range
        advance()
        skipToEndOfLine()
        return .instruction(Instruction(
            mnemonic: parts.mnemonic,
            condition: parts.condition,
            setsFlags: parts.setsFlags,
            operands: [],
            range: range
        ))
    }
}
