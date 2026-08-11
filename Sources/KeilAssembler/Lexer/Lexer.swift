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
}
