/// Accumulates Darwin `.s` text. Labels sit at column 0, everything else is indented,
/// which keeps the emitted file readable — PRD G6 makes that a product goal.
struct AssemblyBuilder {
    private var lines: [String] = []

    init() {}

    mutating func label(_ name: String) { lines.append("\(name):") }
    mutating func instruction(_ text: String) { lines.append("        \(text)") }
    mutating func directive(_ text: String) { lines.append("        \(text)") }
    mutating func comment(_ text: String) { lines.append("        ; \(text)") }
    mutating func blankLine() { lines.append("") }

    var text: String { lines.map { $0 + "\n" }.joined() }
}
