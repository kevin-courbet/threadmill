import XCTest
@testable import Threadmill

final class RemotePathNormalizationTests: XCTestCase {
    func testDefaultWorkspacePathUsesSharedPathNormalization() {
        let remote = Remote(
            id: "remote-1",
            name: "beast",
            host: "beast",
            daemonPort: 19990,
            useSSHTunnel: true,
            cloneRoot: "/home/wsl/dev///"
        )

        XCTAssertEqual(remote.defaultWorkspacePath, "/home/wsl")
        XCTAssertEqual("/home/wsl///".normalizedRemotePath, "/home/wsl")
        XCTAssertEqual("/".normalizedRemotePath, "/")
    }
}
