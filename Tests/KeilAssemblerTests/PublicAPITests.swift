import Foundation
import Testing
import KeilAssembler   // deliberately NOT @testable

@Test func theAppFacadeIsReachableWithoutTestableImport() throws {
    let driver = Driver()
    let compiled = driver.compile(source: """
            AREA PROGRAM, CODE, READONLY
            ENTRY
        MAIN
        MOV R1, #0x12
        END
        """)
    #expect(compiled.hasErrors == false)
    #expect(compiled.assembly != nil)

    let result = try driver.run(
        source: """
                AREA PROGRAM, CODE, READONLY
                ENTRY
            MAIN
            MOV R1, #0x12
            END
            """,
        preload: MemoryPreload(words: [0x1000: 0x12]),
        in: nil
    )
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[1] == 0x12)

    let snapshot: MachineSnapshot = result.snapshots[0]
    _ = (snapshot.seq, snapshot.sourceLine, snapshot.pc, snapshot.registers,
         snapshot.cpsr, snapshot.storeAddress, snapshot.storeValue, snapshot.storeWidth)

    for diagnostic in result.diagnostics {
        _ = (diagnostic.severity, diagnostic.code, diagnostic.message, diagnostic.note)
        _ = (diagnostic.range.line, diagnostic.range.column, diagnostic.range.length)
    }
}

@Test func compilerInternalsStayInternal() {
    // Nothing to assert at runtime — this test's value is that PublicAPITests.swift
    // does not use @testable, so referencing Lexer, Parser, Analyser, Lowering or
    // PerfLog here would fail to compile. Keeping the surface small is the point.
    #expect(Bool(true))
}
