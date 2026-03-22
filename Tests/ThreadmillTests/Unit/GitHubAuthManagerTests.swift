import Foundation
import XCTest
@testable import Threadmill

@MainActor
final class GitHubAuthManagerTests: XCTestCase {
    func testStartDeviceFlowPollsUntilAuthorizedAndSavesToken() async throws {
        var openedVerificationURL: URL?
        var savedToken: String?
        var pollCount = 0

        let manager = GitHubAuthManager(
            clientID: "test-client-id",
            dataLoader: { request in
                guard let url = request.url else {
                    throw TestError.forcedFailure
                }

                if url.absoluteString == "https://github.com/login/device/code" {
                    let response = try XCTUnwrap(
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                    )
                    let data = try JSONSerialization.data(withJSONObject: [
                        "device_code": "device-123",
                        "user_code": "ABCD-EFGH",
                        "verification_uri": "https://github.com/login/device",
                        "expires_in": 600,
                        "interval": 1,
                    ])
                    return (data, response)
                }

                pollCount += 1
                let response = try XCTUnwrap(
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                )

                if pollCount == 1 {
                    let pending = try JSONSerialization.data(withJSONObject: ["error": "authorization_pending"])
                    return (pending, response)
                }

                let success = try JSONSerialization.data(withJSONObject: [
                    "access_token": "gho_123",
                    "token_type": "bearer",
                    "scope": "repo",
                ])
                return (success, response)
            },
            openVerificationURL: { openedVerificationURL = $0 },
            saveToken: { savedToken = $0 },
            loadToken: { nil },
            deleteToken: {},
            sleep: { _ in }
        )

        try await manager.startDeviceFlow()

        XCTAssertTrue(manager.isAuthenticated)
        XCTAssertFalse(manager.isPolling)
        XCTAssertEqual(savedToken, "gho_123")
        XCTAssertEqual(openedVerificationURL?.absoluteString, "https://github.com/login/device")
        XCTAssertEqual(pollCount, 2)
    }

    func testLoadStoredTokenAndLogoutUpdateState() throws {
        var storedToken: String? = "gho_existing"

        let manager = GitHubAuthManager(
            clientID: "test-client-id",
            dataLoader: { _ in throw TestError.missingStub },
            openVerificationURL: { _ in },
            saveToken: { storedToken = $0 },
            loadToken: { storedToken },
            deleteToken: { storedToken = nil },
            sleep: { _ in }
        )

        XCTAssertTrue(manager.loadStoredToken())
        XCTAssertTrue(manager.isAuthenticated)

        manager.logout()

        XCTAssertFalse(manager.isAuthenticated)
        XCTAssertNil(storedToken)
    }
}
