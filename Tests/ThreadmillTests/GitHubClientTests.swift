import Foundation
import XCTest
@testable import Threadmill

@MainActor
final class GitHubClientTests: XCTestCase {
    func testFetchUserReposPaginatesAcrossLinkHeader() async throws {
        var requests: [URLRequest] = []
        var pollCount = 0

        let client = GitHubClient(token: "gho_test") { request in
            requests.append(request)
            pollCount += 1

            guard let url = request.url else {
                throw TestError.forcedFailure
            }

            if pollCount == 1 {
                XCTAssertEqual(url.absoluteString, "https://api.github.com/user/repos?per_page=100")
                let data = try JSONSerialization.data(withJSONObject: [
                    [
                        "id": 1,
                        "full_name": "anomalyco/threadmill",
                        "name": "threadmill",
                        "owner": ["login": "anomalyco"],
                        "clone_url": "https://github.com/anomalyco/threadmill.git",
                        "ssh_url": "git@github.com:anomalyco/threadmill.git",
                        "default_branch": "main",
                        "private": true,
                        "description": "Thread manager",
                        "pushed_at": "2026-03-05T10:00:00Z",
                    ]
                ])
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "Link": "<https://api.github.com/user/repos?per_page=100&page=2>; rel=\"next\""
                        ]
                    )
                )
                return (data, response)
            }

            let data = try JSONSerialization.data(withJSONObject: [
                [
                    "id": 2,
                    "full_name": "anomalyco/spindle",
                    "name": "spindle",
                    "owner": ["login": "anomalyco"],
                    "clone_url": "https://github.com/anomalyco/spindle.git",
                    "ssh_url": "git@github.com:anomalyco/spindle.git",
                    "default_branch": "main",
                    "private": false,
                    "description": "Daemon",
                    "pushed_at": "2026-03-04T10:00:00Z",
                ]
            ])
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (data, response)
        }

        let repos = try await client.fetchUserRepos()

        XCTAssertEqual(repos.map(\.id), [1, 2])
        XCTAssertEqual(repos.map(\.fullName), ["anomalyco/threadmill", "anomalyco/spindle"])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer gho_test")
    }

    func testMapToRepoPrefersSSHCloneURL() {
        let client = GitHubClient(token: "gho_test") { _ in
            throw TestError.missingStub
        }

        let gitHubRepo = GitHubRepo(
            id: 1,
            fullName: "anomalyco/threadmill",
            name: "threadmill",
            owner: GitHubOwner(login: "anomalyco"),
            cloneUrl: "https://github.com/anomalyco/threadmill.git",
            sshUrl: "git@github.com:anomalyco/threadmill.git",
            defaultBranch: "main",
            isPrivate: true,
            description: nil,
            pushedAt: nil
        )
        let cachedAt = Date(timeIntervalSince1970: 42)

        let repo = client.mapToRepo(gitHubRepo, cachedAt: cachedAt)

        XCTAssertEqual(repo.owner, "anomalyco")
        XCTAssertEqual(repo.name, "threadmill")
        XCTAssertEqual(repo.fullName, "anomalyco/threadmill")
        XCTAssertEqual(repo.cloneURL, "git@github.com:anomalyco/threadmill.git")
        XCTAssertEqual(repo.defaultBranch, "main")
        XCTAssertTrue(repo.isPrivate)
        XCTAssertEqual(repo.cachedAt, cachedAt)
    }

    func testValidateTokenReturnsFalseAndClearsAuthOnUnauthorized() async {
        var didClearAuth = false
        let client = GitHubClient(token: "gho_test", onUnauthorized: {
            didClearAuth = true
        }) { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)
            )
            return (Data("unauthorized".utf8), response)
        }

        let isValid = await client.validateToken()

        XCTAssertFalse(isValid)
        XCTAssertTrue(didClearAuth)
    }

    func testFetchUserReposClearsAuthOnUnauthorized() async {
        var didClearAuth = false
        let client = GitHubClient(token: "gho_test", onUnauthorized: {
            didClearAuth = true
        }) { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)
            )
            return (Data("unauthorized".utf8), response)
        }

        do {
            _ = try await client.fetchUserRepos()
            XCTFail("Expected unauthorized error")
        } catch {
            guard case let GitHubClientError.requestFailed(statusCode, _) = error else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertEqual(statusCode, 401)
        }

        XCTAssertTrue(didClearAuth)
    }
}
