import Foundation
import Testing
@testable import KeilAssembler

/// Regression test for a deadlock in `Driver.invokeCapturing` (Spec §7.9 process
/// plumbing), found while adding Task 19's corpus tests.
///
/// The pipe-draining code used to hand stdout to
/// `DispatchQueue.global(qos: .utility).async { readDataToEndOfFile() }` while the
/// calling thread blocked in `drainGroup.wait()`. That async closure needs a worker
/// thread of its own to even start running, drawn from the same small, fixed-size
/// pool Swift Testing uses to run concurrent `@Test`s. Once enough concurrent
/// `Driver`-based tests filled every pool thread with a thread parked in
/// `drainGroup.wait()`, the drain closures could never be scheduled and every
/// in-flight `invokeCapturing` call hung forever — confirmed with `sample` on a
/// wedged `swift test --filter CorpusTests` run, which showed every
/// cooperative-pool thread parked in `_dlock_wait` at that call site. Four corpus
/// tests never filled the pool; Task 19 grew the corpus past the point that does.
///
/// The fix drains both pipes with `readabilityHandler`, which is driven by a kqueue
/// readiness notification rather than a thread blocked in a `read()` syscall, so it
/// cannot be starved regardless of how many invocations run at once. This test
/// reproduces the concurrency load that exposed the deadlock: it hung indefinitely
/// before the fix and completes in well under a second after it.
@Test func manyConcurrentRunsDoNotDeadlock() async throws {
    let source = """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R1, #0X12
    MOV R2, R1
    END
    """
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<12 {
            group.addTask {
                let result = try Driver().run(source: source, preload: MemoryPreload())
                #expect(result.finalRegisters[1] == 0x12)
                #expect(result.finalRegisters[2] == 0x12)
            }
        }
        try await group.waitForAll()
    }
}
