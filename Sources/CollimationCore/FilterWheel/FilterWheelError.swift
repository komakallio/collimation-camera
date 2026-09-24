import Foundation

public struct FilterWheelDescriptor: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var handle: Int32
    public var positionCount: Int
    public var serialNumber: String

    public init(
        id: String,
        name: String,
        handle: Int32,
        positionCount: Int,
        serialNumber: String
    ) {
        self.id = id
        self.name = name
        self.handle = handle
        self.positionCount = positionCount
        self.serialNumber = serialNumber
    }
}

public struct FilterSlot: Equatable, Identifiable, Sendable {
    public var position: Int
    public var alias: String

    public var id: Int { position }

    public init(position: Int, alias: String = "") {
        self.position = position
        self.alias = alias
    }

    public var displayName: String {
        Self.displayName(position: position, alias: alias)
    }

    /// SDK positions are 0-based; the UI shows 1-based slot numbers plus any on-wheel alias.
    public static func displayName(position: Int, alias: String) -> String {
        let number = "\(position + 1)"
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? number : "\(number) · \(trimmed)"
    }
}

public struct FilterWheelSnapshot: Equatable, Sendable {
    public var name: String
    public var position: Int?
    public var moving: Bool
    public var slots: [FilterSlot]

    public init(name: String, position: Int?, moving: Bool, slots: [FilterSlot]) {
        self.name = name
        self.position = position
        self.moving = moving
        self.slots = slots
    }
}

public enum FilterWheelError: Error, LocalizedError, Sendable {
    case sdkNotFound
    case sdkSymbolMissing(String)
    case notConnected
    case noWheelSelected
    case timeout
    case disconnected
    case moving
    case invalidPosition
    case firmware
    case pw(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .sdkNotFound:
            return "Player One Filter Wheel SDK was not found. Place \(VendorLibrary.playerOneFilterWheel) in Vendor/\(VendorLibrary.playerOneFolder) or next to the executable."
        case .sdkSymbolMissing(let name):
            return "Player One Filter Wheel SDK is missing symbol \(name)."
        case .notConnected:
            return "The filter wheel is not connected."
        case .noWheelSelected:
            return "Select a Phoenix filter wheel."
        case .timeout:
            return "Timed out waiting for the filter wheel to finish moving."
        case .disconnected:
            return "The filter wheel was disconnected."
        case .moving:
            return "The filter wheel is still moving."
        case .invalidPosition:
            return "That filter position is not valid for this wheel."
        case .firmware:
            return "The filter wheel firmware reported an error. Try reconnecting."
        case .pw(_, let message):
            return message
        }
    }
}
