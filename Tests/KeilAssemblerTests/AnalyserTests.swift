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
