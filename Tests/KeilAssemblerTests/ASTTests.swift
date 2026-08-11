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
