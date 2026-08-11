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
    #expect(Condition.eq.inverseBranchSuffix == "ne")
    #expect(Condition.cs.inverseBranchSuffix == "lo")
    #expect(Condition.le.inverseBranchSuffix == "gt")
    #expect(Condition.al.inverseBranchSuffix == nil)
}

@Test func mnemonicParsingIsCaseInsensitive() {
    #expect(Mnemonic(text: "ldrb") == .ldrb)
    #expect(Mnemonic(text: "MOV") == .mov)
    #expect(Mnemonic(text: "NOPE") == nil)
}
