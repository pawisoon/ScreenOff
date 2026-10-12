import CoreGraphics
import Foundation

public struct Display: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let isBuiltin: Bool
    public let isMain: Bool
    public let isEnabled: Bool

    public init(id: CGDirectDisplayID, name: String, isBuiltin: Bool, isMain: Bool, isEnabled: Bool) {
        self.id = id
        self.name = name
        self.isBuiltin = isBuiltin
        self.isMain = isMain
        self.isEnabled = isEnabled
    }
}

public enum ScreenOffError: LocalizedError, Equatable {
    case noMatch(String)
    case ambiguous(String, [String])
    case lastActiveDisplay
    case apiUnavailable
    case configurationFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .noMatch(let q):
            "No display matches '\(q)'."
        case .ambiguous(let q, let names):
            "'\(q)' matches several displays (\(names.joined(separator: ", "))). Use the ID instead."
        case .lastActiveDisplay:
            "Refusing to turn off the last active display."
        case .apiUnavailable:
            "Display control API is unavailable on this macOS version."
        case .configurationFailed(let name, let code):
            "Could not change \(name) (CGError \(code))."
        }
    }
}

extension [Display] {
    /// Resolve a user query: exact ID first, then exact name, then case-insensitive substring.
    public func match(_ query: String) throws -> Display {
        if let id = CGDirectDisplayID(query), let d = first(where: { $0.id == id }) { return d }
        if let d = first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) { return d }
        let hits = filter { $0.name.localizedCaseInsensitiveContains(query) }
        switch hits.count {
        case 1: return hits[0]
        case 0: throw ScreenOffError.noMatch(query)
        default: throw ScreenOffError.ambiguous(query, hits.map(\.name))
        }
    }
}
