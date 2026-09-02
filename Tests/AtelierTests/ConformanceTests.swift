import CryptoKit
import Foundation
import XCTest

@testable import Atelier

/// Wires spec/test-vectors.json into the suite. The vectors are the
/// cross-implementation contract, maintained canonically in the Atelier
/// spec repository and mirrored here — any evaluator change must update
/// both copies in the same change (AGENTS.md).
final class ConformanceTests: XCTestCase {

    private struct Vectors: Decodable {
        struct Bucketing: Decodable {
            struct Vector: Decodable {
                let flag_key: String
                let stable_id: String
                let expected_bucket: Int
            }
            let vectors: [Vector]
        }
        struct EmailHashing: Decodable {
            struct Vector: Decodable {
                let input: String
                let expected_hash: String
            }
            let vectors: [Vector]
        }
        /// Every case is a read: `read_as` is the type the calling code
        /// asked for and `code_default` its compiled-in default, which is
        /// the expected value for every outcome but a matching rule.
        struct Evaluation: Decodable {
            struct Case: Decodable {
                let name: String
                let flag: JSONValue?
                let context: [String: JSONValue]
                let read_as: String
                let code_default: JSONValue
                let expected_value: JSONValue
            }
            let cases: [Case]
        }
        /// Config signature verification (ADR 0017). The tokens are
        /// fixed artifacts to be verified, not reproduced — ECDSA
        /// signatures are randomized, so an implementation cannot check
        /// itself by re-signing.
        struct Signature: Decodable {
            struct PublicJWK: Decodable {
                let x: String
                let y: String
                let kid: String
            }
            struct Vector: Decodable {
                let name: String
                let expect: String
                let org: String
                let app: String
                let cached_revision: Int
                let token: String
            }
            let public_jwk: PublicJWK
            let vectors: [Vector]
        }
        let bucketing: Bucketing
        let email_hashing: EmailHashing
        let evaluation: Evaluation
        let signature: Signature
    }

    private static func loadVectors() throws -> Vectors {
        // <repo>/Tests/AtelierTests/ConformanceTests.swift
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AtelierTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("spec/test-vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testBucketingVectors() throws {
        let vectors = try Self.loadVectors().bucketing.vectors
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            XCTAssertEqual(
                Evaluator.bucket(flagKey: vector.flag_key, stableID: vector.stable_id),
                vector.expected_bucket,
                "bucket(\(vector.flag_key), \(vector.stable_id))")
        }
    }

    func testEmailHashingVectors() throws {
        let vectors = try Self.loadVectors().email_hashing.vectors
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            XCTAssertEqual(
                Evaluator.emailHash(vector.input), vector.expected_hash,
                "emailHash(\(vector.input))")
        }
    }

    func testSignatureVectors() throws {
        let spec = try Self.loadVectors().signature
        XCTAssertFalse(spec.vectors.isEmpty)

        // The vectors publish the key as a JWK, which is the JWKS
        // format; an app supplies the same key as one string. Note the
        // conversion is over *bytes*, not text: 32 bytes is not a
        // multiple of 3, so concatenating the two base64url strings
        // encodes something else entirely.
        guard let x = ConfigSignature.base64urlDecode(Array(spec.public_jwk.x.utf8)),
            let y = ConfigSignature.base64urlDecode(Array(spec.public_jwk.y.utf8))
        else {
            XCTFail("vector public_jwk is not base64url")
            return
        }
        let anchors = ConfigSignature.anchors(from: [base64url(x + y)])
        XCTAssertEqual(anchors.count, 1, "vector public_jwk is not a usable P-256 key")

        for vector in spec.vectors {
            let fetched = ConfigSignature.verifiedDocument(
                Data(vector.token.utf8),
                anchors: anchors,
                organization: vector.org,
                product: vector.app,
                cachedRevision: vector.cached_revision)

            let accepted: Bool
            if case .document = fetched { accepted = true } else { accepted = false }
            XCTAssertEqual(
                accepted, vector.expect == "accept",
                "vector \(vector.name) should \(vector.expect)")
        }
    }

    /// The trust store is what the whole scheme rests on: a build that
    /// verifies against a fetched key verifies nothing at all.
    func testVerificationRefusesEverythingWithoutAnchors() throws {
        let spec = try Self.loadVectors().signature
        guard let valid = spec.vectors.first(where: { $0.expect == "accept" }) else {
            XCTFail("vectors carry no accepted token")
            return
        }
        let fetched = ConfigSignature.verifiedDocument(
            Data(valid.token.utf8),
            anchors: [],
            organization: valid.org,
            product: valid.app,
            cachedRevision: nil)
        guard case .unavailable = fetched else {
            XCTFail("an empty trust store must accept nothing")
            return
        }
    }

    /// base64url of raw bytes — the form an app pastes.
    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func testEvaluationVectors() throws {
        let cases = try Self.loadVectors().evaluation.cases
        XCTAssertFalse(cases.isEmpty)
        for testCase in cases {
            guard let stableID = testCase.context["stable_id"]?.stringValue else {
                XCTFail("\(testCase.name): vector context missing stable_id")
                continue
            }
            guard let readAs = Evaluator.ValueType(rawValue: testCase.read_as) else {
                XCTFail("\(testCase.name): unknown read_as \(testCase.read_as)")
                continue
            }
            let flag: JSONValue? = testCase.flag.flatMap { $0 == .null ? nil : $0 }
            let resolved = Evaluator.resolveValue(
                flag: flag,
                context: testCase.context,
                stableID: stableID,
                readAs: readAs)

            // Compare in the type the read asked for — the same narrowing
            // the public `value(_:default:)` overloads do — so `2` and
            // `2.0` are one double and `"10"` is never `10`.
            func scalar(_ value: JSONValue) -> String? {
                switch readAs {
                case .bool: return value.boolValue.map { "\($0)" }
                case .int: return value.intValue.map { "\($0)" }
                case .double: return value.doubleValue.map { "\($0)" }
                case .string: return value.stringValue
                }
            }
            guard let expected = scalar(testCase.expected_value) else {
                XCTFail("\(testCase.name): expected_value is not a \(testCase.read_as)")
                continue
            }
            XCTAssertEqual(
                scalar(resolved ?? testCase.code_default), expected, testCase.name)
        }
    }
}
