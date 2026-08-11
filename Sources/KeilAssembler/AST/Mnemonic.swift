/// Spec §6.1. `HS`/`LO` are alias spellings of `CS`/`CC` and collapse onto them.
enum Condition: String, Sendable, Equatable, CaseIterable {
    case eq, ne, cs, cc, mi, pl, vs, vc, hi, ls, ge, lt, gt, le, al

    init?(suffix: String) {
        switch suffix.lowercased() {
        case "hs": self = .cs
        case "lo": self = .cc
        default:
            guard let parsed = Condition(rawValue: suffix.lowercased()) else { return nil }
            self = parsed
        }
    }

    /// The A64 branch suffix that skips the guarded block, or nil for `AL`
    /// (which emits no guard at all).
    var inverseBranchSuffix: String? {
        switch self {
        case .eq: "ne"
        case .ne: "eq"
        case .cs: "lo"
        case .cc: "hs"
        case .mi: "pl"
        case .pl: "mi"
        case .vs: "vc"
        case .vc: "vs"
        case .hi: "ls"
        case .ls: "hi"
        case .ge: "lt"
        case .lt: "ge"
        case .gt: "le"
        case .le: "gt"
        case .al: nil
        }
    }
}

/// Spec §6.2.
enum ShiftKind: String, Sendable, Equatable, CaseIterable {
    case lsl, lsr, asr, ror, rrx

    init?(text: String) {
        guard let parsed = ShiftKind(rawValue: text.lowercased()) else { return nil }
        self = parsed
    }

    /// A64 shift-by-register mnemonic, Spec §7.4.
    var variableMnemonic: String { rawValue + "v" }
}

/// Spec §6.3.
enum Mnemonic: String, Sendable, Equatable, CaseIterable {
    case mov, mvn
    case add, adc, sub, sbc, rsb, rsc
    case and, orr, eor, bic
    case cmp, cmn, tst, teq
    case mul, mla
    case ldr, str, ldrb, strb, ldrh, strh
    case push, pop, stmfd, ldmfd
    case b, bl, bx
    case adr, nop

    init?(text: String) {
        guard let parsed = Mnemonic(rawValue: text.lowercased()) else { return nil }
        self = parsed
    }

    /// Spec §6.3: these always set flags and have no destination register.
    var isComparison: Bool { self == .cmp || self == .cmn || self == .tst || self == .teq }
}
