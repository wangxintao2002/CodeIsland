import Foundation

public struct SessionKey: Hashable, Codable, Comparable, CustomStringConvertible {
    public static let localOriginId = "local"
    private static let separator = "::"

    public let originId: String
    public let sessionId: String

    public init(originId: String = SessionKey.localOriginId, sessionId: String) {
        let trimmedOrigin = originId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSession = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.originId = trimmedOrigin.isEmpty ? SessionKey.localOriginId : trimmedOrigin
        self.sessionId = trimmedSession.isEmpty ? "default" : trimmedSession
    }

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: Self.separator) else {
            self.init(sessionId: trimmed.isEmpty ? "default" : trimmed)
            return
        }
        let origin = String(trimmed[..<range.lowerBound])
        let session = String(trimmed[range.upperBound...])
        self.init(originId: origin, sessionId: session)
    }

    public var rawValue: String {
        if originId == Self.localOriginId {
            return sessionId
        }
        return "\(originId)\(Self.separator)\(sessionId)"
    }

    public var description: String { rawValue }

    public static func < (lhs: SessionKey, rhs: SessionKey) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
