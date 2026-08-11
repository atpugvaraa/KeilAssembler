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
