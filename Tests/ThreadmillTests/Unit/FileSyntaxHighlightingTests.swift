import CodeEditLanguages
import Foundation
import SwiftTreeSitter
import XCTest
@testable import Threadmill

final class FileSyntaxHighlightingTests: XCTestCase {
    func testTreeSitterTypescriptLoadsAndParses() throws {
        let lang = CodeLanguage.typescript
        XCTAssertNotNil(lang.language, "TypeScript tree-sitter language failed to load from xcframework")
        XCTAssertNotNil(lang.queryURL, "TypeScript highlights.scm query URL is nil")

        // Verify highlights.scm is readable
        let queryURL = try XCTUnwrap(lang.queryURL)
        let queryData = try Data(contentsOf: queryURL)
        XCTAssertGreaterThan(queryData.count, 0, "highlights.scm is empty")

        // Verify TreeSitterModel can build a Query
        let query = TreeSitterModel.shared.query(for: lang.id)
        XCTAssertNotNil(query, "TreeSitterModel failed to create query for TypeScript")
        if let q = query {
            XCTAssertGreaterThan(q.patternCount, 0, "TypeScript query has 0 patterns")
        }

        // Verify parser can parse TypeScript code
        let parser = Parser()
        let tsLang = try XCTUnwrap(lang.language)
        try parser.setLanguage(tsLang)
        let code = "const x: number = 42;"
        let tree = parser.parse(code)
        XCTAssertNotNil(tree, "Parser returned nil tree for TypeScript code")
        XCTAssertNotNil(tree?.rootNode, "Parse tree has no root node")
    }

    func testLanguageDetectionReturnsTypescriptForTsExtension() {
        let lang = LanguageDetection.language(for: "/some/path/file.ts")
        XCTAssertEqual(lang.id, .typescript)
    }
}
