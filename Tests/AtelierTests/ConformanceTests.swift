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
        struct Evaluation: Decodable {
            struct Case: Decodable {
                let name: String
                let flag: JSONValue?
                let context: [String: JSONValue]
                let code_default: Bool
                let expected_on: Bool
            }
            let cases: [Case]
        }
        let bucketing: Bucketing
        let email_hashing: EmailHashing
        let evaluation: Evaluation
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

    func testEvaluationVectors() throws {
        let cases = try Self.loadVectors().evaluation.cases
        XCTAssertFalse(cases.isEmpty)
        for testCase in cases {
            guard let stableID = testCase.context["stable_id"]?.stringValue else {
                XCTFail("\(testCase.name): vector context missing stable_id")
                continue
            }
            let flag: JSONValue? = testCase.flag.flatMap { $0 == .null ? nil : $0 }
            let isOn = Evaluator.resolve(
                flag: flag,
                context: testCase.context,
                stableID: stableID,
                codeDefault: testCase.code_default)
            XCTAssertEqual(isOn, testCase.expected_on, testCase.name)
        }
    }
}
