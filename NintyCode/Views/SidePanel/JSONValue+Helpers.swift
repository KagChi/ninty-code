import NintyCore

/// Shared JSONValue accessors for MCP tool payloads (side-panel tabs).
extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        default: return nil
        }
    }

    var stringArray: [String] {
        guard case .array(let items) = self else { return [] }
        return items.compactMap(\.stringValue)
    }
}
