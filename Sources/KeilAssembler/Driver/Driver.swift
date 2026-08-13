import Foundation

public enum ToolchainStatus: Sendable, Equatable {
    case ready
    /// Carries clang's own stderr, so a failure that isn't the expected missing-CLT
    /// one is still diagnosable rather than being flattened into "something broke".
    case missing(reason: String)
}

public struct CompileResult: Sendable {
    public let diagnostics: [Diagnostic]
    public let assembly: String?
    public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
}

public struct RunResult: Sendable {
    public let snapshots: [MachineSnapshot]
    public let diagnostics: [Diagnostic]
    public let exitCode: Int32
    public let standardError: String
    /// The directory this run's executable, `image.bin`, and `trace.bin` live
    /// in (Spec §7.9). `Driver.run` deletes its own auto-created directory on
    /// a successful (exit code 0) run — this is only useful for a caller-
    /// supplied directory, or for inspecting a failed run before cleaning up.
    public let runDirectory: URL
    /// The analysed program's data image, then `preload.entries` in that order —
    /// a preload entry overwrites a `DCD` at the same address (Spec §5.3). Fed to
    /// `MemoryImage.init(initial:)`/`folding(initial:...)` by a caller wanting to
    /// show ARM7 memory rather than just registers.
    public let initialMemory: [(address: UInt32, bytes: [UInt8])]

    /// The register state after the last executed instruction, or all zeros.
    public var finalRegisters: [UInt32] {
        snapshots.last?.registers ?? [UInt32](repeating: 0, count: 16)
    }
}

/// Spec §7.9. Each run gets its own directory holding the executable, `image.bin`,
/// and `trace.bin`, so runs never collide and a run is reproducible from its
/// directory alone.
public struct Driver: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case toolFailed(tool: String, status: Int32, output: String)
        case runtimeSourceMissing
        case compilationProducedNoAssembly([Diagnostic])

        public var description: String {
            switch self {
            case .toolFailed(let tool, let status, let output):
                "\(tool) exited \(status): \(output)"
            case .runtimeSourceMissing:
                "armd_rt.c is missing from the package bundle"
            case .compilationProducedNoAssembly(let diagnostics):
                "compilation failed: " + diagnostics
                    .filter { $0.severity == .error }
                    .map { "\($0.code) \($0.range) \($0.message)" }
                    .joined(separator: "; ")
            }
        }
    }

    let clangURL = URL(fileURLWithPath: "/usr/bin/clang")

    public init() {}

    public func compile(source: String) -> CompileResult {
        var diagnostics = DiagnosticBag()
        let tokens = Lexer(source: source).tokenize(into: &diagnostics)
        var parser = Parser(tokens: tokens)
        let program = parser.parse(into: &diagnostics)
        let analysed = Analyser.analyse(program, into: &diagnostics)
        let assembly = Lowering.lower(analysed, into: &diagnostics)
        return CompileResult(diagnostics: diagnostics.diagnostics, assembly: assembly)
    }

    public func run(
        source: String,
        preload: MemoryPreload,
        in directory: URL? = nil
    ) throws -> RunResult {
        var diagnostics = DiagnosticBag()
        let tokens = Lexer(source: source).tokenize(into: &diagnostics)
        var parser = Parser(tokens: tokens)
        let program = parser.parse(into: &diagnostics)
        let analysed = Analyser.analyse(program, into: &diagnostics)
        guard let assembly = Lowering.lower(analysed, into: &diagnostics) else {
            throw Failure.compilationProducedNoAssembly(diagnostics.diagnostics)
        }

        // Spec §7.9: an auto-created directory is this call's own temp scratch
        // space and gets cleaned up on success below; a caller-supplied one is
        // caller-owned and must never be touched, successful run or not.
        let ownsDirectory = directory == nil
        let runDirectory = try directory ?? makeRunDirectory()
        PerfLog.info("run directory: \(runDirectory.path)")

        let assemblyURL = runDirectory.appendingPathComponent("program.s")
        try assembly.write(to: assemblyURL, atomically: true, encoding: .utf8)

        try StartupImage
            .encode(dataImage: analysed.dataImage, preload: preload)
            .write(to: runDirectory.appendingPathComponent("image.bin"))

        // The runtime ships as `armd_rt.c.txt`, not `armd_rt.c`. Xcode's SwiftPM
        // integration classifies a `.c` file inside a target as a source to compile
        // and drops it from the resource bundle, so an app embedding this package
        // found a bundle holding nothing but Info.plist — while `swift test`, which
        // honours `.copy`, passed. The `.txt` extension keeps Xcode's source scanner
        // off it.
        //
        // clang infers the language from the extension, so it is written back out as
        // `armd_rt.c` into the run directory beside `program.s` and `image.bin`.
        guard let runtimeResource = Bundle.module.url(forResource: "armd_rt.c", withExtension: "txt") else {
            PerfLog.error("armd_rt.c.txt not found in Bundle.module")
            throw Failure.runtimeSourceMissing
        }
        let runtimeURL = runDirectory.appendingPathComponent("armd_rt.c")
        try Data(contentsOf: runtimeResource).write(to: runtimeURL)

        let executableURL = runDirectory.appendingPathComponent("program")
        try PerfLog.measure("assemble-and-link") {
            try invoke(clangURL, arguments: Self.clangBuildArguments(
                executable: executableURL.path,
                assembly: assemblyURL.path,
                runtime: runtimeURL.path
            ), in: runDirectory, tool: "clang")
        }

        let execution = try PerfLog.measure("run") {
            try invokeCapturing(executableURL, arguments: [], in: runDirectory)
        }

        let traceURL = runDirectory.appendingPathComponent("trace.bin")
        let traceData = (try? Data(contentsOf: traceURL)) ?? Data()
        let snapshots = try TraceDecoder.decode(traceData)

        // A successful run has no further debugging use for its own auto-created
        // directory; a failing one (nonzero exit — a crash, since nothing in this
        // subset can fail any other way) is exactly when its contents are worth
        // keeping for a postmortem. `try?`: cleanup failing must never turn a
        // successful run into a thrown error.
        if ownsDirectory, execution.status == 0 {
            try? FileManager.default.removeItem(at: runDirectory)
        }

        return RunResult(
            snapshots: snapshots,
            diagnostics: diagnostics.diagnostics,
            exitCode: execution.status,
            standardError: execution.errorOutput,
            runDirectory: runDirectory,
            initialMemory: analysed.dataImage.map { (address: $0.address, bytes: $0.bytes) } + preload.entries
        )
    }

    /// The `clang` invocation that assembles the lowered `.s` file together with
    /// `armd_rt.c` into the run's executable (Spec §7.9). `-Wall -Wextra`: the
    /// generated assembly and the runtime should build clean under real
    /// warnings, not just "no errors" — this doesn't add `-Werror`, so a warning
    /// still can't fail the build, only surface in `standardError`.
    static func clangBuildArguments(executable: String, assembly: String, runtime: String) -> [String] {
        ["-Wall", "-Wextra", "-o", executable, assembly, runtime]
    }

    /// Whether this Mac can actually build, checked by building.
    ///
    /// `/usr/bin/clang` exists on a stock macOS install without Command Line
    /// Tools — it is a shim that fails at run time with "xcode-select: note: no
    /// developer tools were found". A path check therefore passes on a machine
    /// where every build fails. Compiling a trivial program exercises the exact
    /// dependency `run` has, so there is nothing left to guess about.
    public func preflight() -> ToolchainStatus {
        do {
            let directory = try makeRunDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("probe.c")
            try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
            let result = try invokeCapturing(clangURL, arguments: [
                "-o", directory.appendingPathComponent("probe").path, source.path
            ], in: directory)
            if result.status != 0 {
                PerfLog.error("preflight failed: \(result.errorOutput)")
                return .missing(reason: result.errorOutput)
            }
            return .ready
        } catch {
            PerfLog.error("preflight threw: \(error)")
            return .missing(reason: String(describing: error))
        }
    }

    // MARK: - Process plumbing

    private func makeRunDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("armd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func invoke(_ url: URL, arguments: [String], in directory: URL, tool: String) throws {
        let result = try invokeCapturing(url, arguments: arguments, in: directory)
        guard result.status == 0 else {
            PerfLog.error("\(tool) failed (\(result.status)): \(result.errorOutput)")
            throw Failure.toolFailed(tool: tool, status: result.status, output: result.errorOutput)
        }
    }

    private func invokeCapturing(
        _ url: URL, arguments: [String], in directory: URL
    ) throws -> (status: Int32, errorOutput: String) {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = outputPipe

        // Both pipes must be drained concurrently, not one after the other: a
        // child that writes more than the pipe's kernel buffer (~64 KiB) to
        // stdout blocks on write() until someone reads it. Reading only
        // stderr here would deadlock the moment a linked program — clang
        // included — ever produced that much stdout, since this thread
        // would sit reading stderr while the child sat blocked writing to
        // stdout, with neither side able to proceed to waitUntilExit().
        //
        // An earlier version drained stdout with
        // `DispatchQueue.global(qos: .utility).async { readDataToEndOfFile() }`.
        // That deadlocks under heavy concurrency: the async block needs a
        // worker thread of its own to even start, drawn from the same
        // small, fixed-size pool that Swift Testing's parallel test
        // execution uses for the *calling* thread. Once enough concurrent
        // Driver-based tests exist to fill every pool thread with a thread
        // blocked in this function (Task 19 was the first to grow the
        // corpus past that point — 4 tests never exhausted the pool, but
        // 14 does), the drain closures can never be scheduled and every
        // in-flight invocation deadlocks forever. Confirmed by `sample`ing
        // a hung `swift test --filter CorpusTests`: every cooperative-pool
        // thread was parked in `_dlock_wait` inside the old `drainGroup.wait()`.
        //
        // `readabilityHandler` avoids this because it is driven by a kqueue
        // readiness notification rather than a thread parked in a blocking
        // read() — it does not consume a thread from the pool while
        // waiting, so it cannot be starved by however many invocations are
        // running concurrently.
        final class Box: @unchecked Sendable { var data = Data() }
        let stderrBox = Box()
        let drainGroup = DispatchGroup()

        drainGroup.enter()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
                drainGroup.leave()
            }
        }

        drainGroup.enter()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                drainGroup.leave()
            } else {
                stderrBox.data.append(chunk)
            }
        }

        try process.run()
        process.waitUntilExit()
        drainGroup.wait()

        return (process.terminationStatus, String(data: stderrBox.data, encoding: .utf8) ?? "")
    }
}
