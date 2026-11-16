import CoreFoundation
import Foundation

enum YAMLValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([YAMLValue])
    case object([String: YAMLValue])
}

enum YAMLValueError: Error, Equatable, Sendable {
    case unsupportedValue
    case nonStringKey
    case nonFiniteNumber
}

extension YAMLValue {
    init(any value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .integer(Int64(value))
        case let value as Int8:
            self = .integer(Int64(value))
        case let value as Int16:
            self = .integer(Int64(value))
        case let value as Int32:
            self = .integer(Int64(value))
        case let value as Int64:
            self = .integer(value)
        case let value as UInt where value <= Int64.max:
            self = .integer(Int64(value))
        case let value as Double:
            guard value.isFinite else { throw YAMLValueError.nonFiniteNumber }
            self = .double(value)
        case let value as Float:
            guard value.isFinite else { throw YAMLValueError.nonFiniteNumber }
            self = .double(Double(value))
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                let doubleValue = value.doubleValue
                guard doubleValue.isFinite else { throw YAMLValueError.nonFiniteNumber }
                if doubleValue.rounded() == doubleValue,
                   let integer = Int64(exactly: doubleValue) {
                    self = .integer(integer)
                } else {
                    self = .double(doubleValue)
                }
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map(YAMLValue.init(any:)))
        case let value as [String: Any]:
            self = .object(try value.mapValues(YAMLValue.init(any:)))
        case let value as [AnyHashable: Any]:
            var result: [String: YAMLValue] = [:]
            result.reserveCapacity(value.count)
            for (key, nestedValue) in value {
                guard let key = key as? String else { throw YAMLValueError.nonStringKey }
                result[key] = try YAMLValue(any: nestedValue)
            }
            self = .object(result)
        default:
            throw YAMLValueError.unsupportedValue
        }
    }

    var foundationValue: Any {
        switch self {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .integer(value):
            value
        case let .double(value):
            value
        case let .string(value):
            value
        case let .array(values):
            values.map(\.foundationValue)
        case let .object(values):
            values.mapValues(\.foundationValue)
        }
    }
}
