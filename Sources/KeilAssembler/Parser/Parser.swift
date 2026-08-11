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

        let statement = parseStatement(into: &diagnostics)
        return Line(label: label, statement: statement, range: startRange)
    }

    /// Filled in by Tasks 6–8. Returns nil and consumes the line when nothing parses.
    private mutating func parseStatement(into diagnostics: inout DiagnosticBag) -> Statement? {
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
            return parseDirective(into: &diagnostics)
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

    // MARK: - Stubs for Tasks 6-7

    /// Stub: Task 6 replaces this with real directive parsing. Consumes the
    /// rest of the line so the parser's cursor invariant holds and returns
    /// nil (no statement) until then.
    private mutating func parseDirective(into diagnostics: inout DiagnosticBag) -> Statement? {
        skipToEndOfLine()
        return nil
    }

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
