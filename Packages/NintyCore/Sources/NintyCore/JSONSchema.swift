import Foundation

/// Indirect box so `items` can recurse (structs can't self-contain).
final class SchemaItems: Codable, @unchecked Sendable, Equatable {
    let schema: JSONSchema
    init(_ schema: JSONSchema) { self.schema = schema }
    static func == (lhs: SchemaItems, rhs: SchemaItems) -> Bool { lhs.schema == rhs.schema }
    init(from decoder: Decoder) throws { schema = try JSONSchema(from: decoder) }
    func encode(to encoder: Encoder) throws { try schema.encode(to: encoder) }
}

/// JSON Schema subset for tool parameter definitions.
public struct JSONSchema: Codable, Sendable, Equatable {
    public var type: String
    public var description: String?
    public var properties: [String: JSONSchema]?
    public var required: [String]?
    var itemsStorage: SchemaItems?
    public var enumeration: [String]?

    public var items: JSONSchema? {
        get { itemsStorage?.schema }
        set { itemsStorage = newValue.map(SchemaItems.init) }
    }

    enum CodingKeys: String, CodingKey {
        case type, description, properties, required
        case itemsStorage = "items"
        case enumeration = "enum"
    }

    public init(type: String, description: String? = nil) {
        self.type = type
        self.description = description
    }

    public static func string(_ description: String? = nil) -> JSONSchema {
        JSONSchema(type: "string", description: description)
    }

    public static func integer(_ description: String? = nil) -> JSONSchema {
        JSONSchema(type: "integer", description: description)
    }

    public static func boolean(_ description: String? = nil) -> JSONSchema {
        JSONSchema(type: "boolean", description: description)
    }

    public static func array(of items: JSONSchema, description: String? = nil) -> JSONSchema {
        var schema = JSONSchema(type: "array", description: description)
        schema.items = items
        return schema
    }

    public static func enumeration(_ values: [String], description: String? = nil) -> JSONSchema {
        var schema = JSONSchema(type: "string", description: description)
        schema.enumeration = values
        return schema
    }

    public static func object(
        properties: [String: JSONSchema],
        required: [String] = [],
        description: String? = nil
    ) -> JSONSchema {
        var schema = JSONSchema(type: "object", description: description)
        schema.properties = properties
        if !required.isEmpty { schema.required = required }
        return schema
    }
}
