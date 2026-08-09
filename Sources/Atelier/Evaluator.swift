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

    /// What a flag may serve (ADR 0013); every rule's value matches it.
    enum ValueType: String {
        case bool, int, double, string
    }

    /// Read a flag (as loose JSON, or nil when absent from the config)
    /// for a caller reading `readAs`.
    ///
    /// Returns the value of the first rule that matches this context —
    /// or nil, meaning **the caller must use the default it compiled in**
    /// (ADR 0014). Nil covers every other outcome there is: the flag is
    /// absent, `enabled` is false so it overrides nobody, no rule matched,
    /// `readAs` is not the type the flag declares (reads are exact — no
    /// widening, no coercion), or anything rule 4 covers. A flag with no
    /// `value_type` is a bool flag.
    static func resolveValue(
        flag: JSONValue?, context: [String: JSONValue], stableID: String, readAs: ValueType
    ) -> JSONValue? {
        guard let flag, let object = flag.objectValue else { return nil }
        do {
            let declared = object["value_type"] ?? .string(ValueType.bool.rawValue)
            guard let name = declared.stringValue, let type = ValueType(rawValue: name) else {
                throw UnknownConstruct(reason: "unknown value_type")
            }
            guard type == readAs else { return nil }
            return try resolveStrict(
                flag: flag, context: context, stableID: stableID, type: type)
        } catch {
            // Rule 4: anything unrecognized sends the whole flag to the
            // caller's compiled-in default — never "skip the rule".
            return nil
        }
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

    /// Nil means "nothing overrode this user"; throwing means rule 4.
    private static func resolveStrict(
        flag: JSONValue, context: [String: JSONValue], stableID: String, type: ValueType
    ) throws -> JSONValue? {
        guard let object = flag.objectValue else {
            throw UnknownConstruct(reason: "flag is not an object")
        }
        guard let key = object["key"]?.stringValue else {
            throw UnknownConstruct(reason: "missing key")
        }
        guard let enabled = object["enabled"]?.boolValue else {
            throw UnknownConstruct(reason: "missing/mistyped enabled")
        }
        // 1. Master switch — checked before rule validation on purpose:
        // `enabled` is a recognized construct, and the one-click lever must
        // work even on builds that can't parse some future rule shape
        // elsewhere in the flag. It overrides nobody; it is not "off".
        if !enabled { return nil }

        guard let rules = object["rules"]?.arrayValue else {
            throw UnknownConstruct(reason: "missing/mistyped rules")
        }

        // Recognition pass BEFORE any matching: an unknown construct
        // anywhere in the flag must send it to the code default even if an
        // earlier rule would already have matched. Skipping validation of
        // later rules could silently widen a restricted audience.
        let parsedRules = try rules.map { try parseRule($0, type: type) }

        // 2. Rules in order; first match wins. A rule matches when all its
        // conditions match and its rollout gate lets this user through.
        for rule in parsedRules {
            guard rule.conditions.allSatisfy({ matches(condition: $0, context: context) })
            else { continue }
            if let percent = rule.rolloutPercent,
                bucket(flagKey: key, stableID: stableID) >= percent
            { continue }
            return rule.value
        }

        // 3. Nobody claimed this user: their app keeps its own default.
        return nil
    }

    // MARK: - Rule parsing (strict)

    private struct Rule {
        var conditions: [Condition]
        /// Nil means every user the conditions match.
        var rolloutPercent: Int?
        var value: JSONValue
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

    private static func parseRule(_ json: JSONValue, type: ValueType) throws -> Rule {
        guard let object = json.objectValue else {
            throw UnknownConstruct(reason: "rule is not an object")
        }
        guard Set(object.keys).isSubset(of: ["conditions", "rollout_percent", "value"]) else {
            throw UnknownConstruct(reason: "rule has unknown fields")
        }
        guard let value = object["value"] else {
            throw UnknownConstruct(reason: "rule is missing a value")
        }
        guard matches(value: value, type: type) else {
            throw UnknownConstruct(reason: "rule value does not match value_type")
        }
        guard let conditions = object["conditions"]?.arrayValue else {
            throw UnknownConstruct(reason: "missing/mistyped conditions")
        }
        // Absent is the common case and means "everyone the conditions
        // matched". Present-but-unusable is rule 4, not a silent 100%.
        var rolloutPercent: Int?
        if let raw = object["rollout_percent"] {
            guard let percent = raw.intValue, (0...100).contains(percent) else {
                throw UnknownConstruct(reason: "mistyped rollout_percent")
            }
            rolloutPercent = percent
        }
        return Rule(
            conditions: try conditions.map(parseCondition),
            rolloutPercent: rolloutPercent,
            value: value)
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
