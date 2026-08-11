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
