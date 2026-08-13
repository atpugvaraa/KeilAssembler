import Testing
@testable import KeilAssembler

/// Weak by nature — this machine has a working toolchain, so it can only assert
/// the passing case. Its value is catching a probe that is itself broken: wrong
/// clang arguments, an unwritable temp directory, a status read from the wrong
/// process. Those are the realistic ways `preflight` starts lying.
@Test func preflightSucceedsOnAMachineThatCanRunTheSuite() {
    #expect(Driver().preflight() == .ready)
}
