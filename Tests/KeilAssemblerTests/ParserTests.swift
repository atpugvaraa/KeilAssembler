import Testing
@testable import KeilAssembler

func parse(_ source: String) -> (Program, DiagnosticBag) {
    var bag = DiagnosticBag()
    let tokens = Lexer(source: source).tokenize(into: &bag)
    var parser = Parser(tokens: tokens)
    let program = parser.parse(into: &bag)
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

// MARK: - Strengthening beyond the brief

@Test func parserKeepsAGenuineLabelWhenFollowedByAnInstructionOnTheSameLine() {
    // A wrong implementation that only recognises a column-1 label when it is
    // alone on the line (e.g. one that unconditionally treats any column-1
    // word followed by more tokens as a mis-parsed mnemonic) would fail this:
    // it must still read LOOP as the label and MOV as the instruction.
    let (program, bag) = parse("LOOP MOV R1, R2\n")
    #expect(bag.diagnostics.isEmpty)
    #expect(program.lines.count == 1)
    #expect(program.lines[0].label == "LOOP")
    guard case .instruction(let instruction)? = program.lines[0].statement else {
        Issue.record("expected an instruction")
        return
    }
    #expect(instruction.mnemonic == .mov)
}

@Test func parserDoesNotHangOnAnUnsupportedColumnOneSymbol() {
    // A symbol that is neither a label candidate handled specially, nor a
    // mnemonic, nor a directive: must still terminate and report E013 rather
    // than looping. Regression guard for the class of bug called out in the
    // task brief (a cursor that never advances).
    let (program, bag) = parse("    NOTAMNEMONIC R1\n")
    #expect(bag.diagnostics.map(\.code) == ["E013"])
    #expect(program.lines.count == 1)
}

@Test func parserTerminatesOnSourceWithNoTrailingNewline() {
    let (program, bag) = parse("MAIN")
    #expect(bag.diagnostics.isEmpty)
    #expect(program.lines.count == 1)
    #expect(program.lines[0].label == "MAIN")
}

@Test func parserTerminatesOnALexerErrorCharacter() {
    let (program, bag) = parse("@@@\n")
    #expect(bag.diagnostics.map(\.code) == ["E001", "E001", "E001"])
    #expect(program.lines.isEmpty)
}

@Test func parserTerminatesOnEmptySource() {
    let (program, bag) = parse("")
    #expect(bag.diagnostics.isEmpty)
    #expect(program.lines.isEmpty)
}
