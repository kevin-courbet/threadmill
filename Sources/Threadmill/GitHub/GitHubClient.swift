import Foundation

@MainActor
protocol GitHubAPI: AnyObject {
    func fetchUserRepos() async throws -> [GitHubRepo]
    func fetchOrgRepos(org: String) async throws -> [GitHubRepo]
    func validateToken() async -> Bool
}

struct GitHubRepo: Codable {
    let id: Int
    let fullName: String
    let name: String
    let owner: GitHubOwner
    let cloneUrl: String
    let sshUrl: String
    let defaultBranch: String
    let isPrivate: Bool
    let description: String?
    let pushedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case name
        case owner
        case cloneUrl = "clone_url"
        case sshUrl = "ssh_url"
        case defaultBranch = "default_branch"
        case isPrivate = "private"
        case description
        case pushedAt = "pushed_at"
    }
}

struct GitHubOwner: Codable {
    let login: String
}

enum GitHubClientError: LocalizedError {
    case missingToken
    case invalidResponse
    case requestFailed(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "GitHub token is not configured."
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case let .requestFailed(statusCode, message):
            return "GitHub request failed (\(statusCode)): \(message)"
        }
    }
}

typealias GitHubDataLoader = (URLRequest) async throws -> (Data, HTTPURLResponse)

@MainActor
final class GitHubClient: GitHubAPI {
    private let tokenProvider: () -> String?
    private let onUnauthorized: @MainActor () -> Void
    private let dataLoader: GitHubDataLoader
    private let decoder = JSONDecoder()

    init(
        token: String,
        onUnauthorized: @escaping @MainActor () -> Void = {},
        dataLoader: @escaping GitHubDataLoader = GitHubClient.defaultDataLoader
    ) {
        self.tokenProvider = { token }
        self.onUnauthorized = onUnauthorized
        self.dataLoader = dataLoader
    }

    init(
        tokenProvider: @escaping () -> String?,
        onUnauthorized: @escaping @MainActor () -> Void = {},
        dataLoader: @escaping GitHubDataLoader = GitHubClient.defaultDataLoader
    ) {
        self.tokenProvider = tokenProvider
        self.onUnauthorized = onUnauthorized
        self.dataLoader = dataLoader
    }

    func fetchUserRepos() async throws -> [GitHubRepo] {
        let url = try makeURL(path: "/user/repos", queryItems: [URLQueryItem(name: "per_page", value: "100")])
        return try await fetchPaginatedRepos(startingAt: url)
    }

    func fetchOrgRepos(org: String) async throws -> [GitHubRepo] {
        let url = try makeURL(path: "/orgs/\(org)/repos", queryItems: [URLQueryItem(name: "per_page", value: "100")])
        return try await fetchPaginatedRepos(startingAt: url)
    }

    func validateToken() async -> Bool {
        do {
            let url = try makeURL(path: "/user", queryItems: [])
            let request = try makeRequest(url: url)
            let (_, response) = try await dataLoader(request)
            if response.statusCode == 401 {
                onUnauthorized()
                return false
            }
            return (200..<300).contains(response.statusCode)
        } catch {
            return false
        }
    }

    func mapToRepo(_ gitHubRepo: GitHubRepo, existingID: String? = nil, cachedAt: Date = Date()) -> Repo {
        Repo(
            id: existingID ?? UUID().uuidString,
            owner: gitHubRepo.owner.login,
            name: gitHubRepo.name,
            fullName: gitHubRepo.fullName,
            cloneURL: gitHubRepo.sshUrl.isEmpty ? gitHubRepo.cloneUrl : gitHubRepo.sshUrl,
            defaultBranch: gitHubRepo.defaultBranch,
            isPrivate: gitHubRepo.isPrivate,
            cachedAt: cachedAt
        )
    }

    private func fetchPaginatedRepos(startingAt startURL: URL) async throws -> [GitHubRepo] {
        var allRepos: [GitHubRepo] = []
        var nextURL: URL? = startURL

        while let url = nextURL {
            let request = try makeRequest(url: url)
            let (data, response) = try await dataLoader(request)

            guard (200..<300).contains(response.statusCode) else {
                if response.statusCode == 401 {
                    onUnauthorized()
                }
                let message = String(data: data, encoding: .utf8) ?? "Unknown GitHub API error"
                throw GitHubClientError.requestFailed(statusCode: response.statusCode, message: message)
            }

            let repos = try decoder.decode([GitHubRepo].self, from: data)
            allRepos.append(contentsOf: repos)
            nextURL = parseNextURL(from: response)
        }

        return allRepos
    }

    private func makeRequest(url: URL) throws -> URLRequest {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw GitHubClientError.missingToken
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = path
        components.queryItems = queryItems

        guard let url = components.url else {
            throw GitHubClientError.invalidResponse
        }
        return url
    }

    private func parseNextURL(from response: HTTPURLResponse) -> URL? {
        guard let linkHeader = response.value(forHTTPHeaderField: "Link") else {
            return nil
        }

        for rawPart in linkHeader.split(separator: ",") {
            let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard part.contains("rel=\"next\"") else {
                continue
            }

            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end else {
                continue
            }

            let urlString = String(part[part.index(after: start)..<end])
            if let url = URL(string: urlString) {
                return url
            }
        }

        return nil
    }

    private static func defaultDataLoader(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubClientError.invalidResponse
        }
        return (data, httpResponse)
    }
}
