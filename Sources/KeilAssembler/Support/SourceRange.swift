/// A span of source text. Line and column are 0-based, matching Spec §7.7's
/// `srcLine` trace field so a snapshot indexes the source array directly.
struct SourceRange: Sendable, Equatable {
    let line: Int
    let column: Int
    let length: Int

    init(line: Int, column: Int, length: Int) {
        self.line = line
        self.column = column
        self.length = length
    }
}

extension SourceRange: CustomStringConvertible {
    var description: String { "\(line + 1):\(column + 1)" }
}
