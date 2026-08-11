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
