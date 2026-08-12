import Darwin
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

// MARK: - Semantic diagnostics (Task 11)

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

// MARK: - Strengthening beyond the brief

@Test func modifiedImmediateRejectsValuesRequiringMoreThanEightSetBits() {
    // Pins the mask check itself: a wrong implementation that only checked whether
    // *some* rotation reduced the value below 256 (e.g. `rotated < 0x100` on a signed
    // read, or a mask of `~0xFF` applied before rotating) could wrongly accept a value
    // whose bits are simply spread too far apart to ever land in one 8-bit window.
    // 0x101 (bits 0 and 8) can never be brought within 8 contiguous bits by *any*
    // rotation, even or odd — this is the "no rotation at all works" case, distinct
    // from the "only an odd rotation works" case below.
    #expect(Analyser.isEncodableModifiedImmediate(0x101) == false)
    #expect(Analyser.isEncodableModifiedImmediate(0xFFFF_FFFF) == false)
}

@Test func modifiedImmediateRejectsAValueThatOnlyAnOddRotationCanReach() {
    // 0x1FE is eight *contiguous* set bits (bits 1..8), so it fits an 8-bit window —
    // but only by rotating right 1 (odd). A wrong implementation that iterated over
    // odd rotations too (e.g. `stride(from: 0, to: 32, by: 1)`, or a fence-post error
    // extending the `by: 2` stride one step too far) would wrongly accept this.
    #expect(Analyser.isEncodableModifiedImmediate(0x1FE) == false)
}

@Test func modifiedImmediateAcceptsZeroAndRejectsEveryBitSet() {
    // 0 is the trivial rotation-0 case; a wrong implementation of the loop bound or
    // the `& ~0xFF` mask could special-case it wrong in either direction. All-ones
    // needs all 32 bits, which is far beyond any single rotated 8-bit value.
    #expect(Analyser.isEncodableModifiedImmediate(0x0))
    #expect(Analyser.isEncodableModifiedImmediate(0xFFFF_FFFF) == false)
}

@Test func modifiedImmediateAcceptsTheHighestEvenRotation() {
    // 0x1 rotated right by 30 (the last rotation the loop visits, since the stride
    // stops before 32) is 0x4 — 1 rotated right by 2 == ROL(1, 30). A wrong
    // implementation with an off-by-one loop bound (`to: 30` instead of `to: 32`,
    // dropping rotation 30 entirely) would miss exactly this case.
    #expect(Analyser.isEncodableModifiedImmediate(0x4))
}

@Test func analyserAcceptsAnEncodableImmediateWithNoDiagnostic() {
    // The positive twin of analyserRejectsAnUnencodableImmediate: an encodable
    // immediate must produce *no* E020, and no diagnostic at all. Without this, a
    // wrong implementation that always emitted E020 regardless of encodability (or
    // that dropped the `!isEncodableModifiedImmediate` negation) would still pass
    // the rejection test above but flag every immediate as an error.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #0x12
    """)
    #expect(bag.hasErrors == false)
    #expect(bag.diagnostics.isEmpty)
}

@Test func analyserPreservesAnUndefinedSymbolDiagnosticInAnImmediateOperand() {
    // Pins the diagnostics-dance around evaluating an immediate operand's expression:
    // ExpressionEvaluator.evaluate already emits E031 for an undefined symbol and
    // returns nil. A wrong ordering of `diagnostics = scratch` versus the E020 emit
    // could either lose that E031 (assigning `diagnostics = scratch` before scratch
    // is populated, or never assigning it on the nil path) or duplicate it (emitting
    // into `diagnostics` *and* keeping `scratch`'s copy). Exactly one E031, and no
    // spurious E020 riding along with it (an evaluation failure is not the same as an
    // unencodable-but-known value).
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #NOPE
    """)
    #expect(bag.diagnostics.map(\.code) == ["E031"])
}

@Test func analyserDoesNotWarnAboutShifterCarryWhenFlagsAreNotSet() {
    // The negative twin of analyserWarnsAboutUnmodelledShifterCarry: a shifted
    // Operand2 on a plain (non-S) MOV never sets flags, so C is never read from the
    // shifter in the first place — W010 would be a false positive here. A wrong
    // implementation that warned on any shifted operand regardless of `setsFlags`
    // (or that mixed up `&&` for `||`, e.g. requiring flags-set *and* comparison)
    // would fail this.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R3, R1, LSL #2
    """)
    #expect(bag.diagnostics.map(\.code).contains("W010") == false)
}

@Test func analyserWarnsAboutShifterCarryOnTstEvenWithoutTheSSuffix() {
    // TST/TEQ always set flags whether or not `S` is written (Spec §6.3), and they
    // are in D1's "logical" family that sources C from the shifter — so
    // `instruction.setsFlags` alone is not enough to gate W010 for them. A wrong
    // implementation that only tested `setsFlags` would miss this, since the parser
    // never sets `setsFlags` true for an unsuffixed TST.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        TST R1, R2, LSL #2
    """)
    #expect(bag.diagnostics.map(\.code).contains("W010"))
}

@Test func analyserDoesNotWarnAboutShifterCarryOnCmpOrAdds() {
    // Spec §9 D1, verbatim: "ADDS/SUBS/CMP/CMN are unaffected — their C and V come
    // from the ALU and match exactly." A wrong implementation that gated W010 on
    // `mnemonic.isComparison` (cmp/cmn/tst/teq) rather than the exact logical-family
    // list D1 names would wrongly warn on CMP and ADDS here, since `isComparison`
    // lumps CMP in with TST/TEQ despite the spec explicitly excluding it.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        CMP R1, R2, LSL #2
        ADDS R3, R1, R2, LSL #2
    """)
    #expect(bag.diagnostics.map(\.code).contains("W010") == false)
}

@Test func analyserWarnsAboutAShiftAmountOfExactlyThirtyTwo() {
    // Pins the >= 32 boundary exactly (not > 32): 32 itself must warn. A wrong
    // implementation guarding `> 32` instead of `>= 32` would silently accept it,
    // even though A64's lslv wraps a shift-by-32 to a no-op while ARM7 saturates
    // to zero — the two disagree right at this boundary.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, R2, LSL #32
    """)
    #expect(bag.diagnostics.map(\.code).contains("W012"))
}

@Test func analyserDoesNotWarnAboutAShiftAmountJustBelowThirtyTwo() {
    // The boundary's negative twin: 31 must not warn. Without this, a test only
    // checking the >= 32 side could pass a wrong implementation that warns on
    // every shift regardless of amount (e.g. dropping the `value >= 32` condition
    // entirely).
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, R2, LSL #31
    """)
    #expect(bag.diagnostics.map(\.code).contains("W012") == false)
}

@Test func analyserDoesNotCrashOnAShiftAmountThatFailsToEvaluate() {
    // The shift-amount dance's failure path: an undefined symbol as the shift amount
    // must surface its own E031 (from ExpressionEvaluator) without the W012 check
    // then force-unwrapping a nil value amount into the `value >= 32` comparison.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, R2, LSL #NOPE
    """)
    #expect(bag.diagnostics.map(\.code) == ["E031"])
}

@Test func analyserDoesNotFlagR15AsAnOrdinaryDestinationRegister() {
    // Spec §7.5 explicitly sanctions `MOV PC, LR` (alongside `BX LR`) as the return
    // idiom the backend lowers. R15 there is *written*, not read as data — D2's rule
    // ("reading R15 as a data operand is E021") does not apply to a destination.
    // A wrong implementation that flags any bare `.register(15)` regardless of
    // operand position — which is what the naive "every operand" loop does — would
    // reject this legitimate, spec-mandated instruction.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV PC, LR
    """)
    #expect(bag.diagnostics.map(\.code).contains("E021") == false)
}

@Test func analyserFlagsR15AsAComparisonSourceRegister() {
    // CMP/CMN/TST/TEQ have no destination — their first operand is Rn, a genuine
    // read (Spec §6.3: "Rn, Operand2 for the compare forms"). The MOV-PC-LR carve-out
    // above must not overreach into exempting operand[0] for these mnemonics too,
    // or a read of R15 through CMP would silently produce a wrong, unmodelled value.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        CMP R15, #4
    """)
    #expect(bag.diagnostics.map(\.code).contains("E021"))
}

@Test func analyserFlagsR15AsTheBaseOfAShiftedOperand() {
    // Spec §9 D2 is a blanket rule ("reading R15 as a data operand is E021"), not
    // scoped to just the immediate/bare-register Operand2 forms. A shifted operand's
    // *base* register is still read as data before the shift is applied — a wrong
    // implementation that pattern-matched `.shifted(_, let shift)` and discarded the
    // register entirely (as the plan's own sample code does) would let this through
    // with no diagnostic at all.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        ADD R1, R2, R15, LSL #2
    """)
    #expect(bag.diagnostics.map(\.code).contains("E021"))
}

// MARK: - Review fix round: register-specified shift count and MOVS PC, LR

@Test func analyserFlagsR15AsARegisterSpecifiedShiftCount() {
    // Spec §9 D2's blanket rule ("reading R15 as a data operand is E021") covers a
    // shift *count* supplied by a register (`Rm, LSL Rs`) too, not just the shifted
    // operand's base register. `ShiftSpec.amountRegister` is real, parseable input
    // (`ADD R1, R2, R3, LSL R15`), but the `.shifted` case only ever inspected the
    // base `register`, never `shift.amountRegister` — so this read of R15 as a shift
    // count reached the analyser and was accepted with zero diagnostics, silently
    // producing a wrong shift amount downstream. A wrong implementation that still
    // only checks the base register would pass every other R15 test in this file
    // while missing this one.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        ADD R1, R2, R3, LSL R15
    """)
    #expect(bag.diagnostics.map(\.code).contains("E021"))
}

@Test func analyserDoesNotExemptMovsPcLrFromR15Checking() {
    // The `MOV PC, LR` carve-out exists for exactly the unsuffixed return idiom Spec
    // §7.5 names. `MOVS PC, LR` is a different instruction: on real ARM7 the `S`
    // additionally restores CPSR from SPSR, and Spec §9 D6 states plainly that this
    // transpiler models no banked registers and no SPSR — so silently lowering
    // `MOVS PC, LR` as a plain return would drop that restore with no diagnostic at
    // all. A wrong implementation that checks `mnemonic == .mov` without also
    // requiring `!setsFlags` would exempt this alongside the legitimate idiom.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOVS PC, LR
    """)
    #expect(bag.diagnostics.map(\.code).contains("E021"))
}

@Test func analyserStillAcceptsThePlainMovPcLrIdiom() {
    // Pins the carve-out from the other side once `!instruction.setsFlags` is added:
    // the legitimate, unsuffixed `MOV PC, LR` must still produce no E021. Without
    // this, a wrong fix could overcorrect (e.g. dropping the carve-out entirely)
    // and reject the return idiom Spec §7.5 requires to keep working.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV PC, LR
    """)
    #expect(bag.diagnostics.map(\.code).contains("E021") == false)
}

@Test func analyserRejectsAComputedBranchThroughARegisterOtherThanLR() {
    // Spec §7.5: only `BX LR` is lowered; any other `BX Rm` is E014. Because a
    // single-operand instruction's sole register always parses as the *trailing*
    // Operand2 form (`.operand2(.register(n))`, never bare `.register(n)` — see
    // `Parser.registerIsTrailingOperand2`, which returns true at end-of-line), a
    // check written against `case .register(let register)? = operands.first` can
    // never match a real BX instruction and would silently never fire.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        BX R0
    """)
    #expect(bag.diagnostics.map(\.code).contains("E014"))
}

@Test func analyserAcceptsBxLrWithNoDiagnostic() {
    // The positive twin: `BX LR` is the one form that must never be flagged.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        BX LR
    """)
    #expect(bag.diagnostics.map(\.code).contains("E014") == false)
    #expect(bag.hasErrors == false)
}

// MARK: - Final fix wave: Critical 1 — `Analyser.check` had no `.registerList` case

@Test func analyserRejectsPushingR15() {
    // `Analyser.check`'s operand loop has no `.registerList` case at all, so a
    // register list — PUSH/POP/STMFD/LDMFD's only operand — is never inspected
    // for R15, unlike every other operand shape. `PUSH {R4, PC}` genuinely
    // *reads* R15's value (to store it), the same kind of read Spec §9 D2
    // already forbids for every other operand shape (`ADD R1, R15, #4`, etc.),
    // so it must get the same E021, not silently pass through with a phantom
    // register value stored to memory.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        PUSH {R4, PC}
    """)
    #expect(bag.diagnostics.map(\.code).contains("E021"))
}

@Test func analyserRejectsStmfdOfR15Too() {
    // Symmetric coverage for STMFD, the other "push"-shaped register-list form.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        STMFD SP!, {R4, PC}
    """)
    #expect(bag.diagnostics.map(\.code).contains("E021"))
}

@Test func analyserAcceptsPoppingIntoR15WithNoDiagnostic() {
    // `POP {..., PC}` is the canonical ARM subroutine return (the natural
    // partner to `PUSH {..., LR}`) — R15 there is a *destination*, lowered as
    // the real function return (Spec §7.5), not a data read. It must not be
    // flagged the way PUSH-of-R15 is.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        PUSH {R4, LR}
        POP {R4, PC}
    """)
    #expect(bag.diagnostics.map(\.code).contains("E021") == false)
    #expect(bag.hasErrors == false)
}

// MARK: - Final fix wave: MVN was missing from the shifter-carry (Spec §9 D1) set

@Test func analyserWarnsAboutUnmodelledShifterCarryOnMvns() {
    // Spec §9 D1 names MOVS, ANDS, ORRS, EORS, BICS, TST, TEQ. MVN is a
    // data-processing mnemonic with a flag-setting form and a shifted operand
    // just like MOV, sourcing carry from the same barrel shifter on real
    // ARM7 — but `.mvn` was missing from `sourcesCarryFromShifter`'s switch, so
    // `MVNS Rd, Rm, LSL #2` fell to `default: false` and got no W010 at all.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MVNS R3, R1, LSL #2
    """)
    #expect(bag.diagnostics.map(\.code).contains("W010"))
}

// MARK: - Final fix wave: EQU must not silently resolve '.' against a bogus position

@Test func equRejectsAReferenceToTheCurrentPosition() {
    // Spec §5.2's EQU pass evaluates every EQU with `here: 0` — pass 1 tracks a
    // real per-line position for DCB/DCW/DCD/SPACE (`dataAddresses`), but EQU
    // has no position of its own and none is threaded through. `X EQU . + 4`
    // therefore silently resolved to 4, not to any position an implementer
    // reading the source would expect. Reject '.' inside an EQU expression
    // instead of guessing against address 0.
    let (_, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
    X EQU . + 4
    """)
    #expect(bag.diagnostics.map(\.code).contains("E043"))
}

@Test func equWithoutAHereReferenceStillResolvesNormally() {
    // Negative twin: an ordinary EQU with no '.' anywhere in its expression
    // must not be caught by the new check.
    let (analysed, bag) = analyse("""
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
    SIZE EQU 4 + 4
    """)
    #expect(bag.diagnostics.map(\.code).contains("E043") == false)
    #expect(analysed.symbols.constants["SIZE"] == 8)
}

// MARK: - Final fix wave: pass 0's scratch bag must not print a phantom diagnostic

/// Raw POSIX pipe/dup2, not `Foundation.Pipe`: this test target must not import
/// Foundation at all — `Foundation.Expression` (macOS 15's Predicate type)
/// collides with this package's own `Expression` (Spec §5.1 AST node) and makes
/// every `.binary(...)`/`.integer(...)` case-shorthand in this file ambiguous.
private func captureStandardOutput(_ body: () -> Void) -> String {
    fflush(stdout)
    var fds: [Int32] = [0, 0]
    pipe(&fds)
    let readEnd = fds[0]
    let writeEnd = fds[1]
    let originalStdout = dup(STDOUT_FILENO)
    dup2(writeEnd, STDOUT_FILENO)
    close(writeEnd)

    body()

    fflush(stdout)
    dup2(originalStdout, STDOUT_FILENO)   // restores stdout and closes the write end's last reference
    close(originalStdout)

    var captured = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(readEnd, &buffer, buffer.count)
        guard count > 0 else { break }
        captured.append(contentsOf: buffer[0..<count])
    }
    close(readEnd)
    return String(decoding: captured, as: UTF8.self)
}

@Test func passZeroDoesNotLogAPhantomDiagnosticForALabelReferencingEqu() {
    // Spec §5.2 pass 0 (the EQU pre-pass): a label-referencing EQU legitimately
    // cannot resolve yet (labels aren't bound until pass 1 finishes), so pass 0
    // evaluates into a scratch `DiagnosticBag` specifically so that failure is
    // discarded and never surfaced. But `DiagnosticBag.emit` unconditionally
    // calls `PerfLog.error`, coupling storage to logging — so even a
    // *discarded* scratch diagnostic still prints "E031 ... is not defined" to
    // the console during an entirely clean build. The probe symbol name is
    // unique to this test so a concurrently-running test's own, legitimate
    // logging can't coincidentally contain it.
    let source = """
        AREA PROGRAM, CODE, READONLY
        ENTRY
    MAIN
        MOV R1, #1
        AREA STORAGE, DATA, READONLY
    ZZZ_PASS0_PHANTOM_PROBE DCD &00000012
    OFFSET EQU ZZZ_PASS0_PHANTOM_PROBE
    """
    let output = captureStandardOutput {
        let (_, bag) = analyse(source)
        #expect(bag.hasErrors == false)
    }
    #expect(output.contains("ZZZ_PASS0_PHANTOM_PROBE") == false)
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
