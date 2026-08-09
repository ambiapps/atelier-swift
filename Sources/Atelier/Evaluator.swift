import CryptoKit
import Foundation

/// Pure implementation of the evaluation algorithm in docs/data-model.md.
/// Every semantic here is covered by spec/test-vectors.json; changes to
/// this file require updating the vectors (and all other evaluators) in
/// the same PR.
enum Evaluator {

    /// Context attribute types the v1 evaluator recognizes.
    /// Anything else is an unknown construct (rule 4).
    private static let attributeTypes: [String: AttributeType] = [
        "stable_id": .string,
        "user_id": .string,
        "email_hash": .string,
        "is_anonymous": .bool,
        "platform": .string,
        "build": .int,
        "app_version": .string,
        "os_version": .string,
        "locale": .string,
    ]

    private enum AttributeType { case string, int, bool }

    /// Raised when the flag contains anything the evaluator does not
    /// recognize — unknown attribute, unknown op, missing/mistyped field,
    /// unparsable value. The caller resolves the whole flag to its
    /// compiled-in default (rule 4).
    struct UnknownConstruct: Error { let reason: String }

    /// Evaluate one flag (as loose JSON, or nil when absent from the
    /// config) against a normalized context. Boolean read: reports the
    /// ON/OFF resolution for a flag of any value type.
    static func resolve(
        flag: JSONValue?, context: [String: JSONValue], stableID: String, codeDefault: Bool
    ) -> Bool {
        guard let flag else { return codeDefault }
        do {
            return try resolveStrict(
                flag: flag, context: context, stableID: stableID)
        } catch {
            // Rule 4: anything unrecognized resolves the whole flag to the
            // compiled-in default — never "skip the rule", never OFF.
            return codeDefault
        }
    }

    /// What a flag's ON and OFF are worth (ADR 0013).
    enum ValueType: String {
        case bool, int, double, string
    }

    /// Value read (ADR 0013): the ON/OFF resolution projected onto the
    /// flag's declared value — ON serves `on_value`, OFF serves
    /// `off_value` — along with the resolution it came from, for the
    /// exposure hook.
    ///
    /// Returns nil where the caller must use its compiled-in default:
    /// the flag is absent, `readAs` is not the type the flag declares
    /// (reads are exact — no widening, no coercion), or anything rule 4
    /// covers. A flag with no value fields is a bool flag serving
    /// true/false, so config written before typed values existed reads
    /// exactly as it always did.
    static func resolveValue(
        flag: JSONValue?, context: [String: JSONValue], stableID: String, readAs: ValueType
    ) -> (value: JSONValue, isOn: Bool)? {
        guard let flag, let object = flag.objectValue else { return nil }
        do {
            let values = try parseValues(object)
            guard values.type == readAs else { return nil }
            let isOn = try resolveStrict(flag: flag, context: context, stableID: stableID)
            return (isOn ? values.onValue : values.offValue, isOn)
        } catch {
            return nil
        }
    }

    private struct Values {
        var type: ValueType
        var onValue: JSONValue
        var offValue: JSONValue
    }

    private static func parseValues(_ object: [String: JSONValue]) throws -> Values {
        let declared = object["value_type"] ?? .string(ValueType.bool.rawValue)
        guard let name = declared.stringValue, let type = ValueType(rawValue: name) else {
            throw UnknownConstruct(reason: "unknown value_type")
        }
        let onValue = object["on_value"] ?? .bool(true)
        let offValue = object["off_value"] ?? .bool(false)
        guard matches(value: onValue, type: type), matches(value: offValue, type: type) else {
            throw UnknownConstruct(reason: "value does not match value_type")
        }
        // A bool flag's values are fixed. Anything else would let
        // `isEnabled` (which reads the resolution) and a value read
        // disagree about the same flag.
        if type == .bool, onValue != .bool(true) || offValue != .bool(false) {
            throw UnknownConstruct(reason: "a bool flag serves true when on, false when off")
        }
        return Values(type: type, onValue: onValue, offValue: offValue)
    }

    private static func matches(value: JSONValue, type: ValueType) -> Bool {
        switch type {
        case .bool: return value.boolValue != nil
        case .int: return value.intValue != nil
        // JSON has one number type and no way to mark 2.0 as fractional,
        // so a double flag accepts a whole number too.
        case .double: return value.doubleValue != nil
        case .string: return value.stringValue != nil
        }
    }

    private static func resolveStrict(
        flag: JSONValue, context: [String: JSONValue], stableID: String
    ) throws -> Bool {
        guard let object = flag.objectValue else {
            throw UnknownConstruct(reason: "flag is not an object")
        }
        guard let key = object["key"]?.stringValue else {
            throw UnknownConstruct(reason: "missing key")
        }
        guard let enabled = object["enabled"]?.boolValue else {
            throw UnknownConstruct(reason: "missing/mistyped enabled")
        }
        guard let rules = object["rules"]?.arrayValue else {
            throw UnknownConstruct(reason: "missing/mistyped rules")
        }
        guard let percent = object["default_rollout_percent"]?.intValue,
            (0...100).contains(percent)
        else {
            throw UnknownConstruct(reason: "missing/mistyped default_rollout_percent")
        }
        // 1. Kill switch — checked before rule validation on purpose:
        // `enabled` is a recognized construct, and the one-click emergency
        // lever must work even on builds that can't parse some future rule
        // shape elsewhere in the flag.
        if !enabled { return false }

        // Recognition pass BEFORE any matching: an unknown construct
        // anywhere in the flag must resolve it to the code default even if
        // an earlier rule would already have matched. Skipping validation
        // of later rules could silently widen a restricted audience.
        let parsedRules = try rules.map(parseRule)

        // 2. Rules in order; first match wins.
        for rule in parsedRules {
            if rule.conditions.allSatisfy({ matches(condition: $0, context: context) }) {
                return rule.serve
            }
        }

        // 3. Default rollout.
        return bucket(flagKey: key, stableID: stableID) < percent
    }

    // MARK: - Rule parsing (strict)

    private struct Rule {
        var conditions: [Condition]
        var serve: Bool
    }

    private struct Condition {
        var attribute: String
        var type: AttributeType
        var op: Op
        /// Single comparison value (eq/neq/ordering/semver ops).
        var value: JSONValue?
        /// Membership list (in/not_in).
        var values: [JSONValue]?
    }

    private enum Op: String {
        case eq, neq
        case `in`, notIn = "not_in"
        case gt, gte, lt, lte
        case semverEq = "semver_eq"
        case semverGt = "semver_gt"
        case semverGte = "semver_gte"
        case semverLt = "semver_lt"
        case semverLte = "semver_lte"

        var isMembership: Bool { self == .in || self == .notIn }
        var isOrdering: Bool {
            self == .gt || self == .gte || self == .lt || self == .lte
        }
        var isSemver: Bool {
            switch self {
            case .semverEq, .semverGt, .semverGte, .semverLt, .semverLte: return true
            default: return false
            }
        }
    }

    private static func parseRule(_ json: JSONValue) throws -> Rule {
        guard let object = json.objectValue else {
            throw UnknownConstruct(reason: "rule is not an object")
        }
        guard Set(object.keys).isSubset(of: ["conditions", "serve"]) else {
            throw UnknownConstruct(reason: "rule has unknown fields")
        }
        guard let serve = object["serve"]?.boolValue else {
            throw UnknownConstruct(reason: "missing/mistyped serve")
        }
        guard let conditions = object["conditions"]?.arrayValue else {
            throw UnknownConstruct(reason: "missing/mistyped conditions")
        }
        return Rule(conditions: try conditions.map(parseCondition), serve: serve)
    }

    private static func parseCondition(_ json: JSONValue) throws -> Condition {
        guard let object = json.objectValue else {
            throw UnknownConstruct(reason: "condition is not an object")
        }
        guard Set(object.keys).isSubset(of: ["attribute", "op", "value", "values"]) else {
            throw UnknownConstruct(reason: "condition has unknown fields")
        }
        guard let attribute = object["attribute"]?.stringValue,
            let type = attributeTypes[attribute]
        else {
            throw UnknownConstruct(reason: "unknown attribute")
        }
        guard let opString = object["op"]?.stringValue, let op = Op(rawValue: opString) else {
            throw UnknownConstruct(reason: "unknown op")
        }

        let condition = Condition(
            attribute: attribute, type: type, op: op,
            value: object["value"], values: object["values"]?.arrayValue)

        if op.isMembership {
            // in/not_in: values array of strings or ints, matching the
            // attribute's type; bool membership is not defined in v1.
            guard object["value"] == nil, let values = condition.values, !values.isEmpty else {
                throw UnknownConstruct(reason: "membership op requires values")
            }
            switch type {
            case .string:
                guard values.allSatisfy({ $0.stringValue != nil }) else {
                    throw UnknownConstruct(reason: "mistyped values")
                }
            case .int:
                guard values.allSatisfy({ $0.intValue != nil }) else {
                    throw UnknownConstruct(reason: "mistyped values")
                }
            case .bool:
                throw UnknownConstruct(reason: "membership op on bool attribute")
            }
        } else {
            guard object["values"] == nil, let value = condition.value else {
                throw UnknownConstruct(reason: "op requires a single value")
            }
            if op.isOrdering {
                // gt/gte/lt/lte apply to ints only (data-model.md).
                guard type == .int, value.intValue != nil else {
                    throw UnknownConstruct(reason: "ordering op requires int")
                }
            } else if op.isSemver {
                guard type == .string, let string = value.stringValue else {
                    throw UnknownConstruct(reason: "semver op requires version string")
                }
                guard parseVersion(string) != nil else {
                    throw UnknownConstruct(reason: "unparsable semver value")
                }
            } else {
                // eq/neq: value type must match the attribute type.
                switch type {
                case .string:
                    guard value.stringValue != nil else {
                        throw UnknownConstruct(reason: "mistyped value")
                    }
                case .int:
                    guard value.intValue != nil else {
                        throw UnknownConstruct(reason: "mistyped value")
                    }
                case .bool:
                    guard value.boolValue != nil else {
                        throw UnknownConstruct(reason: "mistyped value")
                    }
                }
            }
        }
        return condition
    }

    // MARK: - Condition matching

    /// Note: a merely-absent context attribute (recognized construct)
    /// matches NO condition — including neq/not_in. That is normal
    /// non-matching, not rule 4.
    private static func matches(condition: Condition, context: [String: JSONValue]) -> Bool {
        guard let contextValue = context[condition.attribute], contextValue != .null else {
            return false
        }
        switch condition.op {
        case .eq:
            return contextValue == condition.value
        case .neq:
            // Context values are normalized to the attribute's type before
            // evaluation; a type-mismatched context value matches nothing.
            guard typed(contextValue, as: condition.type) else { return false }
            return contextValue != condition.value
        case .in:
            return condition.values?.contains(contextValue) ?? false
        case .notIn:
            guard typed(contextValue, as: condition.type) else { return false }
            return !(condition.values?.contains(contextValue) ?? true)
        case .gt, .gte, .lt, .lte:
            guard let lhs = contextValue.intValue, let rhs = condition.value?.intValue else {
                return false
            }
            switch condition.op {
            case .gt: return lhs > rhs
            case .gte: return lhs >= rhs
            case .lt: return lhs < rhs
            case .lte: return lhs <= rhs
            default: return false
            }
        case .semverEq, .semverGt, .semverGte, .semverLt, .semverLte:
            guard let lhsString = contextValue.stringValue,
                let lhs = parseVersion(lhsString),
                let rhsString = condition.value?.stringValue,
                let rhs = parseVersion(rhsString)
            else { return false }
            let order = compareVersions(lhs, rhs)
            switch condition.op {
            case .semverEq: return order == .orderedSame
            case .semverGt: return order == .orderedDescending
            case .semverGte: return order != .orderedAscending
            case .semverLt: return order == .orderedAscending
            case .semverLte: return order != .orderedDescending
            default: return false
            }
        }
    }

    private static func typed(_ value: JSONValue, as type: AttributeType) -> Bool {
        switch type {
        case .string: return value.stringValue != nil
        case .int: return value.intValue != nil
        case .bool: return value.boolValue != nil
        }
    }

    // MARK: - Version comparison (data-model.md)

    /// Split on ".", compare numerically component-by-component, missing
    /// components are 0. Any non-numeric component makes the value
    /// unparsable.
    static func parseVersion(_ string: String) -> [Int]? {
        let components = string.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }
        var numbers: [Int] = []
        for component in components {
            guard !component.isEmpty, component.allSatisfy(\.isNumber),
                let number = Int(component)
            else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    static func compareVersions(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left < right ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    // MARK: - Bucketing (data-model.md, normative)

    /// bucket = big_endian_uint32(sha256(utf8(flag_key + ":" + stable_id))[0..3]) mod 100
    static func bucket(flagKey: String, stableID: String) -> Int {
        let digest = SHA256.hash(data: Data((flagKey + ":" + stableID).utf8))
        let bytes = Array(digest.prefix(4))
        let value =
            UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
        return Int(value % 100)
    }

    // MARK: - Email hashing (data-model.md)

    /// email_hash = lowercase_hex(sha256(utf8(lowercase(trim(email)))))
    static func emailHash(_ email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
