import Foundation

/// A run of bytes destined for a fixed ARM7 address. Spec §5.3.
struct ImageBlob: Sendable, Equatable {
    let address: UInt32
    let bytes: [UInt8]
}

struct AnalysedProgram: Sendable {
    let program: Program
    let symbols: SymbolTable
    let dataImage: [ImageBlob]
    let entryLineIndex: Int?
    /// Index into `program.lines` → the ARM7 address of that line's instruction.
    let addresses: [Int: UInt32]
}

/// Spec §5.2. Two passes: lay out and bind every label, then evaluate the data.
enum Analyser {
    /// Spec §5.2 `ARM7_ORIGIN`.
    static let origin: UInt32 = 0x0000_8000
    /// Spec §7.8 `ARM7_STACK_TOP`.
    static let stackTop: UInt32 = 0x0010_0000

    static func analyse(_ program: Program, into diagnostics: inout DiagnosticBag) -> AnalysedProgram {
        PerfLog.mark("analyse-start")
        var bag = diagnostics
        let result = PerfLog.measure("analyse") { () -> AnalysedProgram in
            var symbols = SymbolTable()
            var addresses: [Int: UInt32] = [:]
            /// Index into `program.lines` → the ARM7 address of that line's data.
            /// Recorded here in pass 1 so pass 2 never has to re-derive the layout,
            /// and so unlabelled data directives are addressable too.
            var dataAddresses: [Int: UInt32] = [:]
            var entryLineIndex: Int?
            var seenAreaNames: Set<String> = []
            var position = origin
            var inCodeArea = true

            // Population sites for `symbols`. `SymbolTable.lookup` resolves constants
            // before labels and cannot itself signal a name defined in both dictionaries
            // (see the doc comment on SymbolTable) — that obligation falls here, at every
            // site that writes into `.labels` or `.constants`. A name colliding with the
            // *other* dictionary, or a duplicate within the *same* dictionary, is E042;
            // the first definition wins and keeps its address/value, the second is
            // diagnosed and dropped.
            func bindLabel(_ name: String, at address: UInt32, range: SourceRange) {
                if symbols.constants[name] != nil {
                    bag.emit(Diagnostic(
                        severity: .error, code: "E042",
                        message: "'\(name)' is defined as both a label and an EQU constant",
                        range: range,
                        note: "rename one of them; the label's address is otherwise unreachable"
                    ))
                    return
                }
                if symbols.labels[name] != nil {
                    bag.emit(Diagnostic(
                        severity: .error, code: "E042",
                        message: "label '\(name)' is defined more than once",
                        range: range,
                        note: "rename one of the duplicate labels"
                    ))
                    return
                }
                symbols.labels[name] = address
            }

            func bindConstant(_ name: String, value: UInt32, range: SourceRange) {
                if symbols.labels[name] != nil {
                    bag.emit(Diagnostic(
                        severity: .error, code: "E042",
                        message: "'\(name)' is defined as both a label and an EQU constant",
                        range: range,
                        note: "rename one of them; the label's address is otherwise unreachable"
                    ))
                    return
                }
                if symbols.constants[name] != nil {
                    bag.emit(Diagnostic(
                        severity: .error, code: "E042",
                        message: "EQU symbol '\(name)' is defined more than once",
                        range: range,
                        note: "rename one of the duplicate EQU definitions"
                    ))
                    return
                }
                symbols.constants[name] = value
            }

            // Pass 1 — layout. Sizes are known without evaluating any expression:
            // an instruction is 4 bytes and a data directive's size is its element
            // count, so forward references resolve in pass 2 without a fixpoint.
            for (index, line) in program.lines.enumerated() {
                if case .directive(let directive)? = line.statement {
                    switch directive {
                    case .area(let name, let kind, _, let alignment):
                        if !seenAreaNames.insert(name).inserted {
                            bag.emit(Diagnostic(
                                severity: .warning, code: "W004",
                                message: "AREA '\(name)' is declared more than once",
                                range: line.range,
                                note: "canonical ARMASM requires distinct names; treated as separate areas"
                            ))
                        }
                        inCodeArea = (kind == .code)
                        position = align(position, to: UInt32(1) << UInt32(alignment))

                    case .entry:
                        if entryLineIndex != nil {
                            bag.emit(Diagnostic(
                                severity: .error, code: "E034",
                                message: "more than one ENTRY directive",
                                range: line.range, note: nil
                            ))
                        }
                        entryLineIndex = index

                    case .align(let amount):
                        let boundary = amount.flatMap {
                            ExpressionEvaluator.evaluate($0, symbols: symbols, here: position, range: line.range, diagnostics: &bag)
                        } ?? 4
                        position = align(position, to: max(1, boundary))

                    case .defineBytes(let values):
                        if let label = line.label { bindLabel(label, at: position, range: line.range) }
                        dataAddresses[index] = position
                        position &+= UInt32(values.count)
                        continue

                    case .defineHalfwords(let values):
                        position = align(position, to: 2)
                        if let label = line.label { bindLabel(label, at: position, range: line.range) }
                        dataAddresses[index] = position
                        position &+= UInt32(values.count * 2)
                        continue

                    case .defineWords(let values):
                        position = align(position, to: 4)
                        if let label = line.label { bindLabel(label, at: position, range: line.range) }
                        dataAddresses[index] = position
                        position &+= UInt32(values.count * 4)
                        continue

                    case .space(let size):
                        if let label = line.label { bindLabel(label, at: position, range: line.range) }
                        dataAddresses[index] = position
                        if let count = ExpressionEvaluator.evaluate(size, symbols: symbols, here: position, range: line.range, diagnostics: &bag) {
                            position &+= count
                        }
                        continue

                    case .equ:
                        // The "label" here (Line.label, same field every statement carries)
                        // names a compile-time constant, not a position. Bound in pass 1b
                        // instead — falling through to the generic label bind below would
                        // wrongly register it in `symbols.labels` at whatever `position`
                        // happens to be, and every ordinary EQU would then read back as a
                        // self-collision against the very check above.
                        continue

                    case .end, .ltorg, .export:
                        break
                    }
                }

                if let label = line.label {
                    bindLabel(label, at: position, range: line.range)
                }

                if case .instruction? = line.statement {
                    guard inCodeArea else {
                        bag.emit(Diagnostic(
                            severity: .error, code: "E035",
                            message: "instruction appears in a DATA area",
                            range: line.range, note: nil
                        ))
                        continue
                    }
                    addresses[index] = position
                    position &+= 4
                }
            }

            if entryLineIndex == nil {
                bag.emit(Diagnostic(
                    severity: .error, code: "E033",
                    message: "no ENTRY directive",
                    range: program.lines.first?.range ?? SourceRange(line: 0, column: 0, length: 0),
                    note: "mark the entry point with ENTRY"
                ))
            }

            // Pass 1b — EQU constants, now that every label is bound.
            for line in program.lines {
                if case .directive(.equ(let symbol, let value))? = line.statement {
                    if let resolved = ExpressionEvaluator.evaluate(value, symbols: symbols, here: 0, range: line.range, diagnostics: &bag) {
                        bindConstant(symbol, value: resolved, range: line.range)
                    }
                }
            }

            // Pass 2 — evaluate data.
            var dataImage: [ImageBlob] = []
            for (index, line) in program.lines.enumerated() {
                guard case .directive(let directive)? = line.statement,
                      let address = dataAddresses[index]
                else { continue }

                switch directive {
                case .defineBytes(let values):
                    dataImage.append(ImageBlob(
                        address: address,
                        bytes: values.compactMap { expression in
                            ExpressionEvaluator.evaluate(expression, symbols: symbols, here: address, range: line.range, diagnostics: &bag)
                                .map { UInt8(truncatingIfNeeded: $0) }
                        }
                    ))
                case .defineHalfwords(let values):
                    var bytes: [UInt8] = []
                    for expression in values {
                        guard let value = ExpressionEvaluator.evaluate(expression, symbols: symbols, here: address, range: line.range, diagnostics: &bag) else { continue }
                        bytes.append(UInt8(truncatingIfNeeded: value))
                        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
                    }
                    dataImage.append(ImageBlob(address: address, bytes: bytes))
                case .defineWords(let values):
                    var bytes: [UInt8] = []
                    for expression in values {
                        guard let value = ExpressionEvaluator.evaluate(expression, symbols: symbols, here: address, range: line.range, diagnostics: &bag) else { continue }
                        for shift in stride(from: 0, through: 24, by: 8) {
                            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
                        }
                    }
                    dataImage.append(ImageBlob(address: address, bytes: bytes))
                case .space(let size):
                    if let count = ExpressionEvaluator.evaluate(size, symbols: symbols, here: address, range: line.range, diagnostics: &bag) {
                        dataImage.append(ImageBlob(address: address, bytes: Array(repeating: 0, count: Int(count))))
                    }
                default:
                    break
                }
            }

            PerfLog.info("laid out \(addresses.count) instructions, \(dataImage.count) data blobs")
            return AnalysedProgram(
                program: program, symbols: symbols, dataImage: dataImage,
                entryLineIndex: entryLineIndex, addresses: addresses
            )
        }
        diagnostics = bag
        return result
    }

    /// A boundary of 0 or 1 is a no-op (nothing is unaligned relative to it); guarding
    /// it here — rather than trusting every call site — is what keeps `ALIGN 0` from
    /// source safe, since `%` by zero traps.
    private static func align(_ value: UInt32, to boundary: UInt32) -> UInt32 {
        guard boundary > 1 else { return value }
        let remainder = value % boundary
        return remainder == 0 ? value : value &+ (boundary - remainder)
    }
}
