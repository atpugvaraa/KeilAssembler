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

// MARK: - Task 6: directives and expressions

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

// MARK: - Expression precedence (strengthening beyond the brief)
//
// Spec §5.1 precedence, lowest binding first: :AND: :OR: :EOR: -> :SHL: :SHR: -> + - -> * / :MOD:
// -> unary -> primary. A precedence-climbing chain with levels swapped, or a level that
// consumes an extra term, still produces a *valid-looking* Expression tree, so these pin
// the actual tree shape rather than just checking that parsing succeeds.

@Test func parserGroupsMultiplicationTighterThanAddition() {
    // A chain that put + and * at the same level (or reversed them) would build
    // .binary(.multiply, .binary(.add, 1, 2), 3) instead.
    let (program, bag) = parse("N EQU 1 + 2 * 3\n")
    #expect(bag.diagnostics.isEmpty)
    #expect(program.lines[0].statement == .directive(.equ(
        symbol: "N",
        value: .binary(.add, .integer(1), .binary(.multiply, .integer(2), .integer(3)))
    )))
}

@Test func parserGroupsAdditionTighterThanShift() {
    // :SHL:/:SHR: bind looser than + -, so the additive expression must be the
    // fully-grouped right operand of the shift, not the other way round.
    let (program, bag) = parse("N EQU 1 :SHL: 2 + 3\n")
    #expect(bag.diagnostics.isEmpty)
    #expect(program.lines[0].statement == .directive(.equ(
        symbol: "N",
        value: .binary(.shiftLeft, .integer(1), .binary(.add, .integer(2), .integer(3)))
    )))
}

@Test func parserGroupsShiftTighterThanLogical() {
    // :AND:/:OR:/:EOR: are the loosest tier, binding looser than :SHL:/:SHR:. A chain that
    // swapped parseLogical and parseShift would build .binary(.shiftLeft, .binary(.and, 1, 2), 3)
    // instead — still a valid-looking tree, only catchable by pinning the shape.
    let (program, bag) = parse("N EQU 1 :AND: 2 :SHL: 3\n")
    #expect(bag.diagnostics.isEmpty)
    #expect(program.lines[0].statement == .directive(.equ(
        symbol: "N",
        value: .binary(.and, .integer(1), .binary(.shiftLeft, .integer(2), .integer(3)))
    )))
}

@Test func parserMapsEachLogicalOperatorWordToItsOwnDistinctOperator() {
    // Catches a typo in the `logicalOperators` dictionary (e.g. "EOR" mapped to .or) that a
    // "does it parse" test would never see, since the result is still a valid Expression tree.
    func value(_ source: String) -> Expression? {
        guard case .directive(.equ(_, let value))? = parse(source).0.lines[0].statement else { return nil }
        return value
    }
    #expect(value("N EQU 1 :AND: 2\n") == .binary(.and, .integer(1), .integer(2)))
    #expect(value("N EQU 1 :OR: 2\n") == .binary(.or, .integer(1), .integer(2)))
    #expect(value("N EQU 1 :EOR: 2\n") == .binary(.exclusiveOr, .integer(1), .integer(2)))
}

@Test func parserParsesModAsABinaryOperator() {
    let (program, bag) = parse("N EQU 7 :MOD: 2\n")
    #expect(bag.diagnostics.isEmpty)
    #expect(program.lines[0].statement == .directive(.equ(
        symbol: "N", value: .binary(.modulo, .integer(7), .integer(2))
    )))
}

@Test func parserGroupsModAtTheSameTierAsMultiplication() {
    // :MOD: sits with * and /, tighter than + -, so this must group as 1 + (6 :MOD: 4).
    let (program, bag) = parse("N EQU 1 + 6 :MOD: 4\n")
    #expect(bag.diagnostics.isEmpty)
    #expect(program.lines[0].statement == .directive(.equ(
        symbol: "N",
        value: .binary(.add, .integer(1), .binary(.modulo, .integer(6), .integer(4)))
    )))
}

@Test func parserParsesCaretAsBitwiseNotNotExclusiveOr() {
    // Domain rule: '^' is unary NOT in this dialect (no '~' token in the lexer), not XOR.
    // A wrong implementation that drops '^' silently would produce .integer(1) instead.
    let (program, bag) = parse("N EQU ^1\n")
    #expect(bag.diagnostics.isEmpty)
    #expect(program.lines[0].statement == .directive(.equ(symbol: "N", value: .unary(.not, .integer(1)))))
}

@Test func parserParsesUnaryMinusWithoutFoldingIt() {
    // Spec §2: the parser preserves what the source says; constant folding happens later.
    let (program, bag) = parse("N EQU -5\n")
    #expect(bag.diagnostics.isEmpty)
    #expect(program.lines[0].statement == .directive(.equ(symbol: "N", value: .unary(.minus, .integer(5)))))
}

@Test func parserReportsEquWithoutAPrecedingLabel() {
    let (program, bag) = parse("    EQU 4\n")
    #expect(bag.hasErrors)
    #expect(program.lines[0].statement == nil)
}

// MARK: - Termination invariant traces

@Test func parserDoesNotHangOnAreaWithNoName() {
    let (program, bag) = parse("    AREA\n")
    #expect(bag.diagnostics.map(\.code) == ["E008"])
    #expect(program.lines.count == 1)
    #expect(program.lines[0].statement == nil)
}

@Test func parserDoesNotHangOnDcdWithNoValues() {
    let (program, bag) = parse("VALUE1 DCD\n")
    #expect(bag.diagnostics.map(\.code) == ["E016", "E009"])
    #expect(program.lines[0].statement == .directive(.defineWords([])))
}

@Test func parserDoesNotHangOnDcdWithOnlyCommas() {
    let (program, bag) = parse("VALUE1 DCD ,,,\n")
    #expect(bag.diagnostics.map(\.code) == ["W002", "E016", "E009"])
    #expect(program.lines[0].statement == .directive(.defineWords([])))
}

@Test func parserDoesNotHangOnEquWithAMalformedExpression() {
    let (program, bag) = parse("SIZE EQU )\n")
    #expect(bag.diagnostics.map(\.code) == ["E016"])
    #expect(program.lines[0].label == "SIZE")
    #expect(program.lines[0].statement == nil)
}

@Test func parserDoesNotHangOnABinaryOperatorMissingItsRightOperand() {
    let (program, bag) = parse("N EQU 1 +\n")
    #expect(bag.diagnostics.map(\.code) == ["E016"])
    #expect(program.lines[0].statement == nil)
}

@Test func parserDoesNotHangOnAnUnclosedParenthesis() {
    let (program, bag) = parse("N EQU (1\n")
    #expect(bag.diagnostics.map(\.code) == ["E015"])
    #expect(program.lines[0].statement == nil)
}

@Test func parserDoesNotHangOnADataListWhoseExpressionFailsMidList() {
    // The failed expression aborts the rest of the line (Spec: malformed constructs are
    // diagnosed, not silently misparsed); the trailing `, 3` is discarded, not looped over.
    let (program, bag) = parse("VALS DCD 1, ), 3\n")
    #expect(bag.diagnostics.map(\.code) == ["E016"])
    #expect(program.lines[0].statement == .directive(.defineWords([.integer(1)])))
    #expect(program.lines.count == 1)
}

// MARK: - Review fix: a missing comma between data-list values must be diagnosed

@Test func parserDiagnosesADataListMissingACommaBetweenValues() {
    // Without a fix, `1` parses, `while match(.comma)` is false (next token is `.integer(2)`,
    // not a comma), the loop exits silently with values == [1], and the orphaned `2` gets
    // re-dispatched as a bogus top-level statement (misleading E006), with NO diagnostic
    // naming the actual problem: half the data silently vanished.
    let (program, bag) = parse("VALUE1 DCD 1 2\n")
    #expect(bag.diagnostics.map(\.code) == ["E039"])
    #expect(program.lines[0].statement == .directive(.defineWords([.integer(1)])))
    // The orphaned `2` must not surface as a second, misleadingly-diagnosed line.
    #expect(program.lines.count == 1)
}

@Test func parserDiagnosesADcbStringListMissingACommaBetweenValues() {
    // Same defect via string literals: `DCB "ab" "cd"` would otherwise silently emit only
    // 2 bytes ("ab") instead of 4, with no diagnostic pointing at the dropped "cd".
    let (program, bag) = parse("    DCB \"ab\" \"cd\"\n")
    #expect(bag.diagnostics.map(\.code) == ["E039"])
    #expect(program.lines[0].statement == .directive(.defineBytes([
        .integer(UInt32(UnicodeScalar("a").value)), .integer(UInt32(UnicodeScalar("b").value)),
    ])))
    #expect(program.lines.count == 1)
}

// MARK: - Task 7: instructions and Operand2

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

// MARK: - Strengthening beyond the brief

@Test func parserDecomposesLongestMatchingMnemonicNotAShorterPrefix() {
    // If `Mnemonic.decompose` (or its use here) picked the shorter prefix "LDR" first and
    // treated the trailing "B"/"H" as a condition/flag suffix, this would misparse the
    // mnemonic entirely (and likely fail to parse at all, since "B"/"H" alone are not valid
    // suffixes). LDRB/STRH must come through as themselves, unconditional, no flags.
    let ldrb = firstInstruction("    LDRB R1, R2\n")
    #expect(ldrb?.mnemonic == .ldrb)
    #expect(ldrb?.condition == .al)
    #expect(ldrb?.setsFlags == false)

    let strh = firstInstruction("    STRH R1, R2\n")
    #expect(strh?.mnemonic == .strh)
    #expect(strh?.condition == .al)
    #expect(strh?.setsFlags == false)
}

@Test func parserCombinesConditionFlagSuffixAndShiftedOperand() {
    // Exercises suffix-splitting and Operand2 shift parsing together: a wrong implementation
    // that gets each piece right in isolation (per the other tests) could still fail here if,
    // say, the shift lookahead only fires for the unconditional/unflagged spelling.
    let instruction = firstInstruction("    ADDEQS R1, R2, R3, LSL #4\n")
    #expect(instruction?.mnemonic == .add)
    #expect(instruction?.condition == .eq)
    #expect(instruction?.setsFlags == true)
    #expect(instruction?.operands == [
        .register(1),
        .register(2),
        .operand2(.shifted(register: 3, shift: ShiftSpec(kind: .lsl, amount: .integer(4)))),
    ])
}

// MARK: - Task 7: termination invariant traces

@Test func parserDoesNotHangOnAnInstructionWithNoOperands() {
    // No tokens follow the mnemonic before end of line, so the operand loop is never
    // entered at all — a zero-operand instruction like `NOP` is legitimate, not an error.
    let (program, bag) = parse("    MOV\n")
    #expect(bag.diagnostics.isEmpty)
    #expect(firstInstruction("    MOV\n")?.operands == [])
    #expect(program.lines.count == 1)
}

@Test func parserDoesNotHangOnATrailingComma() {
    let (program, bag) = parse("    MOV R1,\n")
    #expect(bag.diagnostics.map(\.code) == ["E038"])
    #expect(program.lines.count == 1)
}

@Test func parserDoesNotHangOnADoubledComma() {
    let (program, bag) = parse("    MOV R1, , R2\n")
    #expect(bag.diagnostics.map(\.code) == ["E038"])
    #expect(program.lines.count == 1)
}

@Test func parserDoesNotHangOnAHashWithNoExpression() {
    let (program, bag) = parse("    MOV R1, #\n")
    #expect(bag.diagnostics.map(\.code) == ["E016"])
    #expect(program.lines.count == 1)
}

@Test func parserDoesNotHangOnAShiftWithNoAmount() {
    let (program, bag) = parse("    MOV R3, R1, LSL\n")
    #expect(bag.diagnostics.map(\.code) == ["E019"])
    #expect(program.lines.count == 1)
}

@Test func parserDoesNotHangOnAShiftHashWithNoAmount() {
    let (program, bag) = parse("    MOV R3, R1, LSL #\n")
    #expect(bag.diagnostics.map(\.code) == ["E016"])
    #expect(program.lines.count == 1)
}

@Test func parserDoesNotHangOnABareUnexpectedOperandToken() {
    let (program, bag) = parse("    MOV R1, )\n")
    #expect(bag.diagnostics.map(\.code) == ["E038"])
    #expect(program.lines.count == 1)
}

// MARK: - Review fix: a missing comma between operands must not silently truncate the list

@Test func parserDiagnosesAMissingCommaBetweenOperands() {
    // Without the fix, `registerIsTrailingOperand2`'s `default: return true` misclassifies R1
    // as the trailing Operand2 (R2 is neither `.comma` nor `.symbol`), so R1 is consumed alone,
    // the `while match(.comma)` loop exits normally (R2 isn't a comma either), and R2 is
    // re-dispatched as a bogus second top-level statement — silently truncating the operand
    // list with no diagnostic naming the actual problem.
    let (program, bag) = parse("    MOV R1 R2\n")
    #expect(bag.diagnostics.map(\.code) == ["E040"])
    #expect(program.lines.count == 1)
    #expect(firstInstruction("    MOV R1 R2\n")?.operands == [.register(1)])
}

@Test func parserDiagnosesAMissingCommaBeforeATrailingSymbol() {
    // Same defect via a non-shift symbol operand: `registerIsTrailingOperand2`'s `.symbol`
    // branch correctly returns false here (LABEL isn't a shift keyword), so R1 is a bare
    // register — but nothing then checks that a comma (not LABEL) was supposed to follow.
    let (program, bag) = parse("    MOV R1 LABEL\n")
    #expect(bag.diagnostics.map(\.code) == ["E040"])
    #expect(program.lines.count == 1)
    #expect(firstInstruction("    MOV R1 LABEL\n")?.operands == [.register(1)])
}
