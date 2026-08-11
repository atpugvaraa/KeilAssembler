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

// MARK: - Strengthening beyond the brief

@Test func evaluatorRejectsModuloByZeroWithE032() {
    // Pins that the shared "right != 0" guard on the `.divide, .modulo` case
    // actually covers modulo too, not just divide. A wrong implementation
    // that only checked zero on the divide branch (e.g. `right == 0 && op == .divide`)
    // would crash here (Swift traps on `%` by zero) or silently return 0.
    var bag = DiagnosticBag()
    let value = ExpressionEvaluator.evaluate(
        .binary(.modulo, .integer(7), .integer(0)), symbols: SymbolTable(), here: 0,
        range: SourceRange(line: 0, column: 0, length: 1),
        diagnostics: &bag
    )
    #expect(value == nil)
    #expect(bag.diagnostics.map(\.code) == ["E032"])
}

@Test func evaluatorComputesDivideAndModuloResults() {
    // Pins that divide and modulo aren't swapped: a wrong implementation
    // that flips `op == .divide ? left / right : left % right` would fail
    // both expectations below simultaneously (3 vs 1).
    #expect(evaluate(.binary(.divide, .integer(7), .integer(2))) == 3)
    #expect(evaluate(.binary(.modulo, .integer(7), .integer(2))) == 1)
}

@Test func evaluatorAppliesBitwiseOperators() {
    // Covers AND/OR/XOR/multiply so the binary switch is exercised on every
    // case, not just add/subtract. A wrong implementation that mixed up
    // `|` and `^`, or `&` and `&*`, would fail one of these.
    #expect(evaluate(.binary(.and, .integer(0b1100), .integer(0b1010))) == 0b1000)
    #expect(evaluate(.binary(.or, .integer(0b1100), .integer(0b1010))) == 0b1110)
    #expect(evaluate(.binary(.exclusiveOr, .integer(0b1100), .integer(0b1010))) == 0b0110)
    #expect(evaluate(.binary(.multiply, .integer(6), .integer(7))) == 42)
}

@Test func evaluatorShiftsNormallyBelowThirtyTwo() {
    #expect(evaluate(.binary(.shiftLeft, .integer(1), .integer(4))) == 0x10)
    #expect(evaluate(.binary(.shiftRight, .integer(0x10), .integer(4))) == 1)
}

@Test func evaluatorShiftsByThirtyTwoOrMoreYieldZero() {
    // Pins the >= 32 guard exactly: a wrong implementation that masks the
    // shift amount (`right % 32`) would treat a shift of 32 as a shift of 0
    // and return the untouched operand (1) instead of 0.
    #expect(evaluate(.binary(.shiftLeft, .integer(1), .integer(32))) == 0)
    #expect(evaluate(.binary(.shiftLeft, .integer(1), .integer(33))) == 0)
    #expect(evaluate(.binary(.shiftRight, .integer(0xFFFF_FFFF), .integer(32))) == 0)
    // And the boundary just below 32 must still behave like a normal shift,
    // ruling out an off-by-one that guards `> 32` instead of `>= 32`.
    #expect(evaluate(.binary(.shiftLeft, .integer(1), .integer(31))) == 0x8000_0000)
}

@Test func evaluatorAppliesUnaryPlusAsIdentity() {
    // The brief's own tests never exercise `.plus`; a wrong implementation
    // that negated or dropped the operand here would slip through untested.
    #expect(evaluate(.unary(.plus, .integer(0x42))) == 0x42)
}

@Test func evaluatorComputesUnaryMinus() {
    // The only prior `.unary(.minus, ...)` use had a nil operand, so the
    // `0 &- value` branch itself never ran. A regression turning it into
    // plain `value` (dropping negation) or a trapping `0 - value` (crashing
    // instead of wrapping) would both pass the rest of the suite silently.
    #expect(evaluate(.unary(.minus, .integer(0))) == 0)
    #expect(evaluate(.unary(.minus, .integer(1))) == 0xFFFF_FFFF)
}

@Test func evaluatorWrapsMultiplyAndAddOnOverflow() {
    // Every prior arithmetic test stayed well under UInt32.max, so replacing
    // `&*`/`&+` with the trapping `*`/`+` would still pass. These force an
    // actual overflow through both operators.
    #expect(evaluate(.binary(.multiply, .integer(0x8000_0000), .integer(2))) == 0)
    #expect(evaluate(.binary(.add, .integer(0xFFFF_FFFF), .integer(2))) == 1)
}

@Test func evaluatorResolvesHereToTheSuppliedAddress() {
    // Every other test passes `here: 0`, so a wrong implementation that
    // always returned 0 for `.here` (ignoring the parameter) would pass
    // them anyway. Pin a non-zero value explicitly.
    var bag = DiagnosticBag()
    let value = ExpressionEvaluator.evaluate(
        .here, symbols: SymbolTable(), here: 0x0000_9004,
        range: SourceRange(line: 0, column: 0, length: 1),
        diagnostics: &bag
    )
    #expect(value == 0x0000_9004)
    #expect(bag.diagnostics.isEmpty)
}

@Test func evaluatorStopsAtTheFirstFailureInABinaryExpression() {
    // With both operands undefined, a correct short-circuiting evaluator
    // reports only the left failure and never evaluates the right operand.
    // A wrong implementation that evaluated both sides unconditionally
    // (ignoring the first nil) would emit two E031 diagnostics instead of one.
    var bag = DiagnosticBag()
    let value = ExpressionEvaluator.evaluate(
        .binary(.add, .symbol("LEFT"), .symbol("RIGHT")), symbols: SymbolTable(), here: 0,
        range: SourceRange(line: 0, column: 0, length: 1),
        diagnostics: &bag
    )
    #expect(value == nil)
    #expect(bag.diagnostics.map(\.code) == ["E031"])
}

@Test func evaluatorPropagatesAnUndefinedSymbolThroughNestedExpressions() {
    // Recursion must actually thread failure upward rather than substituting
    // a fallback value (e.g. 0) for the nil child.
    let value = evaluate(.binary(.multiply, .integer(3), .unary(.minus, .symbol("NOPE"))))
    #expect(value == nil)
}

@Test func evaluatorPrefersConstantsOverLabelsOnNameCollision() {
    // Documents SymbolTable.lookup's declared precedence (constants first).
    var symbols = SymbolTable()
    symbols.constants["X"] = 1
    symbols.labels["X"] = 2
    #expect(symbols.lookup("X") == 1)
}

// MARK: - Analyser (Task 10)

private func analyse(_ source: String) -> (AnalysedProgram, DiagnosticBag) {
    var bag = DiagnosticBag()
    let tokens = Lexer(source: source).tokenize(into: &bag)
    var parser = Parser(tokens: tokens)
    let program = parser.parse(into: &bag)
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

// MARK: - Strengthening beyond the brief

@Test func analyserDiagnosesALabelReusingAnEquName() {
    // The obligation inherited from Task 9: SymbolTable.lookup resolves constants
    // before labels and cannot itself signal ambiguity. A wrong implementation that
    // writes straight into `symbols.labels[...]` / `symbols.constants[...]` without
    // cross-checking the other dictionary would let the EQU silently shadow VALUE's
    // address with no diagnostic at all — exactly the highest-severity defect class
    // this task exists to close.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
    VALUE MOV R2, #2
    VALUE EQU 5
    """)
    #expect(bag.diagnostics.map(\.code).contains("E042"))
}

@Test func analyserDiagnosesADuplicateLabel() {
    // Duplicate names *within* one dictionary deserve the same E042 treatment.
    // The brief's own sample code binds labels with `if symbols.labels[label] == nil`,
    // which silently keeps the first and never reports the second — this test would
    // catch that silent-first-wins behaviour.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
    MAIN
        MOV R2, #2
    """)
    #expect(bag.diagnostics.map(\.code).contains("E042"))
}

@Test func analyserDiagnosesADuplicateEqu() {
    // Symmetric case for the constants dictionary: two EQUs with the same name.
    // A wrong implementation that only cross-checks labels-vs-constants (and never
    // checks constants-vs-constants) would let the second EQU overwrite the first
    // with no diagnostic.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
    SIZE EQU 4
    SIZE EQU 8
    """)
    #expect(bag.diagnostics.map(\.code).contains("E042"))
}

@Test func analyserDoesNotFlagAnOrdinaryEquAsAColliding() {
    // Guards against a false positive from the fix above: an EQU directive's own
    // label-column symbol (Line.label carries it, same as any other statement) must
    // not fall through into the generic position-label binding path and register
    // itself in `symbols.labels` before pass 1b binds it as a constant — that would
    // make every ordinary EQU miscount as a self-collision against E042.
    let (analysed, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
    SIZE EQU 4
        MOV R2, #1
    """)
    #expect(bag.hasErrors == false)
    #expect(bag.diagnostics.map(\.code).contains("E042") == false)
    #expect(analysed.symbols.constants["SIZE"] == 4)
    #expect(analysed.symbols.labels["SIZE"] == nil)
}

@Test func analyserResolvesAForwardLabelReferenceInData() {
    // Spec §5.1: "forward references are permitted." PTR's DCD value names VALUE1
    // before VALUE1's own DCD line. A wrong implementation that evaluated data
    // values during pass 1 (interleaved with layout) rather than deferring all
    // evaluation to pass 2 would report VALUE1 as undefined (E031) here, because
    // VALUE1 is not yet bound at the point PTR is laid out.
    let (analysed, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
        AREA STORAGE, DATA, READONLY
    PTR DCD VALUE1
    VALUE1 DCD &00000012
    """)
    #expect(bag.hasErrors == false)
    let ptr = analysed.symbols.labels["PTR"]!
    let value1 = analysed.symbols.labels["VALUE1"]!
    let blob = analysed.dataImage.first { $0.address == ptr }
    let expectedBytes: [UInt8] = [
        UInt8(truncatingIfNeeded: value1),
        UInt8(truncatingIfNeeded: value1 >> 8),
        UInt8(truncatingIfNeeded: value1 >> 16),
        UInt8(truncatingIfNeeded: value1 >> 24),
    ]
    #expect(blob?.bytes == expectedBytes)
}

@Test func analyserInsertsRealAlignmentPaddingBeforeAFourByteDirective() {
    // Domain rule 3: alignment happens before the label binds, and it must insert
    // real padding, not just round the *label* up while leaving the byte cursor
    // untouched. A wrong implementation that bound WVAL's label to the next multiple
    // of 4 without also advancing `position` past the padding bytes (or that skipped
    // alignment entirely and put WVAL one byte after BVAL) would fail this.
    let (analysed, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
        AREA STORAGE, DATA, READONLY
    BVAL DCB &FF
    WVAL DCD &12345678
    """)
    #expect(bag.hasErrors == false)
    let bval = analysed.symbols.labels["BVAL"]!
    let wval = analysed.symbols.labels["WVAL"]!
    #expect(bval % 4 == 0)          // STORAGE's own AREA alignment.
    #expect(wval != bval + 1)       // Not "one byte later."
    #expect(wval == bval + 4)       // Rounded up to the next 4-byte boundary.
}

// MARK: - Review fix round: EQU pre-pass so SPACE/ALIGN can see constants

@Test func analyserResolvesASpaceSizeDefinedByAnEarlierEqu() {
    // Regression for review finding 1: `symbols.constants` is populated only in
    // pass 1b, which runs after the whole pass-1 layout loop finishes — so a SPACE
    // whose size names an EQU'd constant fails with a misleading "not defined" even
    // when the EQU is a *backward* reference (defined lexically above the SPACE).
    // `SIZE EQU 4` / `BUF SPACE SIZE` is ordinary ARMASM idiom, so this must resolve,
    // and AFTER's address must reflect a real 4-byte advance, not a swallowed size.
    let (analysed, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
        AREA STORAGE, DATA, READONLY
    SIZE EQU 4
    BUF SPACE SIZE
    AFTER DCB &FF
    """)
    #expect(bag.hasErrors == false)
    #expect(bag.diagnostics.map(\.code).contains("E031") == false)
    let buf = analysed.symbols.labels["BUF"]!
    let after = analysed.symbols.labels["AFTER"]!
    #expect(after == buf + 4)
}

@Test func analyserAlignAmountDefinedByAnEarlierEquResolves() {
    // Same gap, ALIGN's side: the amount expression is evaluated in pass 1, before
    // pass 1b binds constants, so a backward-referencing EQU used as an ALIGN amount
    // hit the identical bug. Symmetric coverage to the SPACE case above.
    let (analysed, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
        AREA STORAGE, DATA, READONLY
    EIGHT EQU 8
    BVAL DCB &FF
        ALIGN EIGHT
    AFTER DCB &FF
    """)
    #expect(bag.hasErrors == false)
    #expect(bag.diagnostics.map(\.code).contains("E031") == false)
    let after = analysed.symbols.labels["AFTER"]!
    #expect(after % 8 == 0)
}

@Test func analyserStillDiagnosesAGenuinelyUndefinedSpaceSize() {
    // The EQU pre-pass evaluates into a scratch, discarded DiagnosticBag specifically
    // so a forward reference to a *label* (which legitimately cannot resolve before
    // layout) produces no spurious pre-pass diagnostic. That must not become a hole
    // that swallows real errors: a SPACE size naming a symbol that is never defined
    // anywhere still has to reach the real bag with E031 from pass 1's own evaluation.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
        AREA STORAGE, DATA, READONLY
    BUF SPACE NOPE
    """)
    #expect(bag.diagnostics.map(\.code).contains("E031"))
}

@Test func analyserEquReferencingALabelStillResolvesInPass1b() {
    // Guards the other direction: the pre-pass must not let a label-referencing EQU
    // bind early to a bogus value (labels don't exist yet when the pre-pass runs, so
    // its scratch-bag evaluation of this EQU necessarily fails and is discarded).
    // Pass 1b, which runs after every label is bound, must still resolve it correctly
    // — OFFSET must equal VALUE1's real address, not be missing or wrong.
    let (analysed, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
        AREA STORAGE, DATA, READONLY
    VALUE1 DCD &00000012
    OFFSET EQU VALUE1
    """)
    #expect(bag.hasErrors == false)
    #expect(analysed.symbols.constants["OFFSET"] == analysed.symbols.labels["VALUE1"])
}

// MARK: - Review fix round: DCW and SPACE had zero coverage

@Test func analyserAlignsDCWToTwoAndAdvancesByTwoPerHalfword() {
    // DCW had no test anywhere in the repo. Pins both address-arithmetic rules at
    // once: a 1-byte DCB leaves the cursor odd, so the following DCW must round up
    // to the next *even* address (not sit one byte later, and not over-round to a
    // 4-byte boundary the way DCD does) — and two halfwords must advance the cursor
    // by exactly 4, asserted on a label placed right after. Also pins little-endian
    // byte order for DCW specifically, not just DCD.
    let (analysed, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
        AREA STORAGE, DATA, READONLY
    BVAL DCB &FF
    HVAL DCW &1234, &5678
    AFTER DCB &FF
    """)
    #expect(bag.hasErrors == false)
    let bval = analysed.symbols.labels["BVAL"]!
    let hval = analysed.symbols.labels["HVAL"]!
    let after = analysed.symbols.labels["AFTER"]!
    #expect(hval == bval + 2)   // Rounds up to the next even address, not bval + 1.
    #expect(after == hval + 4) // Two halfwords, 2 bytes each.
    let blob = analysed.dataImage.first { $0.address == hval }
    #expect(blob?.bytes == [0x34, 0x12, 0x78, 0x56])
}

@Test func analyserAdvancesExactlyNByteCountForSpace() {
    // SPACE had no test anywhere in the repo either. A SPACE 10 between two labels
    // must advance the cursor by exactly 10 — catches an off-by-one (e.g. reserving
    // n+1 or n-1 bytes) that a `hasErrors == false`-only assertion would never see.
    let (analysed, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
        AREA STORAGE, DATA, READONLY
    BEFORE SPACE 10
    AFTER DCB &FF
    """)
    #expect(bag.hasErrors == false)
    let before = analysed.symbols.labels["BEFORE"]!
    let after = analysed.symbols.labels["AFTER"]!
    #expect(after == before + 10)
}

@Test func analyserAlignZeroFromSourceDoesNotHangOrCrash() {
    // Termination guard: `align(_:to:)` must not divide by zero or spin when the
    // boundary is 0 or 1 — including when `ALIGN 0` reaches it straight from
    // source, not just as a hardcoded default. A wrong implementation computing
    // `value % boundary` without guarding `boundary <= 1` would trap here.
    let (analysed, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
        ALIGN 0
        MOV R2, R1
    """)
    #expect(bag.hasErrors == false)
    let instructionAddresses = analysed.addresses.values.sorted()
    // ALIGN 0 is a no-op boundary; the second MOV sits immediately after the first.
    #expect(instructionAddresses == [Analyser.origin, Analyser.origin + 4])
}
