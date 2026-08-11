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

@Test func lexerPreservesCaseSensitivityOfSymbolsWhileHandlingCaseInsensitiveRegisters() {
    #expect(lex("myLabel\n    sp lr\n") == [
        .symbol("myLabel"), .endOfLine,
        .register(13), .register(14), .endOfLine,
        .endOfFile,
    ])
    // Verify exact source ranges to ensure case-sensitive symbol spelling survives
    var bag = DiagnosticBag()
    let tokens = Lexer(source: "myLabel\n    sp lr\n").tokenize(into: &bag)
    #expect(tokens[0].kind == .symbol("myLabel"))  // lowercase 'myLabel', not 'MYLABEL'
    #expect(tokens[1].kind == .endOfLine)
    #expect(tokens[2].kind == .register(13))  // 'sp' uppercased for classification but not stored
    #expect(tokens[3].kind == .register(14))  // 'lr' uppercased for classification but not stored
}

@Test func lexerSurvivesBlankLinesPreservingLineIndices() {
    var bag = DiagnosticBag()
    let tokens = Lexer(source: "MAIN\n\n    MOV R1, R2\n").tokenize(into: &bag)
    // Line 0: MAIN
    // Line 1: (blank)
    // Line 2: MOV R1, R2
    // Line 3: (empty after trailing newline)

    // Verify MOV is on line 2, not line 1 (would be wrong if blank line was skipped)
    #expect(tokens[0].kind == .symbol("MAIN"))
    #expect(tokens[0].range.line == 0)
    #expect(tokens[1].kind == .endOfLine)

    // The blank line produces just an endOfLine
    #expect(tokens[2].kind == .endOfLine)

    // MOV should be on line 2
    #expect(tokens[3].kind == .symbol("MOV"))
    #expect(tokens[3].range.line == 2)  // Critical: must be 2, not 1
    #expect(tokens[4].kind == .register(1))
    #expect(tokens[4].range.line == 2)
    #expect(tokens[5].kind == .comma)
    #expect(tokens[5].range.line == 2)
    #expect(tokens[6].kind == .register(2))
    #expect(tokens[6].range.line == 2)
}

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

@Test func lexerRejectsAnUnterminatedCharacterLiteral() {
    var bag = DiagnosticBag()
    let tokens = Lexer(source: "'A").tokenize(into: &bag)
    #expect(bag.diagnostics.map(\.code) == ["E003"])
    #expect(bag.hasErrors)
    // No spurious integer token should be produced for the malformed literal.
    #expect(tokens.map(\.kind) == [.endOfFile])
}

@Test func lexerRejectsAnOutOfRangeBase() {
    var bag = DiagnosticBag()
    _ = Lexer(source: "99_5").tokenize(into: &bag)
    #expect(bag.diagnostics.map(\.code) == ["E005"])
    #expect(bag.hasErrors)
}

@Test func lexerRejectsALoneAmpersandWithNoDigits() {
    var bag = DiagnosticBag()
    _ = Lexer(source: "&").tokenize(into: &bag)
    #expect(bag.diagnostics.map(\.code) == ["E005"])
    #expect(bag.hasErrors)
}

@Test func lexerRejectsAnUnterminatedOperatorWord() {
    var bag = DiagnosticBag()
    _ = Lexer(source: ":SHL").tokenize(into: &bag)
    #expect(bag.diagnostics.map(\.code) == ["E004"])
    #expect(bag.hasErrors)
}

@Test func lexerWraps32BitOverflowingLiterals() {
    #expect(lex("&1FFFFFFFF") == [.integer(0xFFFFFFFF), .endOfFile])
}
