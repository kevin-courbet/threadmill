import Foundation
import XCTest

final class ProtocolSchemaTests: XCTestCase {
    func testSchemaDeclaresSystemStatsAndOmitsSystemCleanupMethod() throws {
        let schema = try loadSchema()
        let methods = try XCTUnwrap(schema["methods"] as? [String: Any])
        let defs = try XCTUnwrap(schema["$defs"] as? [String: Any])

        let statsMethod = try XCTUnwrap(methods["system.stats"] as? [String: Any])
        let statsResult = try XCTUnwrap(statsMethod["result"] as? [String: Any])
        XCTAssertEqual(statsResult["$ref"] as? String, "#/$defs/SystemStatsResult")
        XCTAssertNotNil(defs["SystemStatsResult"])

        XCTAssertNil(methods["system.cleanup"])
    }

    private func loadSchema() throws -> [String: Any] {
        let schemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("protocol/threadmill-rpc.schema.json")

        let data = try Data(contentsOf: schemaURL)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return try XCTUnwrap(object as? [String: Any])
    }
}
