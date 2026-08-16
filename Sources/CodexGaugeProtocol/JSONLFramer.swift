import Foundation

public enum JSONLFramingError: Error, Equatable, Sendable {
    case lineTooLong
}

public struct JSONLFramer: Sendable {
    public static let maximumLineBytes = 1_048_576

    private var buffer = Data()

    public init() {}

    public mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        do {
            let lines = try extractCompleteLines()
            try validatePendingLine()
            return lines
        } catch {
            buffer.removeAll(keepingCapacity: false)
            throw error
        }
    }

    public mutating func finish() throws -> [Data] {
        guard buffer.isEmpty == false else {
            return []
        }
        var finalLine = buffer
        buffer.removeAll(keepingCapacity: false)
        finalLine.removeTrailingCarriageReturn()
        guard finalLine.isEmpty == false else {
            return []
        }
        try validate(finalLine)
        return [finalLine]
    }

    private mutating func extractCompleteLines() throws -> [Data] {
        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            line.removeTrailingCarriageReturn()
            try validate(line)
            guard line.isEmpty == false else {
                continue
            }
            lines.append(line)
        }
        return lines
    }

    private func validatePendingLine() throws {
        guard buffer.count > Self.maximumLineBytes else {
            return
        }
        let allowedTrailingCarriageReturn =
            buffer.count == Self.maximumLineBytes + 1 && buffer.last == 0x0D
        guard allowedTrailingCarriageReturn else {
            throw JSONLFramingError.lineTooLong
        }
    }

    private func validate(_ line: Data) throws {
        guard line.count <= Self.maximumLineBytes else {
            throw JSONLFramingError.lineTooLong
        }
    }
}

private extension Data {
    mutating func removeTrailingCarriageReturn() {
        guard last == 0x0D else {
            return
        }
        removeLast()
    }
}
