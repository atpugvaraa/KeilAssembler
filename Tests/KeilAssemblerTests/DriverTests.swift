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
                #expect(result.exitCode == 0)
                #expect(result.finalRegisters[1] == 0x12)
                #expect(result.finalRegisters[2] == 0x12)
            }
        }
        try await group.waitForAll()
    }
}

// MARK: - Final fix wave: Important 3 — a crash must not discard buffered trace records

/// A subroutine that recurses into itself with no base case. Nothing in this
/// subset can make an ARM7-level memory access fail (Spec §7.8: the whole 4 GiB
/// space is one `mmap`), so unbounded recursion — consuming 16 bytes of *host*
/// stack per call for the BL-target prologue's `stp x29, x30, [sp, #-16]!` — is
/// the only legitimate ARM7 program that can crash the host process at all.
/// Used by both the buffering test below and the run-directory-retention test,
/// since both need a run whose exit code is genuinely nonzero.
private let recursiveCrashSource = """
    AREA PROGRAM, CODE, READONLY
    ENTRY

HELPER
BL HELPER
END
"""

@Test func aCrashDoesNotDiscardTraceRecordsWrittenBeforeIt() throws {
    // `armd_trace` (Spec §7.7/§7.8) opened `trace.bin` with `fopen`'s default
    // full buffering and only ever flushed it from `armd_fini` — which a crash
    // skips entirely. Full buffering flushes in ~4096-byte chunks, and 4096 is
    // not a multiple of the 96-byte trace record (Spec §7.7), so a crash mid
    // buffer either loses everything (if total output never reached one full
    // buffer) or leaves a trailing partial record — which `TraceDecoder.decode`
    // rejects outright (`Failure.truncated`) since its size guard requires an
    // exact multiple of 96. Either way, whatever *did* execute and trace before
    // the crash was lost — exactly the "0 snapshots" Important 2's own repro
    // hit on top of its own bug. Unbuffered writes (the fix) make every write()
    // a whole record, so decoding after a crash always succeeds.
    let result = try Driver().run(source: recursiveCrashSource, preload: MemoryPreload())
    defer { try? FileManager.default.removeItem(at: result.runDirectory) }   // crashed: kept, so clean up manually
    #expect(result.exitCode != 0)             // it really did crash
    #expect(result.snapshots.count > 0)       // and the trace survived anyway
}

// MARK: - Final fix wave: run directories should not accumulate forever

private let successfulRunSource = """
    AREA PROGRAM, CODE, READONLY
    ENTRY

MAIN
MOV R1, #0X12
END
"""

@Test func aSuccessfulRunDeletesItsOwnAutoCreatedRunDirectory() throws {
    // Every auto-created run directory (Spec §7.9: executable + image.bin +
    // trace.bin) was kept forever — 252 stale ones accumulated in $TMPDIR from
    // this suite alone. A successful run has no further debugging use for its
    // directory once its result has been read back.
    let result = try Driver().run(source: successfulRunSource, preload: MemoryPreload())
    #expect(result.exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: result.runDirectory.path) == false)
}

@Test func aFailingRunKeepsItsRunDirectoryForDebugging() throws {
    // The other half of the same fix: a run whose executable crashed is
    // exactly when the directory's contents (the assembly, the built binary,
    // whatever trace survived) are worth keeping for a postmortem.
    let result = try Driver().run(source: recursiveCrashSource, preload: MemoryPreload())
    #expect(result.exitCode != 0)
    #expect(FileManager.default.fileExists(atPath: result.runDirectory.path) == true)
    try? FileManager.default.removeItem(at: result.runDirectory)   // test cleanup
}

@Test func anExplicitlySuppliedRunDirectoryIsNeverDeleted() throws {
    // A caller-supplied directory is caller-owned; Driver must never delete
    // something it didn't create, successful run or not.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("armd-explicit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let result = try Driver().run(source: successfulRunSource, preload: MemoryPreload(), in: directory)
    #expect(result.exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: directory.path) == true)
}

// MARK: - Final fix wave: harden the clang invocation with real warnings

@Test func clangBuildArgumentsIncludeWallAndWextra() {
    // A missing warning flag doesn't change any corpus test's runtime
    // behaviour, so nothing else in this suite would ever catch a regression
    // here — armd_rt.c and the emitted assembly should build clean under real
    // warnings, not just "no errors".
    let arguments = Driver.clangBuildArguments(executable: "/tmp/out", assembly: "/tmp/a.s", runtime: "/tmp/rt.c")
    #expect(arguments.contains("-Wall"))
    #expect(arguments.contains("-Wextra"))
}
