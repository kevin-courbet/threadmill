import Foundation
import XCTest
@testable import Threadmill

final class RelayBinaryLocatorTests: XCTestCase {
    func testResolveUsesBundleExecutableDirectoryWhenCommandLinePathIsRelative() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let binaryDir = tempDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDir, withIntermediateDirectories: true)

        let bundleExecutablePath = binaryDir.appendingPathComponent("Threadmill").path
        let relayPath = binaryDir.appendingPathComponent("threadmill-relay").path
        try createExecutable(atPath: bundleExecutablePath)
        try createExecutable(atPath: relayPath)

        let resolved = RelayBinaryLocator.resolve(
            environment: [:],
            bundleExecutablePath: bundleExecutablePath,
            commandLineExecutablePath: "Threadmill",
            currentDirectoryPath: "/"
        )

        XCTAssertEqual(resolved, relayPath)
    }

    func testResolveDoesNotFallBackToHardcodedNonexistentPath() {
        let resolved = RelayBinaryLocator.resolve(
            environment: [:],
            bundleExecutablePath: "/tmp/missing/Threadmill",
            commandLineExecutablePath: "Threadmill",
            currentDirectoryPath: "/"
        )

        XCTAssertNil(resolved)
    }

    func testResolveFindsRelayBinaryInAncestorBuildProductsDirectory() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let debugDir = tempDir
            .appendingPathComponent("Build", isDirectory: true)
            .appendingPathComponent("Products", isDirectory: true)
            .appendingPathComponent("Debug", isDirectory: true)
        let executableDir = debugDir
            .appendingPathComponent("Threadmill.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)

        try FileManager.default.createDirectory(at: executableDir, withIntermediateDirectories: true)

        let bundleExecutablePath = executableDir.appendingPathComponent("Threadmill").path
        let relayPath = debugDir.appendingPathComponent("threadmill-relay").path
        try createExecutable(atPath: bundleExecutablePath)
        try createExecutable(atPath: relayPath)

        let resolved = RelayBinaryLocator.resolve(
            environment: [:],
            bundleExecutablePath: bundleExecutablePath,
            commandLineExecutablePath: "",
            currentDirectoryPath: "/"
        )

        XCTAssertEqual(resolved, relayPath)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func createExecutable(atPath path: String) throws {
        let data = Data("#!/bin/sh\nexit 0\n".utf8)
        let url = URL(fileURLWithPath: path)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}
