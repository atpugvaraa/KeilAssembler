/// A span of source text. Line and column are 0-based, matching Spec §7.7's
/// `srcLine` trace field so a snapshot indexes the source array directly.
public struct SourceRange: Sendable, Equatable {
    public let line: Int
    public let column: Int
    public let length: Int

    public init(line: Int, column: Int, length: Int) {
        self.line = line
        self.column = column
        self.length = length
    }
}

extension SourceRange: CustomStringConvertible {
    public var description: String { "\(line + 1):\(column + 1)" }
}
