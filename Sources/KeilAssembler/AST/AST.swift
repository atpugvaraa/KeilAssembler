// MARK: - Expressions (Spec §5.1)

enum UnaryOperator: Sendable, Equatable { case plus, minus, not }

enum BinaryOperator: Sendable, Equatable {
    case multiply, divide, modulo
    case add, subtract
    case shiftLeft, shiftRight
    case and, or, exclusiveOr
}

indirect enum Expression: Sendable, Equatable {
    case integer(UInt32)
    case symbol(String)
    case here                                       // '.'
    case unary(UnaryOperator, Expression)
    case binary(BinaryOperator, Expression, Expression)
}

// MARK: - Operands (Spec §6.2, §6.3)

struct ShiftSpec: Sendable, Equatable {
    let kind: ShiftKind
    let amount: Expression?     // nil for RRX
    let amountRegister: Int?    // set for `Rm, LSL Rs`

    init(kind: ShiftKind, amount: Expression? = nil, amountRegister: Int? = nil) {
        self.kind = kind
        self.amount = amount
        self.amountRegister = amountRegister
    }
}

enum Operand2: Sendable, Equatable {
    case immediate(Expression)
    case register(Int)
    case shifted(register: Int, shift: ShiftSpec)
}

enum AddressMode: Sendable, Equatable {
    /// `[Rn]`, `[Rn, #±off]`, `[Rn, #±off]!`
    case immediateOffset(base: Int, offset: Expression?, negated: Bool, writeBack: Bool)
    /// `[Rn, ±Rm]`, `[Rn, ±Rm, <shift> #k]`
    case registerOffset(base: Int, offset: Int, negated: Bool, shift: ShiftSpec?, writeBack: Bool)
    /// `[Rn], #±off`
    case postIndexed(base: Int, offset: Expression, negated: Bool)
    /// `LDR Rd, label` — Spec §7.6 literal load
    case label(String)
}

enum Operand: Sendable, Equatable {
    case register(Int)
    case operand2(Operand2)
    case address(AddressMode)
    case registerList([Int])
    case labelReference(String)
    case immediateValue(Expression)     // `LDR Rd, =expr`
}

// MARK: - Statements (Spec §5, §6)

enum AreaKind: Sendable, Equatable { case code, data }

enum Directive: Sendable, Equatable {
    case area(name: String, kind: AreaKind, readOnly: Bool, alignment: Int)
    case entry
    case end
    case equ(symbol: String, value: Expression)
    case align(Expression?)
    case defineBytes([Expression])
    case defineHalfwords([Expression])
    case defineWords([Expression])
    case space(Expression)
    case ltorg
    case export(String)
}

struct Instruction: Sendable, Equatable {
    let mnemonic: Mnemonic
    let condition: Condition
    let setsFlags: Bool
    let operands: [Operand]
    let range: SourceRange
}

enum Statement: Sendable, Equatable {
    case instruction(Instruction)
    case directive(Directive)
}

struct Line: Sendable, Equatable {
    let label: String?
    let statement: Statement?
    let range: SourceRange
}

struct Program: Sendable, Equatable {
    let lines: [Line]
}
