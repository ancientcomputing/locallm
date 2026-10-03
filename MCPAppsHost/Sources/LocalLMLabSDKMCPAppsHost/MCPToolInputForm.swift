import Foundation
import LocalLMLabSDKCore

/// One input a tool takes, derived from its JSON Schema, in the terms a form needs.
public struct MCPToolInputField: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case string
        case integer
        case number
        case boolean
        /// A string restricted to these values.
        case choice([String])
        /// A list of simple values, entered comma-separated. `integer`/`number`/`string` elements.
        case list(element: ListElement)
        /// Anything the form can't model (objects, unions, nested arrays): raw JSON text.
        case json
    }

    public enum ListElement: Sendable, Equatable { case string, integer, number }

    public var id: String { name }
    public let name: String
    public let summary: String
    public let isRequired: Bool
    public let kind: Kind
    /// The schema default, rendered as text for prefilling the form.
    public let defaultText: String?
}

public enum MCPToolInputError: Error, Equatable, CustomStringConvertible {
    case missingRequired(String)
    case invalid(field: String, reason: String)

    public var description: String {
        switch self {
        case .missingRequired(let name): return "\(name) is required"
        case .invalid(let field, let reason): return "\(field): \(reason)"
        }
    }
}

/// Turns a tool's `inputSchema` into form fields, and typed user input back into tool arguments.
/// Pure logic: no UI. Tolerant of real-world schemas — anything it can't model becomes a JSON
/// field, and the SERVER still validates (the form is a convenience, never a security check).
public struct MCPToolInputForm: Sendable, Equatable {
    public let fields: [MCPToolInputField]

    /// True when there is nothing to ask the user: the tool takes no inputs.
    public var isEmpty: Bool { fields.isEmpty }
    /// True when at least one input is mandatory (the tool can't be launched blank).
    public var hasRequiredFields: Bool { fields.contains { $0.isRequired } }

    public init(schema: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: schema)) as? [String: Any],
              let properties = root["properties"] as? [String: Any] else {
            fields = []
            return
        }
        let required = Set((root["required"] as? [Any])?.compactMap { $0 as? String } ?? [])
        fields = properties.compactMap { name, raw -> MCPToolInputField? in
            guard let prop = raw as? [String: Any] else { return nil }
            return Self.field(name: name, prop: prop, required: required.contains(name))
        }
        .sorted { ($0.isRequired ? 0 : 1, $0.name) < ($1.isRequired ? 0 : 1, $1.name) }
    }

    private static func field(name: String, prop: [String: Any], required: Bool) -> MCPToolInputField {
        var summary = (prop["description"] as? String) ?? (prop["title"] as? String) ?? ""
        if summary.count > 400 { summary = String(summary.prefix(400)) + "…" }
        let kind = Self.kind(of: prop)
        var defaultText: String?
        if let d = prop["default"], !(d is NSNull) {
            switch d {
            case let s as String: defaultText = s
            case let n as NSNumber: defaultText = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : "\(n)"
            default:
                if let data = try? JSONSerialization.data(withJSONObject: d, options: [.fragmentsAllowed]) { defaultText = String(decoding: data, as: UTF8.self) }
            }
        }
        return MCPToolInputField(name: name, summary: summary, isRequired: required, kind: kind, defaultText: defaultText)
    }

    private static func kind(of prop: [String: Any]) -> MCPToolInputField.Kind {
        if let options = prop["enum"] as? [Any] {
            let strings = options.compactMap { $0 as? String }
            return strings.count == options.count && !strings.isEmpty ? .choice(strings) : .json
        }
        // `type` may be a string or a list like ["string", "null"]: take the single non-null type.
        var type = prop["type"] as? String
        if let types = prop["type"] as? [Any] {
            let real = types.compactMap { $0 as? String }.filter { $0 != "null" }
            type = real.count == 1 ? real[0] : nil
        }
        switch type {
        case "string": return .string
        case "integer": return .integer
        case "number": return .number
        case "boolean": return .boolean
        case "array":
            switch ((prop["items"] as? [String: Any])?["type"] as? String) {
            case "string": return .list(element: .string)
            case "integer": return .list(element: .integer)
            case "number": return .list(element: .number)
            default: return .json
            }
        default: return .json
        }
    }

    /// Builds the tool arguments from what the user typed (`values` maps field name to text;
    /// booleans are `"true"`/`"false"`). Blank optional fields are omitted; a blank required field,
    /// or text that doesn't fit the field's type, is an error.
    public func arguments(from values: [String: String]) -> Result<[String: MCPValue], MCPToolInputError> {
        var out: [String: MCPValue] = [:]
        for field in fields {
            let raw = (values[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                if field.isRequired && field.kind != .boolean { return .failure(.missingRequired(field.name)) }
                if field.kind == .boolean, values[field.name] != nil { out[field.name] = .bool(false) }
                continue
            }
            switch Self.convert(raw, kind: field.kind) {
            case .success(let value): out[field.name] = value
            case .failure(let reason): return .failure(.invalid(field: field.name, reason: reason))
            }
        }
        return .success(out)
    }

    private enum Conversion { case success(MCPValue), failure(String) }

    private static func convert(_ raw: String, kind: MCPToolInputField.Kind) -> Conversion {
        switch kind {
        case .string: return .success(.string(raw))
        case .integer:
            guard let n = Int(raw) else { return .failure("must be a whole number") }
            return .success(.number(Double(n)))
        case .number:
            guard let n = Double(raw), n.isFinite else { return .failure("must be a number") }
            return .success(.number(n))
        case .boolean:
            switch raw.lowercased() {
            case "true", "yes", "1": return .success(.bool(true))
            case "false", "no", "0": return .success(.bool(false))
            default: return .failure("must be true or false")
            }
        case .choice(let options):
            return options.contains(raw) ? .success(.string(raw)) : .failure("must be one of \(options.joined(separator: ", "))")
        case .list(let element):
            let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var items: [MCPValue] = []
            for part in parts {
                switch element {
                case .string: items.append(.string(part))
                case .integer:
                    guard let n = Int(part) else { return .failure("\"\(part)\" is not a whole number") }
                    items.append(.number(Double(n)))
                case .number:
                    guard let n = Double(part), n.isFinite else { return .failure("\"\(part)\" is not a number") }
                    items.append(.number(n))
                }
            }
            return .success(.array(items))
        case .json:
            guard let data = raw.data(using: .utf8), let value = try? JSONDecoder().decode(MCPValue.self, from: data) else {
                return .failure("is not valid JSON")
            }
            return .success(value)
        }
    }
}
