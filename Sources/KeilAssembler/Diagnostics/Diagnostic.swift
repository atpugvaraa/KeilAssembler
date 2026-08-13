/// Spec §8. Errors are collected, not thrown: one build reports every error it can find.
public struct Diagnostic: Sendable, Equatable {
    public enum Severity: Sendable, Equatable { case error, warning, note }

    public let severity: Severity
    public let code: String        // "E020", "W001"
    public let message: String     // ARMASM vocabulary, not compiler-internal vocabulary
    public let range: SourceRange
    public let note: String?       // what to do instead
}

/// Accumulates diagnostics across a build. Spec §8: a build with any error emits no assembly.
struct DiagnosticBag: Sendable {
    private(set) var diagnostics: [Diagnostic] = []
    private(set) var hasErrors = false
    /// When false, `emit` still records the diagnostic (`diagnostics`/`hasErrors`
    /// behave identically) but skips the `PerfLog` call. For a scratch bag whose
    /// contents are discarded wholesale — Spec §5.2's EQU pre-pass being the one
    /// user today — routing through `PerfLog.error` unconditionally means a
    /// diagnostic that will never be shown to anyone still prints to the console
    /// on an otherwise clean build.
    private let logging: Bool

    init(logging: Bool = true) {
        self.logging = logging
    }

    mutating func emit(_ diagnostic: Diagnostic) {
        if diagnostic.severity == .error {
            hasErrors = true
            if logging { PerfLog.error("\(diagnostic.code) at \(diagnostic.range): \(diagnostic.message)") }
        } else {
            if logging { PerfLog.warning("\(diagnostic.code) at \(diagnostic.range): \(diagnostic.message)") }
        }
        diagnostics.append(diagnostic)
    }
}
