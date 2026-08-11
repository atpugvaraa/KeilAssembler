/// Spec §5.2: labels resolve to ARM7 addresses; EQU symbols are compile-time constants.
///
/// `lookup` resolves `constants` before `labels`. A name defined in *both* dictionaries is a
/// collision — an EQU symbol reusing a label name, or vice versa — that `lookup` cannot signal:
/// it can only silently pick constants and shadow the label. `lookup` does not diagnose this,
/// so whatever populates this table (Task 10's layout/symbol-collection pass) must check for a
/// name existing in both dictionaries and emit a diagnostic before it ever reaches `lookup`.
struct SymbolTable: Sendable {
    var constants: [String: UInt32] = [:]
    var labels: [String: UInt32] = [:]

    init() {}

    func lookup(_ name: String) -> UInt32? {
        constants[name] ?? labels[name]
    }
}

/// Spec §5.1. Integer only, 32-bit wrapping.
enum ExpressionEvaluator {
    static func evaluate(
        _ expression: Expression,
        symbols: SymbolTable,
        here: UInt32,
        range: SourceRange,
        diagnostics: inout DiagnosticBag
    ) -> UInt32? {
        switch expression {
        case .integer(let value):
            return value

        case .here:
            return here

        case .symbol(let name):
            guard let value = symbols.lookup(name) else {
                diagnostics.emit(Diagnostic(
                    severity: .error, code: "E031",
                    message: "'\(name)' is not defined",
                    range: range,
                    note: "define it with a label or an EQU directive"
                ))
                return nil
            }
            return value

        case .unary(let op, let operand):
            guard let value = evaluate(operand, symbols: symbols, here: here, range: range, diagnostics: &diagnostics) else {
                return nil
            }
            switch op {
            case .plus:  return value
            case .minus: return 0 &- value
            case .not:   return ~value
            }

        case .binary(let op, let leftExpression, let rightExpression):
            guard let left = evaluate(leftExpression, symbols: symbols, here: here, range: range, diagnostics: &diagnostics),
                  let right = evaluate(rightExpression, symbols: symbols, here: here, range: range, diagnostics: &diagnostics) else {
                return nil
            }
            switch op {
            case .multiply:    return left &* right
            case .add:         return left &+ right
            case .subtract:    return left &- right
            case .and:         return left & right
            case .or:          return left | right
            case .exclusiveOr: return left ^ right
            case .shiftLeft:   return right >= 32 ? 0 : left << right
            case .shiftRight:  return right >= 32 ? 0 : left >> right
            case .divide, .modulo:
                guard right != 0 else {
                    diagnostics.emit(Diagnostic(
                        severity: .error, code: "E032",
                        message: "division by zero",
                        range: range, note: nil
                    ))
                    return nil
                }
                return op == .divide ? left / right : left % right
            }
        }
    }
}
