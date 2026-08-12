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

// MARK: - Review fix: the S-strip must only apply to mnemonics with a real flag-setting form

@Test func mnemonicDecomposeTableForTheBLFamily() {
    // Candidates sort longest-first, so "bl" is tried before "b". `BL` has no
    // architectural S-suffixed form, so a residual "S" left over after
    // stripping "BL" must never be consumed as a flag suffix — that swallows
    // the real conditional branch `BLS` (= `B.LS`, ARMv4-legal) into an
    // unconditional `BL` that also (spuriously) "sets flags". `BLE`/`BLCS`/
    // `BLLS` must keep parsing exactly as before: real `BL` with a genuine
    // two-letter condition, since none of those residues end in a bare "S".
    let bls = Mnemonic.decompose("BLS")
    #expect(bls?.mnemonic == .b)
    #expect(bls?.condition == .ls)
    #expect(bls?.setsFlags == false)

    let ble = Mnemonic.decompose("BLE")
    #expect(ble?.mnemonic == .b)
    #expect(ble?.condition == .le)
    #expect(ble?.setsFlags == false)

    let blcs = Mnemonic.decompose("BLCS")
    #expect(blcs?.mnemonic == .bl)
    #expect(blcs?.condition == .cs)
    #expect(blcs?.setsFlags == false)

    let blls = Mnemonic.decompose("BLLS")
    #expect(blls?.mnemonic == .bl)
    #expect(blls?.condition == .ls)
    #expect(blls?.setsFlags == false)
}

@Test func mnemonicDecomposeRejectsABogusSSuffixOnMnemonicsWithNoFlagSettingForm() {
    // Spec §6.3: only data-processing and multiply mnemonics have an `S` form.
    // Branches, NOP, ADR, the stack ops, and the load/store family do not —
    // a trailing "S" after any of these is not a legal instruction at all and
    // must fail to decompose, not silently parse with `setsFlags: true`.
    #expect(Mnemonic.decompose("BS") == nil)
    #expect(Mnemonic.decompose("NOPS") == nil)
    #expect(Mnemonic.decompose("LDRS") == nil)
    #expect(Mnemonic.decompose("STRS") == nil)
    #expect(Mnemonic.decompose("PUSHS") == nil)
    #expect(Mnemonic.decompose("ADRS") == nil)
    #expect(Mnemonic.decompose("BXS") == nil)
}
