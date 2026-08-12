import Foundation

struct CompileResult: Sendable {
    let diagnostics: [Diagnostic]
    let assembly: String?
    var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
}

struct RunResult: Sendable {
    let snapshots: [MachineSnapshot]
    let diagnostics: [Diagnostic]
    let exitCode: Int32
    let standardError: String

    /// The register state after the last executed instruction, or all zeros.
    var finalRegisters: [UInt32] {
        snapshots.last?.registers ?? [UInt32](repeating: 0, count: 16)
    }
}

/// Spec §7.9. Each run gets its own directory holding the executable, `image.bin`,
/// and `trace.bin`, so runs never collide and a run is reproducible from its
/// directory alone.
struct Driver: Sendable {
    enum Failure: Error, CustomStringConvertible {
        case toolFailed(tool: String, status: Int32, output: String)
        case runtimeSourceMissing
        case compilationProducedNoAssembly([Diagnostic])

        var description: String {
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

    init() {}

    func compile(source: String) -> CompileResult {
        var diagnostics = DiagnosticBag()
        let tokens = Lexer(source: source).tokenize(into: &diagnostics)
        var parser = Parser(tokens: tokens)
        let program = parser.parse(into: &diagnostics)
        let analysed = Analyser.analyse(program, into: &diagnostics)
        let assembly = Lowering.lower(analysed, into: &diagnostics)
        return CompileResult(diagnostics: diagnostics.diagnostics, assembly: assembly)
    }

    func run(
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

        let runDirectory = try directory ?? makeRunDirectory()
        PerfLog.info("run directory: \(runDirectory.path)")

        let assemblyURL = runDirectory.appendingPathComponent("program.s")
        try assembly.write(to: assemblyURL, atomically: true, encoding: .utf8)

        try StartupImage
            .encode(dataImage: analysed.dataImage, preload: preload)
            .write(to: runDirectory.appendingPathComponent("image.bin"))

        guard let runtimeURL = Bundle.module.url(forResource: "armd_rt", withExtension: "c") else {
            PerfLog.error("armd_rt.c not found in Bundle.module")
            throw Failure.runtimeSourceMissing
        }

        let executableURL = runDirectory.appendingPathComponent("program")
        try PerfLog.measure("assemble-and-link") {
            try invoke(clangURL, arguments: [
                "-o", executableURL.path,
                assemblyURL.path,
                runtimeURL.path,
            ], in: runDirectory, tool: "clang")
        }

        let execution = try PerfLog.measure("run") {
            try invokeCapturing(executableURL, arguments: [], in: runDirectory)
        }

        let traceURL = runDirectory.appendingPathComponent("trace.bin")
        let traceData = (try? Data(contentsOf: traceURL)) ?? Data()
        let snapshots = try TraceDecoder.decode(traceData)

        return RunResult(
            snapshots: snapshots,
            diagnostics: diagnostics.diagnostics,
            exitCode: execution.status,
            standardError: execution.errorOutput
        )
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
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (process.terminationStatus, String(data: errorData, encoding: .utf8) ?? "")
    }
}
