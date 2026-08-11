/// Spec §4. The lexer preserves what the source says; it does not normalise.
struct Token: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case symbol(String)         // case preserved: user symbols are case-sensitive
        case integer(UInt32)
        case string(String)
        case register(Int)          // 0...15, with SP=13, LR=14, PC=15
        case operatorWord(String)   // :MOD:, :SHL:, :SHR:, :AND:, :OR:, :EOR: — uppercased
        case hash
        case comma
        case leftBracket, rightBracket
        case leftBrace, rightBrace
        case bang
        case equals
        case plus, minus, star, slash
        case leftParen, rightParen
        case caret
        case dot                    // '.' — current position, Spec §5.1
        case endOfLine
        case endOfFile
    }

    let kind: Kind
    let range: SourceRange
}
