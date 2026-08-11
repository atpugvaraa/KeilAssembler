import Testing
@testable import KeilAssembler

@Test func conditionParsingHandlesBothAliasSpellings() {
    #expect(Condition(suffix: "EQ") == .eq)
    #expect(Condition(suffix: "HS") == .cs)
    #expect(Condition(suffix: "LO") == .cc)
    #expect(Condition(suffix: "ZZ") == nil)
}

@Test func conditionsKnowTheirInverseGuardBranch() {
    // Spec §6.1: a conditional instruction is skipped by branching on the inverse.
    // Test all condition pairs to catch swaps or inversions.
    #expect(Condition.eq.inverseBranchSuffix == "ne")
    #expect(Condition.ne.inverseBranchSuffix == "eq")
    #expect(Condition.cs.inverseBranchSuffix == "lo")
    #expect(Condition.cc.inverseBranchSuffix == "hs")
    #expect(Condition.mi.inverseBranchSuffix == "pl")
    #expect(Condition.pl.inverseBranchSuffix == "mi")
    #expect(Condition.vs.inverseBranchSuffix == "vc")
    #expect(Condition.vc.inverseBranchSuffix == "vs")
    #expect(Condition.hi.inverseBranchSuffix == "ls")
    #expect(Condition.ls.inverseBranchSuffix == "hi")
    #expect(Condition.ge.inverseBranchSuffix == "lt")
    #expect(Condition.lt.inverseBranchSuffix == "ge")
    #expect(Condition.gt.inverseBranchSuffix == "le")
    #expect(Condition.le.inverseBranchSuffix == "gt")
    #expect(Condition.al.inverseBranchSuffix == nil)
}

@Test func mnemonicParsingIsCaseInsensitive() {
    #expect(Mnemonic(text: "ldrb") == .ldrb)
    #expect(Mnemonic(text: "MOV") == .mov)
    #expect(Mnemonic(text: "NOPE") == nil)
}

@Test func mnemonicDecomposePrefersTheLongestMnemonic() {
    // A wrong implementation that tries mnemonics in enum-declaration order
    // (or any order that isn't longest-first) would read "LDRB" as "LDR"
    // plus a bogus "B" suffix, since LDR is also a prefix of LDRB.
    let result = Mnemonic.decompose("LDRB")
    #expect(result?.mnemonic == .ldrb)
    #expect(result?.condition == .al)
    #expect(result?.setsFlags == false)
}

@Test func mnemonicDecomposeFallsBackWhenTheLongestPrefixLeavesAnInvalidSuffix() {
    // "BLE" is B (branch) with condition LE, not BL (branch-with-link) with a
    // nonsensical single-character "E" suffix. Exercises the `continue` that
    // rejects a too-greedy candidate and retries with the next-longest one.
    let result = Mnemonic.decompose("BLE")
    #expect(result?.mnemonic == .b)
    #expect(result?.condition == .le)
    #expect(result?.setsFlags == false)
}

@Test func mnemonicDecomposeAcceptsBothSuffixOrders() {
    let condThenS = Mnemonic.decompose("ADDEQS")
    #expect(condThenS?.mnemonic == .add)
    #expect(condThenS?.condition == .eq)
    #expect(condThenS?.setsFlags == true)

    let sThenCond = Mnemonic.decompose("ADDSEQ")
    #expect(sThenCond?.mnemonic == .add)
    #expect(sThenCond?.condition == .eq)
    #expect(sThenCond?.setsFlags == true)
}

@Test func mnemonicDecomposeRejectsUnknownText() {
    #expect(Mnemonic.decompose("NOPE") == nil)
    #expect(Mnemonic(parsingSuffixesOf: "NOPE") == nil)
}
