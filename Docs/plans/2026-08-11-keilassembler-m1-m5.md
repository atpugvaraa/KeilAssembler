# KeilAssembler M1–M5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take Keil ARMASM source through lexing, parsing, analysis, and AArch64 lowering, then assemble, link, and run it natively so the lab exercises in Spec §10 produce their expected ARM7 register state.

**Architecture:** A single Swift package with no UI dependencies. Source → `Lexer` → `Parser` → `Analyser` → `Lowering` → Darwin `.s` text → `clang` → Mach-O executable, run in its own directory alongside `image.bin` (ARM7 memory contents) and `trace.bin` (a per-instruction machine-state snapshot). ARM7 registers live in a memory struct addressed by `x27`; ARM7 memory is a 4 GiB lazily-committed `mmap` addressed by `x28`.

**Tech Stack:** Swift 6.3 (`swiftLanguageModes: [.v6]`), Swift Testing (`@Test`/`#expect`), Foundation, `/usr/bin/clang`, a small C runtime (`armd_rt.c`) shipped as a package resource.

## Global Constraints

Copied verbatim from `Docs/PRD.md` §7 and `Docs/Spec.md`. Every task inherits these.

- macOS 15+, Apple Silicon (arm64) only.
- Swift 6.3, `swiftLanguageModes: [.v6]`, strict concurrency.
- Swift Testing (`@Test` / `#expect`), not XCTest.
- Toolchain dependency: `/usr/bin/clang` (Command Line Tools). No Homebrew packages, no `arm-none-eabi-*`, no QEMU.
- Zero third-party Swift dependencies.
- Package builds and tests headlessly (CI-able, no UI required).
- **PRD S4:** `KeilAssembler` has no `import SwiftUI` and no AppKit dependency.
- **PRD S3:** Unsupported constructs produce a diagnostic naming the construct and the source location. Silently emitting wrong code is a defect of the highest severity.
- **Spec §2 Rule:** The lexer and parser preserve what the source says. All normalisation happens at or after analysis.
- **Register file offsets are normative (Spec §7.2):** `Rn` at `[x27, #(n*4)]`, `cpsr` at `[x27, #0x40]`.
- **Host register roles are normative (Spec §7.1):** `x27` = register file, `x28` = ARM7 memory base, `w9`–`w12` scratch.

## Logging Policy

Decided for this plan; applies to every file.

- `PerformanceLogger.swift` is copied verbatim from cisum into `Sources/KeilAssembler/Support/`, with `public` changed to `internal` on the `PerfLog` type only. It never escapes the package. Tests reach it via `@testable import KeilAssembler`.
- **Boundaries:** every pass wraps its body in `PerfLog.measure("<pass>")` — `lex`, `parse`, `analyse`, `lower`, `emit`, `assemble`, `link`, `run`, `decode-trace`.
- **Every error path:** every `throw` and every `Diagnostic` emission is preceded by `PerfLog.error(...)` carrying the diagnostic code and source location.
- **Phase transitions:** `PerfLog.mark(...)` at the start of each pass.
- **No per-token, per-character, or per-instruction logging.** `PERFORMANCE_LOGGING_GUIDE.md` §Best Practices: "Avoid logging inside tight loops."
- A successful build emits roughly 8–10 log lines.

## Spec-Defect Protocol

When implementation hits a defect in `Docs/Spec.md`: correct `Spec.md`, state the correction plainly in the commit message body, and continue. Do not silently implement around it.

Already applied before this plan was written: Spec §7.7 passed the trace store-address as an immediate; it is a runtime value, now passed from `w9`. Committed separately.

## Assumptions

Stated so they can be vetoed at approval rather than discovered later.

- `armd_rt.c` ships as an SPM **resource** (`.copy`) and is read at build time via `Bundle.module`. The alternative — embedding it as a Swift string literal — keeps the C unreadable and unlintable.
- The lexer classifies `R0`–`R15`, `SP`, `LR`, `PC` as register tokens (Spec §4's token table lists Register as a token form). A user symbol named `PC` would therefore not lex as a symbol. No corpus program does this.
- Run directories are created under `FileManager.default.temporaryDirectory` unless the caller supplies one.

## File Structure

```
KeilAssembler/
├── Package.swift                                  platforms, test target, resource
├── Sources/KeilAssembler/
│   ├── Support/
│   │   ├── PerformanceLogger.swift                copied verbatim, internal
│   │   └── SourceRange.swift                      line/column/length
│   ├── Diagnostics/
│   │   └── Diagnostic.swift                       Spec §8, plus DiagnosticBag
│   ├── Lexer/
│   │   ├── Token.swift                            Token, Token.Kind
│   │   └── Lexer.swift                            Spec §4
│   ├── AST/
│   │   ├── Mnemonic.swift                         Mnemonic, Condition, ShiftKind
│   │   └── AST.swift                              Expression, Operand2, AddressMode,
│   │                                              Directive, Instruction, Line, Program
│   ├── Parser/
│   │   └── Parser.swift                           Spec §4.1, §5, §6
│   ├── Analysis/
│   │   ├── ExpressionEvaluator.swift              Spec §5.1
│   │   └── Analyser.swift                         Spec §5.2, §6.2 legality, diagnostics
│   ├── Backend/
│   │   ├── AssemblyBuilder.swift                  .s text accumulation
│   │   ├── Emitter.swift                          Spec §7.1–7.3, §7.9 primitives
│   │   └── Lowering.swift                         Spec §7.4–7.7
│   ├── Runtime/
│   │   ├── StartupImage.swift                     Spec §5.3
│   │   └── Resources/armd_rt.c                    Spec §7.8
│   ├── Trace/
│   │   └── TraceDecoder.swift                     Spec §7.7 record → MachineSnapshot
│   └── Driver/
│       └── Driver.swift                           Spec §7.9 build + run
└── Tests/KeilAssemblerTests/
    ├── LexerTests.swift
    ├── ParserTests.swift
    ├── AnalyserTests.swift
    ├── LoweringTests.swift
    ├── StartupImageTests.swift
    ├── TraceDecoderTests.swift
    └── CorpusTests.swift                          Spec §10
```

---

### Task 1: Package skeleton, logger, source ranges, diagnostics

**Files:**
- Modify: `Package.swift`
- Create: `Sources/KeilAssembler/Support/PerformanceLogger.swift`
- Create: `Sources/KeilAssembler/Support/SourceRange.swift`
- Create: `Sources/KeilAssembler/Diagnostics/Diagnostic.swift`
- Delete: `Sources/KeilAssembler/KeilAssembler.swift` (empty placeholder)
- Test: `Tests/KeilAssemblerTests/DiagnosticTests.swift`

**Interfaces:**
- Produces: `SourceRange(line:column:length:)`; `Diagnostic(severity:code:message:range:note:)` with `Severity.error/.warning/.note`; `DiagnosticBag` with `emit(_:)`, `diagnostics`, `hasErrors`; `PerfLog.trace/debug/info/warning/error/mark/measure/start/end`.

- [ ] **Step 1: Write the failing test**

`Tests/KeilAssemblerTests/DiagnosticTests.swift`:

```swift
import Testing
@testable import KeilAssembler

@Test func diagnosticBagSeparatesErrorsFromWarnings() {
    var bag = DiagnosticBag()
    #expect(bag.hasErrors == false)

    bag.emit(Diagnostic(
        severity: .warning,
        code: "W001",
        message: "instruction in the label column",
        range: SourceRange(line: 3, column: 0, length: 3),
        note: "indent the instruction"
    ))
    #expect(bag.hasErrors == false)
    #expect(bag.diagnostics.count == 1)

    bag.emit(Diagnostic(
        severity: .error,
        code: "E020",
        message: "immediate cannot be encoded",
        range: SourceRange(line: 4, column: 8, length: 6),
        note: nil
    ))
    #expect(bag.hasErrors == true)
    #expect(bag.diagnostics.map(\.code) == ["W001", "E020"])
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter DiagnosticTests`
Expected: FAIL — no test target exists yet, or `cannot find 'DiagnosticBag' in scope`.

- [ ] **Step 3: Update `Package.swift`**

```swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "KeilAssembler",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KeilAssembler", targets: ["KeilAssembler"]),
    ],
    targets: [
        .target(
            name: "KeilAssembler",
            resources: [.copy("Runtime/Resources/armd_rt.c")]
        ),
        .testTarget(
            name: "KeilAssemblerTests",
            dependencies: ["KeilAssembler"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

Create a placeholder so the resource path resolves: `Sources/KeilAssembler/Runtime/Resources/armd_rt.c` containing only `// filled in by Task 17`.

- [ ] **Step 4: Copy the logger**

```bash
mkdir -p ~/Programming/Swift/Packages/KeilAssembler/Sources/KeilAssembler/Support
cp ~/Programming/Swift/SwiftUI/cisum/Modules/Shared/Utilities/Sources/Utilities/PerformanceLogger.swift \
   ~/Programming/Swift/Packages/KeilAssembler/Sources/KeilAssembler/Support/PerformanceLogger.swift
```

Then edit the copy: change `public enum PerfLog` to `enum PerfLog`, and delete the `getLogFileURL()` method (it names cisum's log file and has no caller here). Leave every other member — `public` on members of an internal type is legal and keeps the diff to the original minimal. Replace the file header comment block with:

```swift
//
//  PerformanceLogger.swift
//  KeilAssembler
//
//  Copied from cisum (Modules/Shared/Utilities). Kept internal: the package
//  must not export a second PerfLog into any app that also carries one.
//
```

- [ ] **Step 5: Write `SourceRange.swift`**

```swift
/// A span of source text. Line and column are 0-based, matching Spec §7.7's
/// `srcLine` trace field so a snapshot indexes the source array directly.
struct SourceRange: Sendable, Equatable {
    let line: Int
    let column: Int
    let length: Int

    init(line: Int, column: Int, length: Int) {
        self.line = line
        self.column = column
        self.length = length
    }
}

extension SourceRange: CustomStringConvertible {
    var description: String { "\(line + 1):\(column + 1)" }
}
```

- [ ] **Step 6: Write `Diagnostic.swift`**

```swift
/// Spec §8. Errors are collected, not thrown: one build reports every error it can find.
struct Diagnostic: Sendable, Equatable {
    enum Severity: Sendable, Equatable { case error, warning, note }

    let severity: Severity
    let code: String        // "E020", "W001"
    let message: String     // ARMASM vocabulary, not compiler-internal vocabulary
    let range: SourceRange
    let note: String?       // what to do instead
}

/// Accumulates diagnostics across a build. Spec §8: a build with any error emits no assembly.
struct DiagnosticBag: Sendable {
    private(set) var diagnostics: [Diagnostic] = []
    private(set) var hasErrors = false

    init() {}

    mutating func emit(_ diagnostic: Diagnostic) {
        if diagnostic.severity == .error {
            hasErrors = true
            PerfLog.error("\(diagnostic.code) at \(diagnostic.range): \(diagnostic.message)")
        } else {
            PerfLog.warning("\(diagnostic.code) at \(diagnostic.range): \(diagnostic.message)")
        }
        diagnostics.append(diagnostic)
    }
}
```

Every diagnostic is logged at the moment it is emitted. That is the whole of the "catch errors as they happen" policy for the analysis passes — no call site has to remember to log.

- [ ] **Step 7: Delete the placeholder**

```bash
rm ~/Programming/Swift/Packages/KeilAssembler/Sources/KeilAssembler/KeilAssembler.swift
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `swift test --filter DiagnosticTests`
Expected: PASS, 1 test.

- [ ] **Step 9: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Package.swift Sources Tests
git commit -m "feat: package skeleton with logger, source ranges, and diagnostics"
```

---

### Task 2: Token type and lexer core

**Files:**
- Create: `Sources/KeilAssembler/Lexer/Token.swift`
- Create: `Sources/KeilAssembler/Lexer/Lexer.swift`
- Test: `Tests/KeilAssemblerTests/LexerTests.swift`

**Interfaces:**
- Consumes: `SourceRange`, `DiagnosticBag`, `PerfLog`.
- Produces: `Token(kind:range:)`; `Token.Kind` cases `.symbol(String)`, `.integer(UInt32)`, `.string(String)`, `.register(Int)`, `.operatorWord(String)`, `.hash`, `.comma`, `.leftBracket`, `.rightBracket`, `.leftBrace`, `.rightBrace`, `.bang`, `.equals`, `.plus`, `.minus`, `.star`, `.slash`, `.leftParen`, `.rightParen`, `.caret`, `.dot`, `.endOfLine`, `.endOfFile`; `Lexer(source: String)` with `func tokenize(into: inout DiagnosticBag) -> [Token]`.

- [ ] **Step 1: Write the failing test**

`Tests/KeilAssemblerTests/LexerTests.swift`:

```swift
import Testing
@testable import KeilAssembler

private func lex(_ source: String) -> [Token.Kind] {
    var bag = DiagnosticBag()
    return Lexer(source: source).tokenize(into: &bag).map(\.kind)
}

@Test func lexerSplitsALabelledInstructionLine() {
    #expect(lex("MAIN\n    MOV R1, R2\n") == [
        .symbol("MAIN"), .endOfLine,
        .symbol("MOV"), .register(1), .comma, .register(2), .endOfLine,
        .endOfFile,
    ])
}

@Test func lexerDropsCommentsButKeepsTheLineBreak() {
    #expect(lex("MOV R1, R2 ; copy it\nEND\n") == [
        .symbol("MOV"), .register(1), .comma, .register(2), .endOfLine,
        .symbol("END"), .endOfLine,
        .endOfFile,
    ])
}

@Test func lexerRecognisesRegisterAliases() {
    #expect(lex("SP LR PC R15") == [
        .register(13), .register(14), .register(15), .register(15), .endOfFile,
    ])
}

@Test func lexerRecordsColumnsForDiagnostics() {
    var bag = DiagnosticBag()
    let tokens = Lexer(source: "    MOV R1").tokenize(into: &bag)
    #expect(tokens[0].range == SourceRange(line: 0, column: 4, length: 3))
    #expect(tokens[1].range == SourceRange(line: 0, column: 8, length: 2))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter LexerTests`
Expected: FAIL with `cannot find 'Lexer' in scope`.

- [ ] **Step 3: Write `Token.swift`**

```swift
/// Spec §4. The lexer preserves what the source says; it does not normalise.
struct Token: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case symbol(String)         // case preserved: user symbols are case-sensitive
        case integer(UInt32)
        case string(String)
        case register(Int)          // 0...15, with SP=13, LR=14, PC=15
        case operatorWord(String)   // :MOD:, :SHL:, :SHR:, :AND:, :OR:, :EOR: — uppercased
        case hash
        case comma
        case leftBracket, rightBracket
        case leftBrace, rightBrace
        case bang
        case equals
        case plus, minus, star, slash
        case leftParen, rightParen
        case caret
        case dot                    // '.' — current position, Spec §5.1
        case endOfLine
        case endOfFile
    }

    let kind: Kind
    let range: SourceRange
}
```

- [ ] **Step 4: Write `Lexer.swift` (structure, punctuation, symbols, registers)**

```swift
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
                // Emit one `.endOfLine` per newline actually present in the source.
                // Splitting with `omittingEmptySubsequences: false` yields a trailing
                // empty element when the source ends in a newline; without this guard
                // that element would contribute a spurious extra `.endOfLine`.
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter LexerTests`
Expected: PASS, 4 tests. Console shows one `lex took …ms` line per `tokenize` call.

- [ ] **Step 6: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler/Lexer Tests/KeilAssemblerTests/LexerTests.swift
git commit -m "feat: token type and lexer core"
```

---

### Task 3: Lexer literals

**Files:**
- Modify: `Sources/KeilAssembler/Lexer/Lexer.swift`
- Test: `Tests/KeilAssemblerTests/LexerTests.swift`

**Interfaces:**
- Consumes: `Token.Kind`, `DiagnosticBag` from Tasks 1–2.
- Produces: no new API — `Lexer.tokenize` now yields `.integer`, `.string`, and `.operatorWord`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/KeilAssemblerTests/LexerTests.swift`:

```swift
@Test func lexerReadsEveryNumericLiteralForm() {
    #expect(lex("&1F 0x1F 0X1F 31 2_00011111 8_37 16_1f") == [
        .integer(0x1F), .integer(0x1F), .integer(0x1F),
        .integer(31), .integer(0b0001_1111), .integer(0o37), .integer(0x1F),
        .endOfFile,
    ])
}

@Test func lexerReadsCharacterAndStringLiterals() {
    #expect(lex("'A' \"text\"") == [.integer(65), .string("text"), .endOfFile])
}

@Test func lexerReadsColonDelimitedOperators() {
    #expect(lex("1 :SHL: 2 :and: 3") == [
        .integer(1), .operatorWord("SHL"), .integer(2),
        .operatorWord("AND"), .integer(3), .endOfFile,
    ])
}

@Test func lexerRejectsAnUnterminatedString() {
    var bag = DiagnosticBag()
    _ = Lexer(source: "\"oops").tokenize(into: &bag)
    #expect(bag.diagnostics.map(\.code) == ["E002"])
    #expect(bag.hasErrors)
}

@Test func lexerRejectsMalformedLiteralsRatherThanInventingValues() {
    // PRD S3: every one of these must diagnose, not silently produce a token.
    func codes(_ source: String) -> [String] {
        var bag = DiagnosticBag()
        _ = Lexer(source: source).tokenize(into: &bag)
        return bag.diagnostics.map(\.code)
    }
    #expect(codes("'A") == ["E003"])        // would otherwise yield .integer(65)
    #expect(codes("99_5") == ["E005"])      // would otherwise yield .integer(995)
    #expect(codes("&") == ["E005"])         // lone ampersand, no digits
    #expect(codes(":SHL") == ["E004"])      // no closing colon
}

@Test func lexerWrapsLiteralsWiderThan32Bits() {
    #expect(lex("&1FFFFFFFF") == [.integer(0xFFFF_FFFF), .endOfFile])
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter LexerTests`
Expected: FAIL — `&1F` produces `E001 unexpected character '&'`.

- [ ] **Step 3: Add literal scanning to `Lexer.swift`**

Insert these branches in `scan`, immediately **before** the `punctuation` lookup so that `.` inside a based literal and `-` are not stolen, and before the letter branch so `2_0001` is not read as a symbol:

```swift
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
                // An unterminated character literal must not yield a value: PRD S3
                // makes silently emitting wrong output the highest-severity defect.
                guard column < characters.count, characters[column] == "'" else {
                    diagnostics.emit(Diagnostic(
                        severity: .error, code: "E003",
                        message: "unterminated character literal",
                        range: SourceRange(line: line, column: start, length: column - start),
                        note: "add a closing single quote"
                    ))
                    continue
                }
                column += 1
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
```

Add the number scanner as a private method:

```swift
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
        if lookahead < characters.count, characters[lookahead] == "_" {
            // An underscore means the author declared a base. If that base is out of
            // range the literal is malformed — it must not fall through to the decimal
            // path, which would silently reinterpret `99_5` as 995 (PRD S3).
            guard let radix = Int(basePrefix), (2...16).contains(radix) else {
                column = lookahead + 1
                while column < characters.count, characters[column].isHexDigit { column += 1 }
                diagnostics.emit(Diagnostic(
                    severity: .error, code: "E005",
                    message: "base \(basePrefix) is not valid",
                    range: SourceRange(line: line, column: start, length: column - start),
                    note: "bases 2 to 16 are supported"
                ))
                return 0
            }
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter LexerTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler/Lexer Tests/KeilAssemblerTests/LexerTests.swift
git commit -m "feat: lex numeric, character, string, and colon-operator literals"
```

---

### Task 4: AST types

**Files:**
- Create: `Sources/KeilAssembler/AST/Mnemonic.swift`
- Create: `Sources/KeilAssembler/AST/AST.swift`
- Test: `Tests/KeilAssemblerTests/ASTTests.swift`

**Interfaces:**
- Consumes: `SourceRange`.
- Produces: `Mnemonic`, `Condition`, `ShiftKind`, `ShiftSpec`, `Expression`, `UnaryOperator`, `BinaryOperator`, `Operand2`, `AddressMode`, `Operand`, `Directive`, `AreaKind`, `Instruction`, `Statement`, `Line`, `Program`. These names are used verbatim by Tasks 5–16.

- [ ] **Step 1: Write the failing test**

`Tests/KeilAssemblerTests/ASTTests.swift`:

```swift
import Testing
@testable import KeilAssembler

@Test func conditionParsingHandlesBothAliasSpellings() {
    #expect(Condition(suffix: "EQ") == .eq)
    #expect(Condition(suffix: "HS") == .cs)
    #expect(Condition(suffix: "LO") == .cc)
    #expect(Condition(suffix: "ZZ") == nil)
}

@Test func conditionsKnowTheirInverseGuardBranch() {
    // Spec §6.1: a conditional instruction is skipped by branching on the inverse.
    #expect(Condition.eq.inverseBranchSuffix == "ne")
    #expect(Condition.cs.inverseBranchSuffix == "lo")
    #expect(Condition.le.inverseBranchSuffix == "gt")
    #expect(Condition.al.inverseBranchSuffix == nil)
}

@Test func mnemonicParsingIsCaseInsensitive() {
    #expect(Mnemonic(text: "ldrb") == .ldrb)
    #expect(Mnemonic(text: "MOV") == .mov)
    #expect(Mnemonic(text: "NOPE") == nil)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ASTTests`
Expected: FAIL with `cannot find 'Condition' in scope`.

- [ ] **Step 3: Write `Mnemonic.swift`**

```swift
/// Spec §6.1. `HS`/`LO` are alias spellings of `CS`/`CC` and collapse onto them.
enum Condition: String, Sendable, Equatable, CaseIterable {
    case eq, ne, cs, cc, mi, pl, vs, vc, hi, ls, ge, lt, gt, le, al

    init?(suffix: String) {
        switch suffix.lowercased() {
        case "hs": self = .cs
        case "lo": self = .cc
        default:
            guard let parsed = Condition(rawValue: suffix.lowercased()) else { return nil }
            self = parsed
        }
    }

    /// The A64 branch suffix that skips the guarded block, or nil for `AL`
    /// (which emits no guard at all).
    var inverseBranchSuffix: String? {
        switch self {
        case .eq: "ne"
        case .ne: "eq"
        case .cs: "lo"
        case .cc: "hs"
        case .mi: "pl"
        case .pl: "mi"
        case .vs: "vc"
        case .vc: "vs"
        case .hi: "ls"
        case .ls: "hi"
        case .ge: "lt"
        case .lt: "ge"
        case .gt: "le"
        case .le: "gt"
        case .al: nil
        }
    }
}

/// Spec §6.2.
enum ShiftKind: String, Sendable, Equatable, CaseIterable {
    case lsl, lsr, asr, ror, rrx

    init?(text: String) {
        guard let parsed = ShiftKind(rawValue: text.lowercased()) else { return nil }
        self = parsed
    }

    /// A64 shift-by-register mnemonic, Spec §7.4.
    var variableMnemonic: String { rawValue + "v" }
}

/// Spec §6.3.
enum Mnemonic: String, Sendable, Equatable, CaseIterable {
    case mov, mvn
    case add, adc, sub, sbc, rsb, rsc
    case and, orr, eor, bic
    case cmp, cmn, tst, teq
    case mul, mla
    case ldr, str, ldrb, strb, ldrh, strh
    case push, pop, stmfd, ldmfd
    case b, bl, bx
    case adr, nop

    init?(text: String) {
        guard let parsed = Mnemonic(rawValue: text.lowercased()) else { return nil }
        self = parsed
    }

    /// Spec §6.3: these always set flags and have no destination register.
    var isComparison: Bool { self == .cmp || self == .cmn || self == .tst || self == .teq }
}
```

- [ ] **Step 4: Write `AST.swift`**

```swift
// MARK: - Expressions (Spec §5.1)

enum UnaryOperator: Sendable, Equatable { case plus, minus, not }

enum BinaryOperator: Sendable, Equatable {
    case multiply, divide, modulo
    case add, subtract
    case shiftLeft, shiftRight
    case and, or, exclusiveOr
}

indirect enum Expression: Sendable, Equatable {
    case integer(UInt32)
    case symbol(String)
    case here                                       // '.'
    case unary(UnaryOperator, Expression)
    case binary(BinaryOperator, Expression, Expression)
}

// MARK: - Operands (Spec §6.2, §6.3)

struct ShiftSpec: Sendable, Equatable {
    let kind: ShiftKind
    let amount: Expression?     // nil for RRX
    let amountRegister: Int?    // set for `Rm, LSL Rs`

    init(kind: ShiftKind, amount: Expression? = nil, amountRegister: Int? = nil) {
        self.kind = kind
        self.amount = amount
        self.amountRegister = amountRegister
    }
}

enum Operand2: Sendable, Equatable {
    case immediate(Expression)
    case register(Int)
    case shifted(register: Int, shift: ShiftSpec)
}

enum AddressMode: Sendable, Equatable {
    /// `[Rn]`, `[Rn, #±off]`, `[Rn, #±off]!`
    case immediateOffset(base: Int, offset: Expression?, negated: Bool, writeBack: Bool)
    /// `[Rn, ±Rm]`, `[Rn, ±Rm, <shift> #k]`
    case registerOffset(base: Int, offset: Int, negated: Bool, shift: ShiftSpec?, writeBack: Bool)
    /// `[Rn], #±off`
    case postIndexed(base: Int, offset: Expression, negated: Bool)
    /// `LDR Rd, label` — Spec §7.6 literal load
    case label(String)
}

enum Operand: Sendable, Equatable {
    case register(Int)
    case operand2(Operand2)
    case address(AddressMode)
    case registerList([Int])
    case labelReference(String)
    case immediateValue(Expression)     // `LDR Rd, =expr`
}

// MARK: - Statements (Spec §5, §6)

enum AreaKind: Sendable, Equatable { case code, data }

enum Directive: Sendable, Equatable {
    case area(name: String, kind: AreaKind, readOnly: Bool, alignment: Int)
    case entry
    case end
    case equ(symbol: String, value: Expression)
    case align(Expression?)
    case defineBytes([Expression])
    case defineHalfwords([Expression])
    case defineWords([Expression])
    case space(Expression)
    case ltorg
    case export(String)
}

struct Instruction: Sendable, Equatable {
    let mnemonic: Mnemonic
    let condition: Condition
    let setsFlags: Bool
    let operands: [Operand]
    let range: SourceRange
}

enum Statement: Sendable, Equatable {
    case instruction(Instruction)
    case directive(Directive)
}

struct Line: Sendable, Equatable {
    let label: String?
    let statement: Statement?
    let range: SourceRange
}

struct Program: Sendable, Equatable {
    let lines: [Line]
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter ASTTests`
Expected: PASS, 3 tests.

- [ ] **Step 6: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler/AST Tests/KeilAssemblerTests/ASTTests.swift
git commit -m "feat: AST types for ARMASM statements, operands, and expressions"
```

---

### Task 5: Parser line structure and the column-1 rule

**Files:**
- Create: `Sources/KeilAssembler/Parser/Parser.swift`
- Test: `Tests/KeilAssemblerTests/ParserTests.swift`

**Interfaces:**
- Consumes: `Token`, `Lexer`, `DiagnosticBag`, all AST types.
- Produces: `Parser(tokens: [Token])` with `mutating func parse(into: inout DiagnosticBag) -> Program`; internal cursor helpers `peek()`, `advance()`, `match(_:)`, `skipToEndOfLine()` used by Tasks 6–8. Note `parse` is `mutating`, so callers must bind the parser to a `var` — `Parser(tokens:).parse(into:)` does not compile against an rvalue.

- [ ] **Step 1: Write the failing test**

`Tests/KeilAssemblerTests/ParserTests.swift`:

```swift
import Testing
@testable import KeilAssembler

func parse(_ source: String) -> (Program, DiagnosticBag) {
    var bag = DiagnosticBag()
    let tokens = Lexer(source: source).tokenize(into: &bag)
    let program = Parser(tokens: tokens).parse(into: &bag)
    return (program, bag)
}

@Test func parserReadsALabelInColumnOne() {
    let (program, bag) = parse("MAIN\n")
    #expect(bag.diagnostics.isEmpty)
    #expect(program.lines.count == 1)
    #expect(program.lines[0].label == "MAIN")
    #expect(program.lines[0].statement == nil)
}

@Test func parserSkipsBlankAndCommentOnlyLines() {
    let (program, _) = parse("\n; just a comment\n\nMAIN\n")
    #expect(program.lines.count == 1)
    #expect(program.lines[0].label == "MAIN")
}

@Test func parserAcceptsAMnemonicInTheLabelColumnWithW001() {
    // Spec §4.1 / §11 Q2: the lab source puts MOV in column 1.
    let (program, bag) = parse("MOV R1, R2\n")
    #expect(bag.hasErrors == false)
    #expect(bag.diagnostics.map(\.code) == ["W001"])
    #expect(program.lines[0].label == nil)
    guard case .instruction(let instruction)? = program.lines[0].statement else {
        Issue.record("expected an instruction")
        return
    }
    #expect(instruction.mnemonic == .mov)
}

@Test func parserTreatsAnIndentedMnemonicAsAnInstructionWithoutWarning() {
    let (program, bag) = parse("    MOV R1, R2\n")
    #expect(bag.diagnostics.isEmpty)
    #expect(program.lines[0].label == nil)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ParserTests`
Expected: FAIL with `cannot find 'Parser' in scope`.

- [ ] **Step 3: Write `Parser.swift`**

```swift
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

        // The label is threaded through because `sym EQU expr` binds the label as the
        // constant's name — it is the one directive whose meaning depends on it.
        let statement = parseStatement(label: label, into: &diagnostics)
        return Line(label: label, statement: statement, range: startRange)
    }

    /// Filled in by Tasks 6–8. Returns nil and consumes the line when nothing parses.
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
}
```

Add the suffix-aware mnemonic lookup to `Sources/KeilAssembler/AST/Mnemonic.swift`. It is used by both the parser's dispatch above and Task 7's instruction parsing, so it belongs on the type:

```swift
extension Mnemonic {
    /// Splits `<MNEMONIC>{<cond>}{S}` — Spec §6. Suffix order is `cond` then `S`
    /// (`ADDEQS`), and [ARMASM] also accepts the reverse (`ADDSEQ`); both parse.
    /// Longest mnemonic wins so `LDRB` is not read as `LDR` + a bogus suffix.
    init?(parsingSuffixesOf text: String) {
        guard let parts = Mnemonic.decompose(text) else { return nil }
        self = parts.mnemonic
    }

    static func decompose(_ text: String) -> (mnemonic: Mnemonic, condition: Condition, setsFlags: Bool)? {
        let upper = text.uppercased()
        let candidates = Mnemonic.allCases
            .filter { upper.hasPrefix($0.rawValue.uppercased()) }
            .sorted { $0.rawValue.count > $1.rawValue.count }

        for mnemonic in candidates {
            var rest = String(upper.dropFirst(mnemonic.rawValue.count))
            var setsFlags = false
            var condition = Condition.al

            if rest.hasSuffix("S"), rest.count == 1 || rest.count == 3 {
                setsFlags = true
                rest = String(rest.dropLast())
            }
            if rest.hasPrefix("S"), rest.count == 3 {   // ADDSEQ
                setsFlags = true
                rest = String(rest.dropFirst())
            }
            if !rest.isEmpty {
                guard rest.count == 2, let parsed = Condition(suffix: rest) else { continue }
                condition = parsed
            }
            return (mnemonic, condition, setsFlags)
        }
        return nil
    }
}
```

- [ ] **Step 4: Add a temporary stub so the file compiles**

Tasks 6 and 7 replace these. Add to `Parser.swift`:

```swift
    private mutating func parseDirective(label: String?, into diagnostics: inout DiagnosticBag) -> Statement? {
        skipToEndOfLine()
        return nil
    }

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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter ParserTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler Tests/KeilAssemblerTests/ParserTests.swift
git commit -m "feat: parse ARMASM line structure with column-1 leniency (W001)"
```

---

### Task 6: Parse directives

**Files:**
- Modify: `Sources/KeilAssembler/Parser/Parser.swift` — replace the `parseDirective` stub
- Test: `Tests/KeilAssemblerTests/ParserTests.swift`

**Interfaces:**
- Consumes: `Directive`, `AreaKind`, `Expression`, the `Parser` cursor helpers from Task 5.
- Produces: `Parser.parseExpression(into:) -> Expression?`, used by Tasks 7 and 8.

- [ ] **Step 1: Write the failing test**

Append to `Tests/KeilAssemblerTests/ParserTests.swift`:

```swift
@Test func parserReadsAnAreaDirective() {
    let (program, bag) = parse("    AREA PROGRAM, CODE, READONLY\n")
    #expect(bag.diagnostics.isEmpty)
    #expect(program.lines[0].statement == .directive(
        .area(name: "PROGRAM", kind: .code, readOnly: true, alignment: 2)
    ))
}

@Test func parserReadsDataDefinitionsWithLabels() {
    let (program, bag) = parse("VALUE1 DCD &00000012\n")
    #expect(bag.diagnostics.isEmpty)
    #expect(program.lines[0].label == "VALUE1")
    #expect(program.lines[0].statement == .directive(.defineWords([.integer(0x12)])))
}

@Test func parserAcceptsTheStrayCommaAfterDCDWithW002() {
    // Spec §11 Q1: the lab source writes `VALUE1 DCD, &00000012`.
    let (program, bag) = parse("VALUE1 DCD, &00000012\n")
    #expect(bag.hasErrors == false)
    #expect(bag.diagnostics.map(\.code) == ["W002"])
    #expect(program.lines[0].statement == .directive(.defineWords([.integer(0x12)])))
}

@Test func parserReadsEntryEndAndEqu() {
    let (program, bag) = parse("    ENTRY\nSIZE EQU 4\n    END\n")
    #expect(bag.diagnostics.isEmpty)
    #expect(program.lines[0].statement == .directive(.entry))
    #expect(program.lines[1].statement == .directive(.equ(symbol: "SIZE", value: .integer(4))))
    #expect(program.lines[2].statement == .directive(.end))
}

@Test func parserRejectsAnUnsupportedDirective() {
    let (_, bag) = parse("    MACRO\n")
    #expect(bag.diagnostics.map(\.code) == ["E013"])
}
```

`MACRO` is not in `directiveNames`, so it falls through to the `E013` branch already written in Task 5. Spec §5 assigns `E010` to unsupported *directives*; the parser cannot tell a mis-typed mnemonic from an unsupported directive, so the reserved-word list below promotes the known ones to `E010`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ParserTests`
Expected: FAIL — `parseDirective` returns nil, so `statement` is nil.

- [ ] **Step 3: Replace `parseDirective` in `Parser.swift`**

```swift
    private mutating func parseDirective(label: String?, into diagnostics: inout DiagnosticBag) -> Statement? {
        guard case .symbol(let text) = peek() else { return nil }
        let range = current.range
        advance()

        switch text.uppercased() {
        case "ENTRY":  return .directive(.entry)
        case "END":    return .directive(.end)
        case "LTORG":  return .directive(.ltorg)

        case "EQU":
            // `sym EQU expr` names the constant with the line's label, so EQU is the
            // one directive whose meaning depends on the label having been parsed.
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

        if values.isEmpty {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E009",
                message: "data directive needs at least one value",
                range: range, note: nil
            ))
        }

        // A list that stops before the end of the line means a comma is missing.
        // Without this, `DCD 1 2` silently emits only the 1, and the orphaned 2
        // resurfaces as a bogus top-level statement with a misleading E006 (PRD S3).
        if peek() != .endOfLine, peek() != .endOfFile {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E039",
                message: "expected ',' between data-list values",
                range: current.range, note: nil
            ))
            skipToEndOfLine()
        }
        return values
    }
```

- [ ] **Step 4: Add the expression parser to `Parser.swift`**

Spec §5.1 precedence, lowest binding first. Written as a precedence-climbing chain so each level is one small function.

```swift
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
```

Spec §5.1 lists unary `~` for bitwise NOT; the lexer has no `~` token, and ARMASM spells it `:NOT:` or `^`. `^` is used here, matching the punctuation table in Spec §4.

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter ParserTests`
Expected: PASS, 9 tests.

- [ ] **Step 6: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler/Parser Tests/KeilAssemblerTests/ParserTests.swift
git commit -m "feat: parse directives and expressions, accepting the DCD comma quirk (W002)"
```

---

### Task 7: Parse instructions and Operand2

**Files:**
- Modify: `Sources/KeilAssembler/Parser/Parser.swift` — replace the `parseInstruction` stub
- Test: `Tests/KeilAssemblerTests/ParserTests.swift`

**Interfaces:**
- Consumes: `Mnemonic.decompose`, `Operand`, `Operand2`, `ShiftSpec`, `parseExpression`.
- Produces: `Parser.parseOperand2(into:) -> Operand2?`, used by Task 8 for shifted register offsets.

- [ ] **Step 1: Write the failing test**

Append to `Tests/KeilAssemblerTests/ParserTests.swift`:

```swift
private func firstInstruction(_ source: String) -> Instruction? {
    let (program, _) = parse(source)
    guard case .instruction(let instruction)? = program.lines.first?.statement else { return nil }
    return instruction
}

@Test func parserReadsAnImmediateMove() {
    let instruction = firstInstruction("    MOV R1, #0x12\n")
    #expect(instruction?.mnemonic == .mov)
    #expect(instruction?.condition == .al)
    #expect(instruction?.setsFlags == false)
    #expect(instruction?.operands == [.register(1), .operand2(.immediate(.integer(0x12)))])
}

@Test func parserReadsAThreeOperandAdd() {
    let instruction = firstInstruction("    ADD R4, R1, R2\n")
    #expect(instruction?.operands == [.register(4), .register(1), .operand2(.register(2))])
}

@Test func parserKeepsShiftsInOperand2NotInTheMnemonic() {
    // Spec §6.2: MOV R3, R1, LSL #2 is MOV with a shifted second operand.
    let instruction = firstInstruction("    MOV R3, R1, LSL #2\n")
    #expect(instruction?.mnemonic == .mov)
    #expect(instruction?.operands == [
        .register(3),
        .operand2(.shifted(register: 1, shift: ShiftSpec(kind: .lsl, amount: .integer(2)))),
    ])
}

@Test func parserSplitsConditionAndFlagSuffixes() {
    #expect(firstInstruction("    MOVS R3, #0\n")?.setsFlags == true)
    #expect(firstInstruction("    MOVEQ R3, R1\n")?.condition == .eq)
    let both = firstInstruction("    ADDEQS R1, R2, R3\n")
    #expect(both?.mnemonic == .add)
    #expect(both?.condition == .eq)
    #expect(both?.setsFlags == true)
}

@Test func parserReadsShiftByRegister() {
    let instruction = firstInstruction("    MOV R3, R1, LSR R2\n")
    #expect(instruction?.operands == [
        .register(3),
        .operand2(.shifted(register: 1, shift: ShiftSpec(kind: .lsr, amountRegister: 2))),
    ])
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ParserTests`
Expected: FAIL — the stub returns an instruction with `operands == []`.

- [ ] **Step 3: Replace `parseInstruction` in `Parser.swift`**

```swift
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

        // The loop above ends whenever the next token is not a comma — which means
        // "done" and "a required comma is missing" look identical to it. Without this
        // check, `MOV R1 R2` yields a one-operand instruction with no diagnostic, and
        // the orphaned R2 resurfaces as a phantom second statement (PRD S3).
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

        // A bare register is either a destination/source register or the start of an
        // Operand2 with a shift. Note the shift clause is `Rm, LSL #2` — the comma sits
        // between them — so looking at the token immediately after the register finds a
        // comma, never the shift word. `registerIsTrailingOperand2` looks past it.
        if case .register(let number) = peek() {
            if registerIsTrailingOperand2() {
                guard let operand2 = parseOperand2(into: &diagnostics) else { return nil }
                return .operand2(operand2)
            }
            advance()
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

    /// True when the register at the cursor begins a shifted Operand2 rather than
    /// standing alone. Every unrecognised follower returns false: an unconditional
    /// `default: true` would swallow `MOV R1 R2`'s first register into Operand2 and
    /// silently drop the second.
    private func registerIsTrailingOperand2() -> Bool {
        switch peek(1) {
        case .comma:
            // `Rm, LSL #2` — the shift word sits one token past the comma.
            if case .symbol(let word) = peek(2) { return ShiftKind(text: word) != nil }
            return false
        case .symbol(let word):
            return ShiftKind(text: word) != nil
        case .endOfLine, .endOfFile:
            return true
        default:
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
```

The shift-detection lookahead in `parseOperand` means `ADD R4, R1, R2` yields `.register(4), .register(1), .operand2(.register(2))`: the first two operands are bare registers, and the trailing one is reached through `parseOperand2` only when a shift follows. Task 15's lowering treats a trailing `.register` and a trailing `.operand2(.register)` identically, so both spellings work.

- [ ] **Step 4: Add stubs for Task 8 so the file compiles**

```swift
    private mutating func parseAddressMode(into diagnostics: inout DiagnosticBag) -> AddressMode? {
        skipToEndOfLine()
        return nil
    }

    private mutating func parseRegisterList(into diagnostics: inout DiagnosticBag) -> [Int]? {
        skipToEndOfLine()
        return nil
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter ParserTests`
Expected: PASS, 14 tests.

- [ ] **Step 6: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler/Parser Tests/KeilAssemblerTests/ParserTests.swift
git commit -m "feat: parse instructions, condition/flag suffixes, and Operand2 shifts"
```

---

### Task 8: Parse addressing modes and register lists

**Files:**
- Modify: `Sources/KeilAssembler/Parser/Parser.swift` — replace the two stubs from Task 7
- Test: `Tests/KeilAssemblerTests/ParserTests.swift`

**Interfaces:**
- Consumes: `AddressMode`, `ShiftSpec`, `parseExpression`.
- Produces: complete `AddressMode` and `.registerList` parsing for Task 16's memory lowering.

- [ ] **Step 1: Write the failing test**

Append to `Tests/KeilAssemblerTests/ParserTests.swift`:

```swift
@Test func parserReadsTheThreeLDRFormsDistinctly() {
    // Spec §7.6: these must not be conflated.
    #expect(firstInstruction("    LDR R1, VALUE\n")?.operands == [
        .register(1), .address(.label("VALUE")),
    ])
    #expect(firstInstruction("    LDR R1, =0x3000F000\n")?.operands == [
        .register(1), .immediateValue(.integer(0x3000_F000)),
    ])
    #expect(firstInstruction("    ADR R1, VALUE\n")?.operands == [
        .register(1), .labelReference("VALUE"),
    ])
}

@Test func parserReadsIndirectAndOffsetAddressing() {
    #expect(firstInstruction("    LDR R3, [R1]\n")?.operands == [
        .register(3),
        .address(.immediateOffset(base: 1, offset: nil, negated: false, writeBack: false)),
    ])
    #expect(firstInstruction("    LDR R3, [R1, #4]\n")?.operands == [
        .register(3),
        .address(.immediateOffset(base: 1, offset: .integer(4), negated: false, writeBack: false)),
    ])
    #expect(firstInstruction("    STR R3, [R1, #-8]!\n")?.operands == [
        .register(3),
        .address(.immediateOffset(base: 1, offset: .integer(8), negated: true, writeBack: true)),
    ])
    #expect(firstInstruction("    LDR R3, [R1], #4\n")?.operands == [
        .register(3),
        .address(.postIndexed(base: 1, offset: .integer(4), negated: false)),
    ])
}

@Test func parserReadsScaledRegisterOffsets() {
    #expect(firstInstruction("    LDR R3, [R1, R2, LSL #2]\n")?.operands == [
        .register(3),
        .address(.registerOffset(
            base: 1, offset: 2, negated: false,
            shift: ShiftSpec(kind: .lsl, amount: .integer(2)), writeBack: false
        )),
    ])
}

@Test func parserReadsRegisterLists() {
    #expect(firstInstruction("    PUSH {R1, R4, R14}\n")?.operands == [.registerList([1, 4, 14])])
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ParserTests`
Expected: FAIL — the stubs return nil, so `operands` stops after the destination register.

- [ ] **Step 3: Replace the stubs in `Parser.swift`**

```swift
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
            // The sign follows the hash: ARM writes `[Rn], #-4`, and the lexer emits
            // `#`, `-`, `8` as three separate tokens. Reading the sign first would
            // always see the hash, leave `negated` false, and let parseExpression's
            // own unary-minus swallow the sign into the expression instead.
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

        // `[Rn, #±off]{!}` — the sign follows the hash, so the hash is matched first.
        // For the register-offset form below the sign genuinely comes first (`[Rn, -R3]`),
        // which is why `parseOffsetSign` is called twice rather than hoisted.
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

        // `[Rn, ±Rm{, <shift> #k}]{!}` — here the sign really does precede the register.
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

        guard match(.rightBrace) else {
            diagnostics.emit(Diagnostic(
                severity: .error, code: "E030",
                message: "expected '}'",
                range: current.range, note: nil
            ))
            return nil
        }
        // Spec §6.3: lists are stored lowest-register-at-lowest-address, so order is
        // normalised here and the lowering can walk the array directly.
        return registers.sorted()
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter ParserTests`
Expected: PASS, 18 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler/Parser Tests/KeilAssemblerTests/ParserTests.swift
git commit -m "feat: parse addressing modes, the three LDR forms, and register lists"
```

---

### Task 9: Expression evaluator

**Files:**
- Create: `Sources/KeilAssembler/Analysis/ExpressionEvaluator.swift`
- Test: `Tests/KeilAssemblerTests/AnalyserTests.swift`

**Interfaces:**
- Consumes: `Expression`, `Diagnostic`, `SourceRange`.
- Produces: `SymbolTable` with `constants: [String: UInt32]`, `labels: [String: UInt32]`, `lookup(_:) -> UInt32?`; `ExpressionEvaluator.evaluate(_:symbols:here:range:diagnostics:) -> UInt32?`.

- [ ] **Step 1: Write the failing test**

`Tests/KeilAssemblerTests/AnalyserTests.swift`:

```swift
import Testing
@testable import KeilAssembler

private func evaluate(_ expression: Expression, symbols: SymbolTable = SymbolTable()) -> UInt32? {
    var bag = DiagnosticBag()
    return ExpressionEvaluator.evaluate(
        expression, symbols: symbols, here: 0,
        range: SourceRange(line: 0, column: 0, length: 0),
        diagnostics: &bag
    )
}

@Test func evaluatorAppliesArithmeticWithWrapping() {
    #expect(evaluate(.binary(.add, .integer(0x12), .integer(0x15))) == 0x27)
    #expect(evaluate(.binary(.subtract, .integer(0), .integer(1))) == 0xFFFF_FFFF)
    #expect(evaluate(.unary(.not, .integer(0x12))) == 0xFFFF_FFED)
}

@Test func evaluatorResolvesSymbolsAndLabels() {
    var symbols = SymbolTable()
    symbols.constants["SIZE"] = 4
    symbols.labels["VALUE"] = 0x8000
    #expect(evaluate(.symbol("SIZE"), symbols: symbols) == 4)
    #expect(evaluate(.binary(.add, .symbol("VALUE"), .symbol("SIZE")), symbols: symbols) == 0x8004)
}

@Test func evaluatorReportsAnUnknownSymbol() {
    var bag = DiagnosticBag()
    let value = ExpressionEvaluator.evaluate(
        .symbol("NOPE"), symbols: SymbolTable(), here: 0,
        range: SourceRange(line: 2, column: 4, length: 4),
        diagnostics: &bag
    )
    #expect(value == nil)
    #expect(bag.diagnostics.map(\.code) == ["E031"])
}

@Test func evaluatorRejectsDivisionByZero() {
    var bag = DiagnosticBag()
    let value = ExpressionEvaluator.evaluate(
        .binary(.divide, .integer(1), .integer(0)), symbols: SymbolTable(), here: 0,
        range: SourceRange(line: 0, column: 0, length: 1),
        diagnostics: &bag
    )
    #expect(value == nil)
    #expect(bag.diagnostics.map(\.code) == ["E032"])
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AnalyserTests`
Expected: FAIL with `cannot find 'SymbolTable' in scope`.

- [ ] **Step 3: Write `ExpressionEvaluator.swift`**

```swift
/// Spec §5.2: labels resolve to ARM7 addresses; EQU symbols are compile-time constants.
struct SymbolTable: Sendable {
    var constants: [String: UInt32] = [:]
    var labels: [String: UInt32] = [:]

    init() {}

    func lookup(_ name: String) -> UInt32? {
        constants[name] ?? labels[name]
    }
}

/// Spec §5.1. Integer only, 32-bit wrapping.
enum ExpressionEvaluator {
    static func evaluate(
        _ expression: Expression,
        symbols: SymbolTable,
        here: UInt32,
        range: SourceRange,
        diagnostics: inout DiagnosticBag
    ) -> UInt32? {
        switch expression {
        case .integer(let value):
            return value

        case .here:
            return here

        case .symbol(let name):
            guard let value = symbols.lookup(name) else {
                diagnostics.emit(Diagnostic(
                    severity: .error, code: "E031",
                    message: "'\(name)' is not defined",
                    range: range,
                    note: "define it with a label or an EQU directive"
                ))
                return nil
            }
            return value

        case .unary(let op, let operand):
            guard let value = evaluate(operand, symbols: symbols, here: here, range: range, diagnostics: &diagnostics) else {
                return nil
            }
            switch op {
            case .plus:  return value
            case .minus: return 0 &- value
            case .not:   return ~value
            }

        case .binary(let op, let leftExpression, let rightExpression):
            guard let left = evaluate(leftExpression, symbols: symbols, here: here, range: range, diagnostics: &diagnostics),
                  let right = evaluate(rightExpression, symbols: symbols, here: here, range: range, diagnostics: &diagnostics) else {
                return nil
            }
            switch op {
            case .multiply:    return left &* right
            case .add:         return left &+ right
            case .subtract:    return left &- right
            case .and:         return left & right
            case .or:          return left | right
            case .exclusiveOr: return left ^ right
            case .shiftLeft:   return right >= 32 ? 0 : left << right
            case .shiftRight:  return right >= 32 ? 0 : left >> right
            case .divide, .modulo:
                guard right != 0 else {
                    diagnostics.emit(Diagnostic(
                        severity: .error, code: "E032",
                        message: "division by zero",
                        range: range, note: nil
                    ))
                    return nil
                }
                return op == .divide ? left / right : left % right
            }
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter AnalyserTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler/Analysis Tests/KeilAssemblerTests/AnalyserTests.swift
git commit -m "feat: 32-bit wrapping expression evaluator with symbol resolution"
```

---

### Task 10: Analyser — area layout, ARM7 addresses, data image

**Files:**
- Create: `Sources/KeilAssembler/Analysis/Analyser.swift`
- Test: `Tests/KeilAssemblerTests/AnalyserTests.swift`

**Interfaces:**
- Consumes: `Program`, `Line`, `Directive`, `SymbolTable`, `ExpressionEvaluator`.
- Produces: `ImageBlob(address:bytes:)`; `AnalysedProgram` with `program`, `symbols`, `dataImage: [ImageBlob]`, `entryLineIndex: Int?`, `addresses: [Int: UInt32]` (index into `program.lines` → ARM7 address); `Analyser.analyse(_:into:) -> AnalysedProgram`; constants `Analyser.origin = 0x0000_8000`, `Analyser.stackTop = 0x0010_0000`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/KeilAssemblerTests/AnalyserTests.swift`:

```swift
private func analyse(_ source: String) -> (AnalysedProgram, DiagnosticBag) {
    var bag = DiagnosticBag()
    let tokens = Lexer(source: source).tokenize(into: &bag)
    let program = Parser(tokens: tokens).parse(into: &bag)
    return (Analyser.analyse(program, into: &bag), bag)
}

@Test func analyserAssignsFourBytesPerInstruction() {
    let (analysed, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #0x12
        MOV R2, R1
    """)
    #expect(bag.hasErrors == false)
    #expect(analysed.symbols.labels["MAIN"] == Analyser.origin)
    // MAIN labels the first instruction; the second sits one word later.
    let instructionAddresses = analysed.addresses.values.sorted()
    #expect(instructionAddresses == [Analyser.origin, Analyser.origin + 4])
}

@Test func analyserBuildsADataImageFromDCD() {
    let (analysed, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
        AREA STORAGE, DATA, READONLY
    VALUE1 DCD &00000012
    VALUE2 DCD &00000013
    """)
    #expect(bag.hasErrors == false)
    let value1 = analysed.symbols.labels["VALUE1"]!
    #expect(analysed.symbols.labels["VALUE2"] == value1 + 4)
    // Little-endian, Spec §3.
    let blob = analysed.dataImage.first { $0.address == value1 }
    #expect(blob?.bytes == [0x12, 0x00, 0x00, 0x00])
}

@Test func analyserWarnsWhenAnAreaNameIsReused() {
    // Spec §11 Q4: the labs declare PROGRAM as both CODE and DATA.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
        AREA PROGRAM, DATA, READONLY
    VALUE DCD &12
    """)
    #expect(bag.hasErrors == false)
    #expect(bag.diagnostics.contains { $0.code == "W004" })
}

@Test func analyserRequiresExactlyOneEntry() {
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
    MAIN
        MOV R1, #1
    """)
    #expect(bag.diagnostics.map(\.code).contains("E033"))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AnalyserTests`
Expected: FAIL with `cannot find 'Analyser' in scope`.

- [ ] **Step 3: Write `Analyser.swift`**

```swift
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
            /// Index into `program.lines` → the ARM7 address of that line's data.
            /// Recorded here in pass 1 so pass 2 never has to re-derive the layout,
            /// and so unlabelled data directives are addressable too.
            var dataAddresses: [Int: UInt32] = [:]
            var entryLineIndex: Int?
            var seenAreaNames: Set<String> = []
            var position = origin
            var inCodeArea = true

            // Pass 0 — EQU pre-pass. `SPACE n` and `ALIGN n` are evaluated during
            // layout, so any constant they name must already be bound. Diagnostics go
            // to a scratch bag that is thrown away: an EQU whose expression references
            // a label legitimately cannot resolve yet, and must not error here. Pass 1b
            // re-evaluates every EQU against the real bag once labels are bound, so a
            // genuinely undefined symbol is still reported exactly once.
            for line in program.lines {
                if case .directive(.equ(let symbol, let value))? = line.statement {
                    var scratch = DiagnosticBag()
                    if let resolved = ExpressionEvaluator.evaluate(
                        value, symbols: symbols, here: 0, range: line.range, diagnostics: &scratch
                    ) {
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
                        if let label = line.label { symbols.labels[label] = position }
                        dataAddresses[index] = position
                        position &+= UInt32(values.count)
                        continue

                    case .defineHalfwords(let values):
                        position = align(position, to: 2)
                        if let label = line.label { symbols.labels[label] = position }
                        dataAddresses[index] = position
                        position &+= UInt32(values.count * 2)
                        continue

                    case .defineWords(let values):
                        position = align(position, to: 4)
                        if let label = line.label { symbols.labels[label] = position }
                        dataAddresses[index] = position
                        position &+= UInt32(values.count * 4)
                        continue

                    case .space(let size):
                        if let label = line.label { symbols.labels[label] = position }
                        dataAddresses[index] = position
                        if let count = ExpressionEvaluator.evaluate(size, symbols: symbols, here: position, range: line.range, diagnostics: &bag) {
                            position &+= count
                        }
                        continue

                    case .equ:
                        // `sym EQU expr` carries the line's label, and the constant is
                        // bound in pass 1b. Falling through to the generic label binding
                        // below would also register the name in `symbols.labels`, which
                        // then trips the cross-dictionary collision check.
                        continue

                    case .end, .ltorg, .export:
                        break
                    }
                }

                if let label = line.label, symbols.labels[label] == nil {
                    symbols.labels[label] = position
                }

                if case .instruction? = line.statement {
                    guard inCodeArea else {
                        bag.emit(Diagnostic(
                            severity: .error, code: "E035",
                            message: "instruction appears in a DATA area",
                            range: line.range, note: nil
                        ))
                        continue
                    }
                    addresses[index] = position
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

            // Pass 1b — EQU constants, now that labels are bound. The pre-pass's entries
            // are cleared first: leaving them would make every ordinary EQU look like a
            // redefinition of itself and emit a spurious duplicate-symbol error.
            symbols.constants = [:]
            for line in program.lines {
                if case .directive(.equ(let symbol, let value))? = line.statement {
                    if let resolved = ExpressionEvaluator.evaluate(value, symbols: symbols, here: 0, range: line.range, diagnostics: &bag) {
                        symbols.constants[symbol] = resolved
                    }
                }
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

    private static func align(_ value: UInt32, to boundary: UInt32) -> UInt32 {
        guard boundary > 1 else { return value }
        let remainder = value % boundary
        return remainder == 0 ? value : value &+ (boundary - remainder)
    }
}
```

Because pass 1 records `dataAddresses[index]` for every data directive — labelled or
not — pass 2 never re-derives the layout, and unlabelled `DCB`/`DCW`/`DCD`/`SPACE`
reach the data image too.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter AnalyserTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler/Analysis Tests/KeilAssemblerTests/AnalyserTests.swift
git commit -m "feat: area layout, ARM7 address assignment, and data image construction"
```

---

### Task 11: Analyser — semantic diagnostics

**Files:**
- Modify: `Sources/KeilAssembler/Analysis/Analyser.swift`
- Test: `Tests/KeilAssemblerTests/AnalyserTests.swift`

**Interfaces:**
- Consumes: `AnalysedProgram`, `Instruction`, `Operand2`.
- Produces: `Analyser.isEncodableModifiedImmediate(_:) -> Bool`, used by Task 14's immediate materialisation to decide nothing — it is a diagnostic-only check, per Spec §6.2.

- [ ] **Step 1: Write the failing test**

Append to `Tests/KeilAssemblerTests/AnalyserTests.swift`:

```swift
@Test func modifiedImmediateEncodingMatchesARM7Rules() {
    // 8-bit value rotated right by an even amount.
    #expect(Analyser.isEncodableModifiedImmediate(0x12))
    #expect(Analyser.isEncodableModifiedImmediate(0xFF))
    #expect(Analyser.isEncodableModifiedImmediate(0x3F00))       // 0xFC ror 30
    #expect(Analyser.isEncodableModifiedImmediate(0xFF00_0000))
    #expect(Analyser.isEncodableModifiedImmediate(0x101) == false)
    #expect(Analyser.isEncodableModifiedImmediate(0x1FE) == false)
}

@Test func analyserRejectsAnUnencodableImmediate() {
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #0x101
    """)
    #expect(bag.diagnostics.map(\.code).contains("E020"))
    #expect(bag.hasErrors)
}

@Test func analyserWarnsAboutUnmodelledShifterCarry() {
    // Spec §9 D1.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOVS R3, R1, LSL #2
    """)
    #expect(bag.hasErrors == false)
    #expect(bag.diagnostics.map(\.code).contains("W010"))
}

@Test func analyserRejectsReadingR15AsData() {
    // Spec §9 D2.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        ADD R1, R15, #4
    """)
    #expect(bag.diagnostics.map(\.code).contains("E021"))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AnalyserTests`
Expected: FAIL with `type 'Analyser' has no member 'isEncodableModifiedImmediate'`.

- [ ] **Step 3: Add the checks to `Analyser.swift`**

```swift
extension Analyser {
    /// Spec §9 D1 applies only where C comes from the barrel shifter. ADDS/SUBS/CMP/CMN
    /// take C and V from the ALU and match ARM7 exactly.
    static let shifterCarryMnemonics: Set<Mnemonic> = [.mov, .mvn, .and, .orr, .eor, .bic, .tst, .teq]

    /// Spec §6.2 / [ARMARM]: an 8-bit value rotated right by an even amount.
    /// Enforced as a diagnostic even though the emitted AArch64 has no such
    /// restriction — the transpiler must not accept what real armasm rejects.
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
        // Spec §7.5 lowers `MOV PC, LR` as a return, so that one form must survive the
        // R15 check below. `MOVS PC, LR` must not: on ARM7 it also restores CPSR from
        // SPSR, which Spec §9 D6 says this transpiler does not model at all.
        let isReturnIdiom = instruction.mnemonic == .mov
            && !instruction.setsFlags
            && instruction.operands.count == 2
            && instruction.operands[0] == .register(15)
            && (instruction.operands[1] == .register(14)
                || instruction.operands[1] == .operand2(.register(14)))

        for operand in instruction.operands {
            switch operand {
            case .register(15) where !isReturnIdiom:
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

            case .operand2(.shifted(let shiftBase, let shift)):
                if shiftBase == 15 || shift.amountRegister == 15 {
                    // A register supplying a shift count is read as data, so D2 applies
                    // to it exactly as it does to the shifted register itself.
                    diagnostics.emit(Diagnostic(
                        severity: .error, code: "E021",
                        message: "R15 cannot be used as a data operand",
                        range: instruction.range,
                        note: "Spec §9 D2: R15 holds a synthetic address for display only"
                    ))
                }
                // Spec §9 D1 covers only the instructions whose C comes from the barrel
                // shifter. ADDS/SUBS/CMP/CMN take C and V from the ALU and match ARM7
                // exactly, so warning on them would be false and would teach the user
                // to ignore W010.
                if instruction.setsFlags, Self.shifterCarryMnemonics.contains(instruction.mnemonic) {
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

            default:
                break
            }
        }

        // Spec §7.5 lowers only `BX LR`; any other register is a computed branch.
        // Note the parser yields `BX`'s operand as `.operand2(.register(n))`, never a
        // bare `.register(n)`, because a trailing register goes through parseOperand2 —
        // matching on `.register` here would make this check dead.
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
```

- [ ] **Step 4: Call `check` from `analyse`**

In the pass-1 instruction branch of `analyse`, after `addresses[index] = position`:

```swift
                    if case .instruction(let instruction)? = line.statement {
                        checkQueue.append((instruction, position))
                    }
```

Declare `var checkQueue: [(Instruction, UInt32)] = []` next to `addresses`, and run it after pass 1b so symbols are bound:

```swift
            for (instruction, address) in checkQueue {
                check(instruction, symbols: symbols, address: address, diagnostics: &bag)
            }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter AnalyserTests`
Expected: PASS, 12 tests.

- [ ] **Step 6: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler/Analysis Tests/KeilAssemblerTests/AnalyserTests.swift
git commit -m "feat: semantic diagnostics for immediates, R15, shifter carry, and shift range"
```

---

### Task 12: Startup image encoder

**Files:**
- Create: `Sources/KeilAssembler/Runtime/StartupImage.swift`
- Test: `Tests/KeilAssemblerTests/StartupImageTests.swift`

**Interfaces:**
- Consumes: `ImageBlob`.
- Produces: `MemoryPreload(entries:)` with `entries: [(address: UInt32, bytes: [UInt8])]`; `StartupImage.encode(dataImage:preload:) -> Data`. Task 17's `armd_rt.c` decodes exactly this format; Task 18's driver writes it to `image.bin`.

- [ ] **Step 1: Write the failing test**

`Tests/KeilAssemblerTests/StartupImageTests.swift`:

```swift
import Foundation
import Testing
@testable import KeilAssembler

private func words(_ data: Data) -> [UInt32] {
    stride(from: 0, to: data.count, by: 4).map { offset in
        data[offset..<offset + 4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

@Test func encoderWritesAddressLengthAndPaddedBytes() {
    let data = StartupImage.encode(
        dataImage: [ImageBlob(address: 0x8000, bytes: [0x12, 0x00, 0x00, 0x00])],
        preload: MemoryPreload()
    )
    #expect(words(data) == [0x8000, 4, 0x12])
}

@Test func encoderPadsShortBlobsToAFourByteBoundary() {
    let data = StartupImage.encode(
        dataImage: [ImageBlob(address: 0x8000, bytes: [0xAA])],
        preload: MemoryPreload()
    )
    // header (2 words) + 1 byte padded to one word
    #expect(data.count == 12)
    #expect(words(data) == [0x8000, 1, 0x0000_00AA])
}

@Test func preloadBlobsFollowTheDataImageSoTheyWin() {
    // Spec §5.3: later blobs overwrite earlier ones.
    let data = StartupImage.encode(
        dataImage: [ImageBlob(address: 0x1000, bytes: [1, 0, 0, 0])],
        preload: MemoryPreload(entries: [(address: 0x1000, bytes: [2, 0, 0, 0])])
    )
    #expect(words(data) == [0x1000, 4, 1, 0x1000, 4, 2])
}

@Test func encoderProducesAnEmptyImageWhenThereIsNothingToLoad() {
    #expect(StartupImage.encode(dataImage: [], preload: MemoryPreload()).isEmpty)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter StartupImageTests`
Expected: FAIL with `cannot find 'StartupImage' in scope`.

- [ ] **Step 3: Write `StartupImage.swift`**

```swift
import Foundation

/// Spec §5.3. Memory contents supplied by the client rather than by the source —
/// how the lab's Memory-window values are expressed.
struct MemoryPreload: Sendable {
    var entries: [(address: UInt32, bytes: [UInt8])]

    init(entries: [(address: UInt32, bytes: [UInt8])] = []) {
        self.entries = entries
    }

    /// Convenience for the common case: one 32-bit word at one address.
    init(words: [UInt32: UInt32]) {
        entries = words.sorted { $0.key < $1.key }.map { address, value in
            (address, (0...3).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) })
        }
    }
}

/// Spec §5.3 blob format:
///   `u32 arm7Address · u32 byteCount · byteCount bytes · zero-pad to 4 bytes`
enum StartupImage {
    static func encode(dataImage: [ImageBlob], preload: MemoryPreload) -> Data {
        var data = Data()
        for blob in dataImage {
            append(address: blob.address, bytes: blob.bytes, to: &data)
        }
        for entry in preload.entries {
            append(address: entry.address, bytes: entry.bytes, to: &data)
        }
        PerfLog.info("startup image: \(dataImage.count) data blobs, \(preload.entries.count) preload blobs, \(data.count) bytes")
        return data
    }

    private static func append(address: UInt32, bytes: [UInt8], to data: inout Data) {
        guard !bytes.isEmpty else { return }
        appendWord(address, to: &data)
        appendWord(UInt32(bytes.count), to: &data)
        data.append(contentsOf: bytes)
        let padding = (4 - bytes.count % 4) % 4
        data.append(contentsOf: Array(repeating: 0, count: padding))
    }

    private static func appendWord(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter StartupImageTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler/Runtime Tests/KeilAssemblerTests/StartupImageTests.swift
git commit -m "feat: startup image encoder for data and preload blobs"
```

---

### Task 13: Assembly builder and emitter primitives

**Files:**
- Create: `Sources/KeilAssembler/Backend/AssemblyBuilder.swift`
- Create: `Sources/KeilAssembler/Backend/Emitter.swift`
- Test: `Tests/KeilAssemblerTests/LoweringTests.swift`

**Interfaces:**
- Consumes: `Analyser.origin`, `SourceRange`.
- Produces: `AssemblyBuilder` with `comment(_:)`, `label(_:)`, `instruction(_:)`, `directive(_:)`, `text`; `Emitter` with `cpsrOffset = 0x40`, `loadRegister(_:into:_:)`, `storeRegister(_:from:_:)`, `materialiseImmediate(_:into:_:)`, `saveFlags(into:)`, `restoreFlags(into:)`, `prologue(entryLabel:into:)`, `epilogue(into:)`, `armLabel(_:)`, `trace(line:storeAddressRegister:storeWidth:into:)`. Used verbatim by Tasks 14–16. `prologue` needs `entryLabel` to emit §7.9's `b Lentry`; there is no one-argument form.

- [ ] **Step 1: Write the failing test**

`Tests/KeilAssemblerTests/LoweringTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter LoweringTests`
Expected: FAIL with `cannot find 'AssemblyBuilder' in scope`.

- [ ] **Step 3: Write `AssemblyBuilder.swift`**

```swift
/// Accumulates Darwin `.s` text. Labels sit at column 0, everything else is indented,
/// which keeps the emitted file readable — PRD G6 makes that a product goal.
struct AssemblyBuilder {
    private var lines: [String] = []

    init() {}

    mutating func label(_ name: String) { lines.append("\(name):") }
    mutating func instruction(_ text: String) { lines.append("        \(text)") }
    mutating func directive(_ text: String) { lines.append("        \(text)") }
    mutating func comment(_ text: String) { lines.append("        ; \(text)") }
    mutating func blankLine() { lines.append("") }

    var text: String { lines.map { $0 + "\n" }.joined() }
}
```

- [ ] **Step 4: Write `Emitter.swift`**

```swift
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
    /// `radix` affects only the text: `as` assembles `#0x7` and `#7` identically.
    /// Operand2 values read better in hex, line numbers and widths in decimal.
    static func materialiseImmediate(
        _ value: UInt32, into hostRegister: String, radix: Int = 16, into builder: inout AssemblyBuilder
    ) {
        let low = value & 0xFFFF
        let high = value >> 16
        let prefix = radix == 16 ? "0x" : ""
        builder.instruction("movz    \(hostRegister), #\(prefix)\(String(low, radix: radix))")
        if high != 0 {
            builder.instruction("movk    \(hostRegister), #\(prefix)\(String(high, radix: radix)), lsl #16")
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
    static func trace(
        line: Int,
        storeAddressRegister: String?,
        storeWidth: Int,
        into builder: inout AssemblyBuilder
    ) {
        materialiseImmediate(UInt32(line), into: "w0", radix: 10, into: &builder)
        if let storeAddressRegister {
            builder.instruction("mov     w1, \(storeAddressRegister)")
            materialiseImmediate(UInt32(storeWidth), into: "w2", radix: 10, into: &builder)
        } else {
            builder.instruction("mov     w1, wzr")
            builder.instruction("mov     w2, wzr")
        }
        builder.instruction("bl      _armd_trace")
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
```

`materialiseImmediate` skips the `movk` when the high half is zero, so the test's `movz w0, #7` expectation holds and small immediates cost one instruction. Spec §7.4's table shows both unconditionally; emitting only the needed half is identical in effect because `movz` zeroes the rest of the register.

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter LoweringTests`
Expected: PASS, 5 tests.

- [ ] **Step 6: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler/Backend Tests/KeilAssemblerTests/LoweringTests.swift
git commit -m "feat: assembly builder and AArch64 emitter primitives"
```

---

### Task 14: Operand2 materialisation

**Files:**
- Create: `Sources/KeilAssembler/Backend/Lowering.swift`
- Test: `Tests/KeilAssemblerTests/LoweringTests.swift`

**Interfaces:**
- Consumes: `Emitter`, `Operand2`, `ShiftSpec`, `ExpressionEvaluator`, `SymbolTable`.
- Produces: `Lowering.materialiseOperand2(_:symbols:address:range:into:diagnostics:)` which always leaves the value in `w10`; `Lowering.lower(_:into:) -> String?` (stubbed here, completed in Tasks 15–16).

- [ ] **Step 1: Write the failing test**

Append to `Tests/KeilAssemblerTests/LoweringTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter LoweringTests`
Expected: FAIL with `cannot find 'Lowering' in scope`.

- [ ] **Step 3: Write `Lowering.swift`**

```swift
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
                    note: "Spec §9 D1 describes the shifter-carry limitation but never defines the RRX sequence"
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

    /// Pads a mnemonic to 8 columns so the emitted assembly stays readable. The padding
    /// IS the separator — call sites must not add a literal space after it, or every
    /// instruction comes out double-spaced.
    static func pad(_ mnemonic: String) -> String {
        mnemonic.padding(toLength: max(mnemonic.count, 8), withPad: " ", startingAt: 0)
    }
}
```

Spec §7.4's `RRX` row defers to §9 D1, which describes the shifter-carry limitation rather than defining an `adc`-based sequence. `RRX` is therefore diagnosed rather than mis-lowered, per PRD S3. It appears in no corpus program and is a Task for M6.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter LoweringTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler/Backend Tests/KeilAssemblerTests/LoweringTests.swift
git commit -m "feat: lower Operand2 into w10 with fixed and variable shifts"
```

---

### Task 15: Data-processing lowering

**Files:**
- Modify: `Sources/KeilAssembler/Backend/Lowering.swift`
- Test: `Tests/KeilAssemblerTests/LoweringTests.swift`

**Interfaces:**
- Consumes: `Instruction`, `Mnemonic`, `Condition`, `Emitter`, `materialiseOperand2`.
- Produces: `Lowering.lower(_ analysed: AnalysedProgram, into diagnostics: inout DiagnosticBag) -> String?` returning the complete `.s` text, or nil when `diagnostics.hasErrors`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/KeilAssemblerTests/LoweringTests.swift`:

```swift
private func lower(_ source: String) -> (String?, DiagnosticBag) {
    var bag = DiagnosticBag()
    let tokens = Lexer(source: source).tokenize(into: &bag)
    let program = Parser(tokens: tokens).parse(into: &bag)
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter LoweringTests`
Expected: FAIL with `type 'Lowering' has no member 'lower'`.

- [ ] **Step 3: Add `lower` and data-processing emission to `Lowering.swift`**

```swift
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

            for (index, line) in analysed.program.lines.enumerated() {
                if let label = line.label, analysed.symbols.labels[label] != nil {
                    builder.label(Emitter.armLabel(label))
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
            guard case .register(let destination)? = instruction.operands.first,
                  case .register(let multiplicand)? = instruction.operands.dropFirst().first,
                  case .register(let multiplier)? = instruction.operands.dropFirst(2).first else {
                unsupported(instruction, into: &diagnostics); return
            }
            Emitter.loadRegister(multiplicand, into: "w9", into: &builder)
            Emitter.loadRegister(multiplier, into: "w10", into: &builder)
            if instruction.mnemonic == .mla, case .register(let addend)? = instruction.operands.dropFirst(3).first {
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

        default:
            // Memory and branch instructions arrive in Task 16.
            unsupported(instruction, into: &diagnostics)
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

    static func unsupported(_ instruction: Instruction, into diagnostics: inout DiagnosticBag) {
        diagnostics.emit(Diagnostic(
            severity: .error, code: "E013",
            message: "\(instruction.mnemonic.rawValue.uppercased()) with these operands is not supported in this subset",
            range: instruction.range,
            note: "see Spec §6.3"
        ))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter LoweringTests`
Expected: PASS, 14 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler/Backend Tests/KeilAssemblerTests/LoweringTests.swift
git commit -m "feat: lower data-processing instructions with flags and conditional guards"
```

---

### Task 16: Memory and branch lowering

**Files:**
- Modify: `Sources/KeilAssembler/Backend/Lowering.swift`
- Test: `Tests/KeilAssemblerTests/LoweringTests.swift`

**Interfaces:**
- Consumes: `AddressMode`, `Operand.immediateValue`, `Operand.labelReference`, `Emitter.trace`.
- Produces: complete `Lowering.emit` coverage for `ldr`/`str`/`ldrb`/`strb`/`ldrh`/`strh`/`push`/`pop`/`stmfd`/`ldmfd`/`b`/`bl`/`bx`/`adr`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/KeilAssemblerTests/LoweringTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter LoweringTests`
Expected: FAIL — `LDR` falls into the `default` branch and emits `E013`.

- [ ] **Step 3: Add memory and branch cases to `Lowering.emit`**

Replace the `default:` arm of the `switch instruction.mnemonic` with these cases, keeping `default:` for anything still unhandled. Each memory case returns directly because it emits its own trace call carrying the store address.

```swift
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
                // stored lowest-register-at-lowest-address (Spec §6.3).
                builder.instruction("sub     w9, w9, #\(registers.count * 4)")
                Emitter.storeRegister(13, from: "w9", into: &builder)
                for (slot, register) in registers.enumerated() {
                    Emitter.loadRegister(register, into: "w11", into: &builder)
                    builder.instruction("add     w12, w9, #\(slot * 4)")
                    builder.instruction("str     w11, [x28, w12, uxtw]")
                }
                Emitter.trace(line: sourceLine, storeAddressRegister: "w9", storeWidth: 4, into: &builder)
            } else {
                for (slot, register) in registers.enumerated() {
                    builder.instruction("add     w12, w9, #\(slot * 4)")
                    builder.instruction("ldr     w11, [x28, w12, uxtw]")
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
```

Add the two width helpers next to `arithmetic`:

```swift
    static func accessWidth(_ mnemonic: Mnemonic) -> Int {
        switch mnemonic {
        case .ldrb, .strb: 1
        case .ldrh, .strh: 2
        default: 4
        }
    }

    static func widthSuffix(_ width: Int) -> String {
        switch width {
        case 1: "b"
        case 2: "h"
        default: ""
        }
    }
```

The `bl`/`b` cases emit the trace call *before* the branch so the branch stays the last instruction of the block; every other case emits it last.

- [ ] **Step 4: Emit call-target prologues**

Spec §7.5 requires every `BL` target to open a frame. In `lower`, before the emission loop, collect the targets, and emit the frame push when their label is written:

```swift
            let callTargets: Set<String> = Set(analysed.program.lines.compactMap { line in
                guard case .instruction(let instruction)? = line.statement,
                      instruction.mnemonic == .bl,
                      case .labelReference(let name)? = instruction.operands.first else { return nil }
                return name
            })
            // ... and where the label is emitted:
                if let label = line.label, analysed.symbols.labels[label] != nil {
                    builder.label(Emitter.armLabel(label))
                    if callTargets.contains(label) {
                        builder.instruction("stp     x29, x30, [sp, #-16]!")
                    }
                }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter LoweringTests`
Expected: PASS, 19 tests.

- [ ] **Step 6: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler/Backend Tests/KeilAssemblerTests/LoweringTests.swift
git commit -m "feat: lower memory access, the three LDR forms, stack ops, and branches"
```

---

### Task 17: C runtime and trace decoder

**Files:**
- Modify: `Sources/KeilAssembler/Runtime/Resources/armd_rt.c` (replace the placeholder)
- Create: `Sources/KeilAssembler/Trace/TraceDecoder.swift`
- Test: `Tests/KeilAssemblerTests/TraceDecoderTests.swift`

**Interfaces:**
- Consumes: `StartupImage`'s blob format.
- Produces: `MachineSnapshot` with `seq`, `sourceLine`, `pc`, `registers: [UInt32]` (16), `cpsr`, `storeAddress`, `storeValue`, `storeWidth`; `TraceDecoder.decode(_ data: Data) throws -> [MachineSnapshot]`; `TraceDecoder.recordSize = 96`.

- [ ] **Step 1: Write the failing test**

`Tests/KeilAssemblerTests/TraceDecoderTests.swift`:

```swift
import Foundation
import Testing
@testable import KeilAssembler

private func record(seq: UInt32, line: UInt32, r1: UInt32) -> Data {
    var words = [UInt32](repeating: 0, count: 24)
    words[0] = seq
    words[1] = line
    words[2] = 0x8000                 // pc
    words[3 + 1] = r1                 // r[1]
    words[19] = 0                     // cpsr
    var data = Data()
    for word in words {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
        }
    }
    return data
}

@Test func decoderReadsFixedSizeRecords() throws {
    let snapshots = try TraceDecoder.decode(record(seq: 0, line: 3, r1: 0x12) + record(seq: 1, line: 4, r1: 0x27))
    #expect(snapshots.count == 2)
    #expect(snapshots[0].sourceLine == 3)
    #expect(snapshots[0].registers[1] == 0x12)
    #expect(snapshots[1].seq == 1)
    #expect(snapshots[1].registers[1] == 0x27)
    #expect(snapshots[0].pc == 0x8000)
}

@Test func decoderRejectsATruncatedTrace() {
    #expect(throws: TraceDecoder.Failure.self) {
        try TraceDecoder.decode(record(seq: 0, line: 0, r1: 0).dropLast(4))
    }
}

@Test func recordSizeMatchesTheSpec() {
    #expect(TraceDecoder.recordSize == 96)     // Spec §7.7
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TraceDecoderTests`
Expected: FAIL with `cannot find 'TraceDecoder' in scope`.

- [ ] **Step 3: Write `armd_rt.c`**

Replace the placeholder at `Sources/KeilAssembler/Runtime/Resources/armd_rt.c`:

```c
//  armd_rt.c — KeilAssembler runtime. Spec §7.8.
//
//  Linked into every transpiled program. Owns the ARM7 address space, loads the
//  startup image, and appends one trace record per ARM7 instruction.

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#define ARM7_ADDRESS_SPACE (1ULL << 32)   // Spec §7.8: the whole 32-bit space
#define ARM7_STACK_TOP     0x00100000u    // Spec §3

struct ARMdState {          // Spec §7.2 — offsets are normative
    uint32_t r[16];         // 0x00 .. 0x3C
    uint32_t cpsr;          // 0x40
};

struct ARMdTraceRecord {    // Spec §7.7 — 96 bytes
    uint32_t seq;
    uint32_t srcLine;
    uint32_t pc;
    uint32_t r[16];
    uint32_t cpsr;
    uint32_t storeAddr;
    uint32_t storeValue;
    uint32_t storeWidth;
    uint32_t _pad;
};

struct ARMdState armd_state;

static uint8_t *armd_memory;
static FILE *armd_trace_file;
static uint32_t armd_sequence;

/// Loads `image.bin`: repeated (u32 address, u32 length, bytes, pad to 4).
/// Blobs are applied in file order, so later blobs overwrite earlier ones.
static void armd_load_image(void) {
    FILE *file = fopen("image.bin", "rb");
    if (!file) { return; }               // no image is not an error: memory is zero

    uint32_t header[2];
    while (fread(header, sizeof(uint32_t), 2, file) == 2) {
        uint32_t address = header[0];
        uint32_t length  = header[1];
        uint32_t padded  = (length + 3u) & ~3u;

        if ((uint64_t)address + length > ARM7_ADDRESS_SPACE) { break; }
        if (fread(armd_memory + address, 1, length, file) != length) { break; }
        if (padded > length) { fseek(file, (long)(padded - length), SEEK_CUR); }
    }
    fclose(file);
}

void *armd_init(void) {
    armd_memory = mmap(NULL, ARM7_ADDRESS_SPACE, PROT_READ | PROT_WRITE,
                       MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
    if (armd_memory == MAP_FAILED) {
        fprintf(stderr, "armd: could not reserve the ARM7 address space\n");
        return NULL;
    }

    memset(&armd_state, 0, sizeof(armd_state));
    armd_state.r[13] = ARM7_STACK_TOP;

    armd_load_image();
    armd_trace_file = fopen("trace.bin", "wb");
    return armd_memory;
}

void armd_trace(uint32_t line, uint32_t storeAddr, uint32_t storeWidth) {
    if (!armd_trace_file) { return; }

    struct ARMdTraceRecord record;
    memset(&record, 0, sizeof(record));
    record.seq        = armd_sequence++;
    record.srcLine    = line;
    record.pc         = armd_state.r[15];
    record.cpsr       = armd_state.cpsr;
    record.storeAddr  = storeAddr;
    record.storeWidth = storeWidth;
    memcpy(record.r, armd_state.r, sizeof(record.r));

    if (storeWidth == 1)      { record.storeValue = armd_memory[storeAddr]; }
    else if (storeWidth == 2) { uint16_t half; memcpy(&half, armd_memory + storeAddr, 2); record.storeValue = half; }
    else if (storeWidth == 4) { memcpy(&record.storeValue, armd_memory + storeAddr, 4); }

    fwrite(&record, sizeof(record), 1, armd_trace_file);
}

void armd_fini(void) {
    if (armd_trace_file) {
        fflush(armd_trace_file);
        fclose(armd_trace_file);
        armd_trace_file = NULL;
    }
}
```

- [ ] **Step 4: Write `TraceDecoder.swift`**

```swift
import Foundation

/// One ARM7 machine state, as recorded after a single instruction. Spec §7.7.
struct MachineSnapshot: Sendable, Equatable {
    let seq: UInt32
    let sourceLine: Int
    let pc: UInt32
    let registers: [UInt32]     // 16 entries, R0...R15
    let cpsr: UInt32
    let storeAddress: UInt32
    let storeValue: UInt32
    let storeWidth: UInt32
}

enum TraceDecoder {
    /// Spec §7.7: 24 words.
    static let recordSize = 96

    enum Failure: Error, Equatable {
        case truncated(byteCount: Int)
    }

    static func decode(_ data: Data) throws -> [MachineSnapshot] {
        guard data.count % recordSize == 0 else {
            PerfLog.error("trace is \(data.count) bytes, not a multiple of \(recordSize)")
            throw Failure.truncated(byteCount: data.count)
        }

        return try PerfLog.measure("decode-trace") { () -> [MachineSnapshot] in
            let bytes = [UInt8](data)
            var snapshots: [MachineSnapshot] = []
            snapshots.reserveCapacity(bytes.count / recordSize)

            for start in stride(from: 0, to: bytes.count, by: recordSize) {
                func word(_ index: Int) -> UInt32 {
                    let offset = start + index * 4
                    return UInt32(bytes[offset])
                        | UInt32(bytes[offset + 1]) << 8
                        | UInt32(bytes[offset + 2]) << 16
                        | UInt32(bytes[offset + 3]) << 24
                }
                snapshots.append(MachineSnapshot(
                    seq: word(0),
                    sourceLine: Int(word(1)),
                    pc: word(2),
                    registers: (3..<19).map(word),
                    cpsr: word(19),
                    storeAddress: word(20),
                    storeValue: word(21),
                    storeWidth: word(22)
                ))
            }
            PerfLog.info("decoded \(snapshots.count) snapshots")
            return snapshots
        }
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter TraceDecoderTests`
Expected: PASS, 3 tests.

- [ ] **Step 6: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler/Runtime Sources/KeilAssembler/Trace Tests/KeilAssemblerTests/TraceDecoderTests.swift
git commit -m "feat: ARM7 runtime with 4 GiB address space and trace record decoder"
```

---

### Task 18: Driver — assemble, link, run

**Files:**
- Create: `Sources/KeilAssembler/Driver/Driver.swift`
- Test: `Tests/KeilAssemblerTests/CorpusTests.swift`

**Interfaces:**
- Consumes: every prior task.
- Produces: `Driver()` with `compile(source:) -> CompileResult` and `run(source:preload:) throws -> RunResult`; `CompileResult(diagnostics:assembly:)`; `RunResult(snapshots:diagnostics:exitCode:standardError:)`; `RunResult.finalRegisters: [UInt32]`.

- [ ] **Step 1: Write the failing test**

`Tests/KeilAssemblerTests/CorpusTests.swift`:

```swift
import Foundation
import Testing
@testable import KeilAssembler

/// Spec §10 corpus 1(a): MOV R1, #0x12 / MOV R2, R1 / MOV R3, R1
private let exercise1a = """
    AREA PROGRAM, CODE, READONLY
    ENTRY

MAIN
MOV R1, #0X12
MOV R2, R1
MOV R3, R1
END
"""

@Test func corpus1aCopiesTheImmediateIntoThreeRegisters() throws {
    let result = try Driver().run(source: exercise1a, preload: MemoryPreload())
    #expect(result.diagnostics.contains { $0.severity == .error } == false)
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[1] == 0x12)
    #expect(result.finalRegisters[2] == 0x12)
    #expect(result.finalRegisters[3] == 0x12)
}

@Test func corpus1aProducesOneSnapshotPerInstruction() throws {
    let result = try Driver().run(source: exercise1a, preload: MemoryPreload())
    #expect(result.snapshots.count == 3)
    #expect(result.snapshots[0].registers[1] == 0x12)
    #expect(result.snapshots[0].registers[2] == 0)     // not yet written
    #expect(result.snapshots[1].registers[2] == 0x12)
}

/// Spec §10 corpus 1(b)
@Test func corpus1bAddsTwoImmediates() throws {
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R1, #0X12
    MOV R2, #0X15
    ADD R4, R1, R2
    END
    """, preload: MemoryPreload())
    #expect(result.finalRegisters[4] == 0x27)
}

/// Spec §10 corpus 1(e)
@Test func corpus1eInvertsEveryBit() throws {
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R1, #0X12
    MVN R2, R1
    END
    """, preload: MemoryPreload())
    #expect(result.finalRegisters[2] == 0xFFFF_FFED)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter CorpusTests`
Expected: FAIL with `cannot find 'Driver' in scope`.

- [ ] **Step 3: Write `Driver.swift`**

```swift
import Foundation

struct CompileResult: Sendable {
    let diagnostics: [Diagnostic]
    let assembly: String?
    var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
}

struct RunResult: Sendable {
    let snapshots: [MachineSnapshot]
    let diagnostics: [Diagnostic]
    let exitCode: Int32
    let standardError: String

    /// The register state after the last executed instruction, or all zeros.
    var finalRegisters: [UInt32] {
        snapshots.last?.registers ?? [UInt32](repeating: 0, count: 16)
    }
}

/// Spec §7.9. Each run gets its own directory holding the executable, `image.bin`,
/// and `trace.bin`, so runs never collide and a run is reproducible from its
/// directory alone.
struct Driver: Sendable {
    enum Failure: Error, CustomStringConvertible {
        case toolFailed(tool: String, status: Int32, output: String)
        case runtimeSourceMissing
        case compilationProducedNoAssembly([Diagnostic])

        var description: String {
            switch self {
            case .toolFailed(let tool, let status, let output):
                "\(tool) exited \(status): \(output)"
            case .runtimeSourceMissing:
                "armd_rt.c is missing from the package bundle"
            case .compilationProducedNoAssembly(let diagnostics):
                "compilation failed: " + diagnostics
                    .filter { $0.severity == .error }
                    .map { "\($0.code) \($0.range) \($0.message)" }
                    .joined(separator: "; ")
            }
        }
    }

    let clangURL = URL(fileURLWithPath: "/usr/bin/clang")

    init() {}

    func compile(source: String) -> CompileResult {
        var diagnostics = DiagnosticBag()
        let tokens = Lexer(source: source).tokenize(into: &diagnostics)
        var parser = Parser(tokens: tokens)
        let program = parser.parse(into: &diagnostics)
        let analysed = Analyser.analyse(program, into: &diagnostics)
        let assembly = Lowering.lower(analysed, into: &diagnostics)
        return CompileResult(diagnostics: diagnostics.diagnostics, assembly: assembly)
    }

    func run(
        source: String,
        preload: MemoryPreload,
        in directory: URL? = nil
    ) throws -> RunResult {
        var diagnostics = DiagnosticBag()
        let tokens = Lexer(source: source).tokenize(into: &diagnostics)
        var parser = Parser(tokens: tokens)
        let program = parser.parse(into: &diagnostics)
        let analysed = Analyser.analyse(program, into: &diagnostics)
        guard let assembly = Lowering.lower(analysed, into: &diagnostics) else {
            throw Failure.compilationProducedNoAssembly(diagnostics.diagnostics)
        }

        let runDirectory = try directory ?? makeRunDirectory()
        PerfLog.info("run directory: \(runDirectory.path)")

        let assemblyURL = runDirectory.appendingPathComponent("program.s")
        try assembly.write(to: assemblyURL, atomically: true, encoding: .utf8)

        try StartupImage
            .encode(dataImage: analysed.dataImage, preload: preload)
            .write(to: runDirectory.appendingPathComponent("image.bin"))

        guard let runtimeURL = Bundle.module.url(forResource: "armd_rt", withExtension: "c") else {
            PerfLog.error("armd_rt.c not found in Bundle.module")
            throw Failure.runtimeSourceMissing
        }

        let executableURL = runDirectory.appendingPathComponent("program")
        try PerfLog.measure("assemble-and-link") {
            try invoke(clangURL, arguments: [
                "-o", executableURL.path,
                assemblyURL.path,
                runtimeURL.path,
            ], in: runDirectory, tool: "clang")
        }

        let execution = try PerfLog.measure("run") {
            try invokeCapturing(executableURL, arguments: [], in: runDirectory)
        }

        let traceURL = runDirectory.appendingPathComponent("trace.bin")
        let traceData = (try? Data(contentsOf: traceURL)) ?? Data()
        let snapshots = try TraceDecoder.decode(traceData)

        return RunResult(
            snapshots: snapshots,
            diagnostics: diagnostics.diagnostics,
            exitCode: execution.status,
            standardError: execution.errorOutput
        )
    }

    // MARK: - Process plumbing

    private func makeRunDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("armd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func invoke(_ url: URL, arguments: [String], in directory: URL, tool: String) throws {
        let result = try invokeCapturing(url, arguments: arguments, in: directory)
        guard result.status == 0 else {
            PerfLog.error("\(tool) failed (\(result.status)): \(result.errorOutput)")
            throw Failure.toolFailed(tool: tool, status: result.status, output: result.errorOutput)
        }
    }

    private func invokeCapturing(
        _ url: URL, arguments: [String], in directory: URL
    ) throws -> (status: Int32, errorOutput: String) {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (process.terminationStatus, String(data: errorData, encoding: .utf8) ?? "")
    }
}
```

`Parser.parse` is `mutating`, so the driver binds it to a `var` before calling. Task 5's tests already do this implicitly through the helper.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter CorpusTests`
Expected: PASS, 4 tests. Console shows `assemble-and-link took …ms` and `run took …ms`.

If `clang` reports `undefined symbol: _armd_state`, the prologue's `adrp`/`add` pair is referencing a symbol the C file declares but never emits — confirm `struct ARMdState armd_state;` is at file scope in `armd_rt.c`, not inside a function.

- [ ] **Step 5: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Sources/KeilAssembler/Driver Tests/KeilAssemblerTests/CorpusTests.swift
git commit -m "feat: driver that assembles, links, runs, and decodes the trace"
```

---

### Task 19: Remaining corpus — memory, preload, and conditional execution

**Files:**
- Modify: `Tests/KeilAssemblerTests/CorpusTests.swift`

**Interfaces:**
- Consumes: `Driver`, `MemoryPreload`, `RunResult`. No new API.

- [ ] **Step 1: Write the failing test**

Append to `Tests/KeilAssemblerTests/CorpusTests.swift`:

```swift
/// Spec §10 corpus 1(c) — LDR Rd, label loads the *word at* the label.
@Test func corpus1cLoadsTwoWordsAndAddsThem() throws {
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    LDR R1, VALUE1
    LDR R2, VALUE2
    ADD R3, R1, R2
        AREA STORAGE, DATA, READONLY
    VALUE1 DCD, &00000012
    VALUE2 DCD, &00000013
    END
    """, preload: MemoryPreload())
    #expect(result.finalRegisters[1] == 0x12)
    #expect(result.finalRegisters[2] == 0x13)
    #expect(result.finalRegisters[3] == 0x25)
}

private let exercise1d = """
    AREA PROGRAM, CODE, READONLY
    ENTRY

MAIN
LDR R1, VALUE1
LDR R2, VALUE2
LDR R3, [R1]
LDR R4, [R2]
ADD R6, R4, R3
    AREA STORAGE, DATA, READONLY
VALUE1 DCD, &00001000
VALUE2 DCD, &00001004
END
"""

/// Spec §10 corpus 1(d) — memory contents come from the preload image (§5.3).
@Test func corpus1dDereferencesPreloadedAddresses() throws {
    let result = try Driver().run(
        source: exercise1d,
        preload: MemoryPreload(words: [0x1000: 0x12, 0x1004: 0x13])
    )
    #expect(result.finalRegisters[1] == 0x1000)
    #expect(result.finalRegisters[2] == 0x1004)
    #expect(result.finalRegisters[3] == 0x12)
    #expect(result.finalRegisters[4] == 0x13)
    #expect(result.finalRegisters[6] == 0x25)
}

/// Spec §10 corpus `1d-zero` — pins the documented zero-fill of unwritten memory.
@Test func corpus1dWithoutPreloadReadsZeros() throws {
    let result = try Driver().run(source: exercise1d, preload: MemoryPreload())
    #expect(result.finalRegisters[1] == 0x1000)
    #expect(result.finalRegisters[3] == 0)
    #expect(result.finalRegisters[4] == 0)
    #expect(result.finalRegisters[6] == 0)
}

/// Spec §10 corpus 2(a) — shifted Operand2.
@Test func corpus2aShiftsALoadedWordLeftByTwo() throws {
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    LDR R1, VALUE
    MOV R3, R1, LSL #2
        AREA STORAGE, DATA, READONLY
    VALUE DCD &3000F000
    END
    """, preload: MemoryPreload())
    #expect(result.finalRegisters[1] == 0x3000_F000)
    #expect(result.finalRegisters[3] == 0xC003_C000)
}

/// Spec §10 corpus 2(b) — exercises the §7.3 CPSR round-trip and §6.1 guard.
@Test func corpus2bExecutesTheConditionalMoveWhenZIsSet() throws {
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R1, #0X12
    MOVS R3, #0
    MOVEQ R3, R1, LSL #3
    END
    """, preload: MemoryPreload())
    // MOVS R3, #0 sets Z, so the conditional move runs: 0x12 << 3 = 0x90.
    #expect(result.finalRegisters[3] == 0x90)
}

@Test func storesAreVisibleInTheTrace() throws {
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    LDR R1, =0x00002000
    MOV R2, #0X12
    STR R2, [R1]
    END
    """, preload: MemoryPreload())
    let store = result.snapshots.last
    #expect(store?.storeAddress == 0x2000)
    #expect(store?.storeValue == 0x12)
    #expect(store?.storeWidth == 4)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter CorpusTests`
Expected: FAIL. The likely first failure is `corpus1c`: the parser accepts `DCD,` (W002) but the analyser must place `VALUE1` before `LDR R1, VALUE1` can resolve it, and forward references are only bound after pass 1.

- [ ] **Step 3: Fix whatever the corpus exposes**

No new production code is planned for this task — it is the acceptance gate for Tasks 1–18. Work each failure with `superpowers:systematic-debugging`. The three most likely, in order:

1. **Forward label references.** `LDR R1, VALUE1` appears before `VALUE1 DCD`. Task 10's pass 1 binds every label before pass 2 evaluates anything, and Task 16 reads `symbols.labels[name]` during lowering, which runs after analysis — so this should hold. If it does not, the fault is a label bound to the wrong `position` in pass 1.
2. **`END` inside a `CODE` area.** `END` is parsed as a directive and ignored by the analyser, but it sits after the data area, so nothing follows it. If the analyser treats lines after `END` as code, stop the layout loop at the first `.end` directive.
3. **`MOVEQ R3, R1, LSL #3` operand shape.** The parser's shift lookahead in Task 7 fires on `R1, LSL`, producing `[.register(3), .operand2(.shifted(...))]`. Task 15's `mov` case takes `operands.dropFirst().first`, which is the `.operand2` — correct. If it fails, the lookahead consumed the comma.

Add a regression test for each fault found, at the level where it originated (lexer, parser, analyser, or lowering) — not only at the corpus level.

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: PASS, all tests across all files.

- [ ] **Step 5: Verify the emitted assembly by hand once**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
swift test --filter corpus1dDereferencesPreloadedAddresses 2>&1 | grep "run directory"
# then, in that directory:
cat program.s
```

Read it against Spec §7.5. This is the one manual check the test suite cannot make for you: the tests prove the *values* are right, not that the emitted code is what the Spec describes. PRD G6 makes the readability of this file a product goal.

- [ ] **Step 6: Commit**

```bash
cd ~/Programming/Swift/Packages/KeilAssembler
git add Tests Sources
git commit -m "test: full Spec §10 corpus running end to end with memory preload"
```

---

## Self-Review

**1. Spec coverage.**

| Spec section | Task |
|---|---|
| §2 pipeline | 18 (Driver wires every stage) |
| §3 machine model | 17 (`armd_rt.c` reset state, stack top) |
| §4 lexical structure | 2, 3 |
| §4.1 line grammar, W001 | 5 |
| §5 directives, W002/W003 | 6 |
| §5.1 expressions | 6 (parse), 9 (evaluate) |
| §5.2 area layout, ARM7 addresses | 10 |
| §5.3 startup image, preload | 12 |
| §6.1 condition codes | 4 (table), 15 (guard emission) |
| §6.2 Operand2, E020 | 7 (parse), 11 (legality), 14 (lowering) |
| §6.3 instruction set | 7, 8 (parse), 15, 16 (lower) |
| §7.1 host registers | 13 |
| §7.2 register file | 13 |
| §7.3 flags | 13, 15 |
| §7.4 Operand2 materialisation | 14 |
| §7.5 instruction lowering | 15, 16 |
| §7.6 three LDR forms | 8 (parse), 16 (lower) |
| §7.7 trace | 13 (emit), 17 (record + decode) |
| §7.8 runtime | 17 |
| §7.9 program shape, build | 13 (frame), 18 (clang) |
| §8 diagnostics | 1 |
| §9 D1/D2/D8 | 11 |
| §10 corpus | 18, 19 |
| §11 Q1/Q2/Q4 leniency | 5, 6, 10 |

**Gaps, stated rather than hidden:**
- **§9 D3, D4, D5, D6, D7** are properties of the design (code is not in ARM7 memory; no unaligned rotation; little-endian; user mode; no timing). Nothing implements them and nothing can violate them within M1–M5, so no task claims them. D4's `W011` warning is not implemented — it needs a statically known address, which only `LDR Rd, label` provides. Note it for M6.
- **§6.1 `NV` → `E011`** is not reachable: `Condition(suffix:)` returns nil for `NV`, so `Mnemonic.decompose` rejects the whole mnemonic and the parser emits `E013` instead. The error is caught; the code differs from the Spec. Left as-is and recorded here rather than contorting the suffix decoder.
- **§7.4 `RRX`** is diagnosed (`E036`), not lowered — Spec §7.4 never defines the sequence. Task 14 step 3 documents this.
- **General `LDM`/`STM` → `E012`** is not implemented; those mnemonics simply do not parse and yield `E013`. Same shape of gap as `NV`.

**2. Placeholder scan.** No "TBD", no "add error handling", no "similar to Task N". The two intentional stubs (Task 5 step 4, Task 7 step 4) exist so the file compiles between tasks and are each replaced by a named later task; each dispatch says so explicitly, so a reviewer is not left to guess whether they are abandoned code.

**3. Type consistency.** `SourceRange(line:column:length:)`, `Diagnostic(severity:code:message:range:note:)`, `DiagnosticBag.emit`, `Token.Kind`, `Mnemonic.decompose`, `Operand2.shifted(register:shift:)`, `ShiftSpec(kind:amount:amountRegister:)`, `AddressMode` cases, `ImageBlob(address:bytes:)`, `AnalysedProgram.addresses`, `Emitter.loadRegister(_:into:into:)`, `MachineSnapshot.registers`, `MemoryPreload(words:)` are each defined once and used with the same spelling everywhere after. `Emitter`'s methods take `into builder:` as the trailing label throughout, including `loadRegister(1, into: "w9", into: &builder)` — awkward to read, consistent to call.

---

## Execution Handoff

Plan complete and saved to `Docs/plans/2026-08-11-keilassembler-m1-m5.md`. Two execution options:

**1. Subagent-Driven (recommended)** — a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

