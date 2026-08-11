import Foundation

/// Spec §4. Mnemonics, registers, condition suffixes, shift names and directives are
/// case-insensitive; user symbols are case-sensitive, so symbol spelling is preserved.
struct Lexer {
    private let lines: [[Character]]

    init(source: String) {
        // `omittingEmptySubsequences: false` keeps blank lines, so line indices in
        // diagnostics and in the trace's srcLine field match the editor's line numbers.
        lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Array($0) }
    }

    func tokenize(into diagnostics: inout DiagnosticBag) -> [Token] {
        PerfLog.mark("lex-start")
        var bag = diagnostics
        let tokens = PerfLog.measure("lex") { () -> [Token] in
            var result: [Token] = []
            for (lineIndex, characters) in lines.enumerated() {
                scan(characters, line: lineIndex, into: &result, diagnostics: &bag)
                // Add endOfLine only for lines that actually have a newline after them.
                // The split with omittingEmptySubsequences: false creates an empty last
                // element if the source ends with a newline, so we skip the last line.
                if lineIndex < lines.count - 1 {
                    result.append(Token(
                        kind: .endOfLine,
                        range: SourceRange(line: lineIndex, column: characters.count, length: 0)
                    ))
                }
            }
            result.append(Token(
                kind: .endOfFile,
                range: SourceRange(line: lines.count, column: 0, length: 0)
            ))
            return result
        }
        diagnostics = bag
        PerfLog.info("lexed \(lines.count) lines into \(tokens.count) tokens")
        return tokens
    }

    private func scan(
        _ characters: [Character],
        line: Int,
        into tokens: inout [Token],
        diagnostics: inout DiagnosticBag
    ) {
        var column = 0
        while column < characters.count {
            let character = characters[column]

            if character == ";" { return }                 // comment runs to end of line
            if character == " " || character == "\t" { column += 1; continue }

            if character == "&" || character.isNumber {
                let start = column
                let value = scanNumber(characters, from: &column, line: line, diagnostics: &diagnostics)
                tokens.append(Token(
                    kind: .integer(value),
                    range: SourceRange(line: line, column: start, length: column - start)
                ))
                continue
            }

            if character == "'" {
                let start = column
                column += 1
                guard column < characters.count, characters[column] != "'" else {
                    diagnostics.emit(Diagnostic(
                        severity: .error, code: "E003",
                        message: "empty character literal",
                        range: SourceRange(line: line, column: start, length: 1), note: nil
                    ))
                    column += 1
                    continue
                }
                let scalar = characters[column]
                column += 1
                if column < characters.count, characters[column] == "'" { column += 1 }
                tokens.append(Token(
                    kind: .integer(scalar.unicodeScalars.first.map { UInt32($0.value) } ?? 0),
                    range: SourceRange(line: line, column: start, length: column - start)
                ))
                continue
            }

            if character == "\"" {
                let start = column
                column += 1
                var text = ""
                while column < characters.count, characters[column] != "\"" {
                    text.append(characters[column])
                    column += 1
                }
                guard column < characters.count else {
                    diagnostics.emit(Diagnostic(
                        severity: .error, code: "E002",
                        message: "unterminated string literal",
                        range: SourceRange(line: line, column: start, length: characters.count - start),
                        note: "add a closing double quote"
                    ))
                    return
                }
                column += 1
                tokens.append(Token(
                    kind: .string(text),
                    range: SourceRange(line: line, column: start, length: column - start)
                ))
                continue
            }

            if character == ":" {
                let start = column
                column += 1
                var word = ""
                while column < characters.count, characters[column] != ":" {
                    word.append(characters[column])
                    column += 1
                }
                guard column < characters.count else {
                    diagnostics.emit(Diagnostic(
                        severity: .error, code: "E004",
                        message: "unterminated operator, expected a closing ':'",
                        range: SourceRange(line: line, column: start, length: characters.count - start),
                        note: "write operators as :SHL:, :AND:, :MOD:"
                    ))
                    return
                }
                column += 1
                tokens.append(Token(
                    kind: .operatorWord(word.uppercased()),
                    range: SourceRange(line: line, column: start, length: column - start)
                ))
                continue
            }

            if let punctuation = Self.punctuation[character] {
                tokens.append(Token(
                    kind: punctuation,
                    range: SourceRange(line: line, column: column, length: 1)
                ))
                column += 1
                continue
            }

            if character.isLetter || character == "_" {
                let start = column
                while column < characters.count,
                      characters[column].isLetter || characters[column].isNumber || characters[column] == "_" {
                    column += 1
                }
                let text = String(characters[start..<column])
                let range = SourceRange(line: line, column: start, length: column - start)
                tokens.append(Token(kind: Self.classify(text), range: range))
                continue
            }

            diagnostics.emit(Diagnostic(
                severity: .error,
                code: "E001",
                message: "unexpected character '\(character)'",
                range: SourceRange(line: line, column: column, length: 1),
                note: nil
            ))
            column += 1
        }
    }

    private static let punctuation: [Character: Token.Kind] = [
        ",": .comma, "[": .leftBracket, "]": .rightBracket,
        "{": .leftBrace, "}": .rightBrace, "!": .bang, "#": .hash,
        "=": .equals, "+": .plus, "-": .minus, "*": .star, "/": .slash,
        "(": .leftParen, ")": .rightParen, "^": .caret, ".": .dot,
    ]

    /// `R0`–`R15` and the aliases `SP`, `LR`, `PC` become register tokens; anything
    /// else is a symbol with its spelling preserved.
    private static func classify(_ text: String) -> Token.Kind {
        switch text.uppercased() {
        case "SP": return .register(13)
        case "LR": return .register(14)
        case "PC": return .register(15)
        default: break
        }
        let upper = text.uppercased()
        if upper.hasPrefix("R"), let number = Int(upper.dropFirst()), (0...15).contains(number) {
            return .register(number)
        }
        return .symbol(text)
    }

    /// Spec §4: `&1F`, `0x1F`, `31`, and `<base>_<digits>`.
    private func scanNumber(
        _ characters: [Character],
        from column: inout Int,
        line: Int,
        diagnostics: inout DiagnosticBag
    ) -> UInt32 {
        let start = column

        if characters[column] == "&" {
            column += 1
            return consume(characters, from: &column, radix: 16, start: start, line: line, diagnostics: &diagnostics)
        }

        // 0x / 0X
        if characters[column] == "0", column + 1 < characters.count,
           characters[column + 1] == "x" || characters[column + 1] == "X" {
            column += 2
            return consume(characters, from: &column, radix: 16, start: start, line: line, diagnostics: &diagnostics)
        }

        // <base>_<digits>
        var lookahead = column
        var basePrefix = ""
        while lookahead < characters.count, characters[lookahead].isNumber {
            basePrefix.append(characters[lookahead])
            lookahead += 1
        }
        if lookahead < characters.count, characters[lookahead] == "_",
           let radix = Int(basePrefix), (2...16).contains(radix) {
            column = lookahead + 1
            return consume(characters, from: &column, radix: radix, start: start, line: line, diagnostics: &diagnostics)
        }

        return consume(characters, from: &column, radix: 10, start: start, line: line, diagnostics: &diagnostics)
    }

    private func consume(
        _ characters: [Character],
        from column: inout Int,
        radix: Int,
        start: Int,
        line: Int,
        diagnostics: inout DiagnosticBag
    ) -> UInt32 {
        var digits = ""
        while column < characters.count, characters[column].isHexDigit || characters[column] == "_" {
            if characters[column] != "_" { digits.append(characters[column]) }
            column += 1
        }
        guard !digits.isEmpty, let value = UInt64(digits, radix: radix) else {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E005",
                message: "'\(digits)' is not a valid base-\(radix) literal",
                range: SourceRange(line: line, column: start, length: max(1, column - start)),
                note: nil
            ))
            return 0
        }
        // Spec §5.1: integer expressions are 32-bit wrapping.
        return UInt32(truncatingIfNeeded: value)
    }
}
