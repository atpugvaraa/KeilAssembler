import Testing
@testable import KeilAssembler

/// Spec §7.5/§7.9: which of the two contexts a return sits in — a `BL` callee's
/// own frame (`ldp`/`ret`) or the top level's single host frame (`b Larmd_exit`) —
/// is a *reachability* property of the control-flow graph, not something any
/// lexical scan of the source can decide. Three successive lexical heuristics each
/// fixed one shape and broke another; this suite is the full shape matrix that
/// pins every one of them at once, run through the real `Driver` so a wrong
/// choice shows up as the SIGSEGV it actually is rather than as a text mismatch.
///
/// Every program here is *unambiguous*: no return in it is reachable both at top
/// level and inside a callee. The genuinely ambiguous case is at the bottom, and
/// it must produce `E044` rather than a guess.

private func run(_ body: String) throws -> RunResult {
    try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    \(body)
    END
    """, preload: MemoryPreload())
}

// MARK: - A: the exact repro — call, then an unconditional B past the callee

@Test func shapeAReturnsFromTheCalleeAndExitsAtTheTopLevelResumeLabel() throws {
    let result = try run("""
    MAIN
    MOV R4, #7
    BL HELPER
    B FINISH
    HELPER
    MOV R6, #2
    BX LR
    FINISH
    MOV R2, #9
    BX LR
    """)
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[4] == 7)
    #expect(result.finalRegisters[6] == 2)
    #expect(result.finalRegisters[2] == 9)
}

// MARK: - B: the callee is written before its caller

@Test func shapeBCalleeDefinedBeforeItsCallerStillReturns() throws {
    let result = try Driver().run(source: """
        AREA PROGRAM, CODE, READONLY

    HELPER
    MOV R6, #2
    BX LR
        ENTRY
    MAIN
    MOV R4, #7
    BL HELPER
    MOV R2, #9
    BX LR
    END
    """, preload: MemoryPreload())
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[4] == 7)
    #expect(result.finalRegisters[6] == 2)
    #expect(result.finalRegisters[2] == 9)
}

// MARK: - C: nested calls, each with its own frame

@Test func shapeCNestedCallsEachReturnThroughTheirOwnFrame() throws {
    let result = try run("""
    MAIN
    MOV R1, #1
    BL SUBA
    MOV R2, #2
    BX LR
    SUBA
    MOV R3, #3
    BL SUBB
    MOV R4, #4
    BX LR
    SUBB
    MOV R5, #5
    BX LR
    """)
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[1] == 1)
    #expect(result.finalRegisters[2] == 2)
    #expect(result.finalRegisters[3] == 3)
    #expect(result.finalRegisters[4] == 4)
    #expect(result.finalRegisters[5] == 5)
}

// MARK: - D: the resume label is reached only by a *conditional* branch

@Test func shapeDConditionalOnlyBranchToALabelAfterASubroutine() throws {
    // The heuristic at HEAD only ever collected the targets of *unconditional*
    // `B`s, so FINISH — reached solely by `BEQ` — never cleared the latch, and its
    // top-level `BX LR` popped the host prologue's saved x27/x28 pair.
    let result = try run("""
    MAIN
    MOV R1, #1
    BL HELPER
    CMP R1, #1
    BEQ FINISH
    MOV R5, #99
    BX LR
    HELPER
    MOV R6, #2
    BX LR
    FINISH
    MOV R2, #9
    BX LR
    """)
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[1] == 1)
    #expect(result.finalRegisters[6] == 2)
    #expect(result.finalRegisters[2] == 9)
    #expect(result.finalRegisters[5] == 0)   // the not-taken fall-through never ran
}

// MARK: - E: a label inside a callee reached only by fall-through

@Test func shapeEFallThroughLabelInsideACalleeStaysInsideTheFrame() throws {
    let result = try run("""
    MAIN
    MOV R1, #1
    BL HELPER
    MOV R2, #9
    BX LR
    HELPER
    MOV R6, #2
    INNER
    MOV R7, #3
    BX LR
    """)
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[6] == 2)
    #expect(result.finalRegisters[7] == 3)
    #expect(result.finalRegisters[2] == 9)
}

// MARK: - F: a callee loop whose head is an unconditional `B` target

@Test func shapeFCalleeLoopWithAnUnconditionalBranchTargetStillReturns() throws {
    // `B OUT` sits *inside* HELPER, so OUT is not a top-level resume point at all
    // — but the heuristic at HEAD collected every `B` target program-wide and
    // cleared the latch at OUT, making HELPER's own return branch to the exit
    // label with its frame still on the host stack.
    let result = try run("""
    MAIN
    MOV R1, #1
    BL HELPER
    MOV R2, #9
    BX LR
    HELPER
    MOV R6, #3
    LOOP
    SUBS R6, R6, #1
    BNE LOOP
    B OUT
    OUT
    MOV R7, #4
    BX LR
    """)
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[6] == 0)
    #expect(result.finalRegisters[7] == 4)
    #expect(result.finalRegisters[2] == 9)
}

// MARK: - G: a callee loop head reached only by a conditional back-edge

@Test func shapeGCalleeLoopWithOnlyAConditionalBackEdgeStillReturns() throws {
    let result = try run("""
    MAIN
    MOV R1, #1
    BL HELPER
    MOV R2, #9
    BX LR
    HELPER
    MOV R6, #3
    LOOP
    SUBS R6, R6, #1
    BNE LOOP
    BX LR
    """)
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[6] == 0)
    #expect(result.finalRegisters[2] == 9)
}

// MARK: - H: a forward skip inside a callee

@Test func shapeHForwardBranchInsideACalleeStillReturns() throws {
    let result = try run("""
    MAIN
    MOV R1, #1
    BL HELPER
    MOV R2, #9
    BX LR
    HELPER
    MOV R7, #3
    B DONE
    DONE
    BX LR
    """)
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[7] == 3)
    #expect(result.finalRegisters[2] == 9)
}

// MARK: - I: two callees, the second one defined after a top-level `B` target

@Test func shapeITwoCalleesWithATopLevelResumeLabelBetweenThem() throws {
    let result = try run("""
    MAIN
    MOV R4, #7
    BL FIRST
    B MID
    FIRST
    MOV R1, #1
    BX LR
    MID
    BL SECOND
    MOV R3, #3
    BX LR
    SECOND
    MOV R2, #2
    BX LR
    """)
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[4] == 7)
    #expect(result.finalRegisters[1] == 1)
    #expect(result.finalRegisters[2] == 2)
    #expect(result.finalRegisters[3] == 3)
}

// MARK: - L: the classic `while` subroutine idiom

@Test func shapeLClassicWhileLoopSubroutineReturnsToItsCaller() throws {
    // `CMP`/`BEQ ENDLOOP` … `B LOOP` is the textbook ARM7 counted-loop
    // subroutine. Its `B LOOP` back-edge is what the HEAD heuristic mistook for
    // a top-level resume point.
    let result = try run("""
    MAIN
    MOV R1, #5
    BL SUMLOOP
    MOV R3, #7
    BX LR
    SUMLOOP
    MOV R2, #0
    LOOP
    CMP R1, #0
    BEQ ENDLOOP
    ADD R2, R2, R1
    SUBS R1, R1, #1
    B LOOP
    ENDLOOP
    BX LR
    """)
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[2] == 15)   // 5+4+3+2+1
    #expect(result.finalRegisters[1] == 0)
    #expect(result.finalRegisters[3] == 7)    // control really did come back
}

// MARK: - M: PUSH {R4, LR} / POP {R4, PC} around an internal `B`

@Test func shapeMPushPopCalleeWithAnInternalBranchReturnsToItsCaller() throws {
    let result = try run("""
    MAIN
    MOV R4, #7
    BL HELPER
    MOV R2, #9
    BX LR
    HELPER
    PUSH {R4, LR}
    MOV R4, #1
    B TAIL
    TAIL
    POP {R4, PC}
    """)
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[4] == 7)    // restored by the POP
    #expect(result.finalRegisters[2] == 9)
}

// MARK: - N: two callees and no top-level `B` anywhere

@Test func shapeNTwoCalleesWithNoTopLevelBranchAtAll() throws {
    let result = try run("""
    MAIN
    BL H1
    BL H2
    MOV R3, #3
    BX LR
    H1
    MOV R1, #1
    BX LR
    H2
    MOV R2, #2
    BX LR
    """)
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[1] == 1)
    #expect(result.finalRegisters[2] == 2)
    #expect(result.finalRegisters[3] == 3)
}

// MARK: - O: a top-level loop and no subroutine at all

@Test func shapeOTopLevelLoopWithNoSubroutineExitsCleanly() throws {
    let result = try run("""
    MAIN
    MOV R1, #3
    LOOP
    SUBS R1, R1, #1
    BNE LOOP
    MOV R2, #9
    BX LR
    """)
    #expect(result.exitCode == 0)
    #expect(result.finalRegisters[1] == 0)
    #expect(result.finalRegisters[2] == 9)
}

// MARK: - The genuinely ambiguous case

@Test func aReturnReachableInBothStatesIsDiagnosedRatherThanGuessed() throws {
    // MAIN falls straight through into HELPER, so HELPER's `BX LR` is reachable
    // both with a callee frame open (entered via `BL HELPER`) and without one
    // (entered by fall-through from top-level MAIN). Neither lowering is correct
    // on both paths, so the only honest answer is a diagnostic.
    let result = Driver().compile(source: """
        AREA PROGRAM, CODE, READONLY
        ENTRY

    MAIN
    MOV R1, #1
    BL HELPER
    MOV R2, #2
    HELPER
    MOV R3, #3
    BX LR
    END
    """)
    #expect(result.hasErrors)
    #expect(result.assembly == nil)
    let diagnostic = result.diagnostics.first { $0.code == "E044" }
    #expect(diagnostic != nil)
    #expect(diagnostic?.severity == .error)
}
