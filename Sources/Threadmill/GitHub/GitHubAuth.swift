import AppKit
import Foundation
import Observation
import Security

// Register a GitHub OAuth App and replace this client ID (or set THREADMILL_GITHUB_CLIENT_ID in env).
let THREADMILL_GITHUB_CLIENT_ID: String = {
    if let clientID = ProcessInfo.processInfo.environment["THREADMILL_GITHUB_CLIENT_ID"], !clientID.isEmpty {
        return clientID
    }
    return "THREADMILL_GITHUB_CLIENT_ID"
}()

enum GitHubAuthError: LocalizedError {
    case missingClientID
    case invalidResponse
    case requestFailed(statusCode: Int, message: String)
    case expiredDeviceCode
    case accessDenied
    case missingAccessToken
    case keychainError(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "GitHub OAuth client ID is missing."
        case .invalidResponse:
            return "GitHub OAuth returned an invalid response."
        case let .requestFailed(statusCode, message):
            return "GitHub OAuth request failed (\(statusCode)): \(message)"
        case .expiredDeviceCode:
            return "GitHub device code expired before authorization completed."
        case .accessDenied:
            return "GitHub authorization was denied."
        case .missingAccessToken:
            return "GitHub OAuth completed without an access token."
        case let .keychainError(status):
            return "Keychain operation failed (status: \(status))."
        }
    }
}

struct KeychainHelper {
    static func save(service: String, account: String, token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GitHubAuthError.keychainError(status: status)
        }
    }

    static func load(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw GitHubAuthError.keychainError(status: status)
        }
        guard let data = item as? Data else {
            throw GitHubAuthError.invalidResponse
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubAuthError.keychainError(status: status)
        }
    }
}

private struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct AccessTokenResponse: Decodable {
    let accessToken: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case error
        case errorDescription = "error_description"
    }
}

@MainActor
@Observable
final class GitHubAuthManager {
    var isAuthenticated = false
    var userCode: String?
    var verificationURL: URL?
    var isPolling = false

    private let clientID: String
    private let dataLoader: GitHubDataLoader
    private let openVerificationURL: (URL) -> Void
    private let saveToken: (String) throws -> Void
    private let loadToken: () throws -> String?
    private let deleteToken: () throws -> Void
    private let sleep: (TimeInterval) async -> Void
    private var token: String?

    init(
        clientID: String = THREADMILL_GITHUB_CLIENT_ID,
        service: String = "dev.threadmill.github",
        account: String = "access_token",
        dataLoader: @escaping GitHubDataLoader = GitHubAuthManager.defaultDataLoader,
        openVerificationURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        saveToken: ((String) throws -> Void)? = nil,
        loadToken: (() throws -> String?)? = nil,
        deleteToken: (() throws -> Void)? = nil,
        sleep: @escaping (TimeInterval) async -> Void = { interval in
            let nanoseconds = UInt64(max(interval, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.clientID = clientID
        self.dataLoader = dataLoader
        self.openVerificationURL = openVerificationURL
        self.saveToken = saveToken ?? { token in
            try KeychainHelper.save(service: service, account: account, token: token)
        }
        self.loadToken = loadToken ?? {
            try KeychainHelper.load(service: service, account: account)
        }
        self.deleteToken = deleteToken ?? {
            try KeychainHelper.delete(service: service, account: account)
        }
        self.sleep = sleep
    }

    func startDeviceFlow() async throws {
        guard !clientID.isEmpty, clientID != "THREADMILL_GITHUB_CLIENT_ID" else {
            throw GitHubAuthError.missingClientID
        }

        let deviceCode = try await requestDeviceCode()
        guard let verificationURL = URL(string: deviceCode.verificationURI) else {
            throw GitHubAuthError.invalidResponse
        }

        userCode = deviceCode.userCode
        self.verificationURL = verificationURL
        openVerificationURL(verificationURL)

        isPolling = true
        defer { isPolling = false }

        let accessToken = try await pollForAccessToken(
            deviceCode: deviceCode.deviceCode,
            expiresIn: deviceCode.expiresIn,
            interval: deviceCode.interval
        )

        try saveToken(accessToken)
        token = accessToken
        isAuthenticated = true
        userCode = nil
        self.verificationURL = nil
    }

    func logout() {
        do {
            try deleteToken()
        } catch {
            NSLog("threadmill-github-auth: failed to delete keychain token: %@", "\(error)")
        }
        token = nil
        isAuthenticated = false
        userCode = nil
        verificationURL = nil
        isPolling = false
    }

    func loadStoredToken() -> Bool {
        do {
            guard let token = try loadToken(), !token.isEmpty else {
                self.token = nil
                isAuthenticated = false
                return false
            }

            self.token = token
            isAuthenticated = true
            return true
        } catch {
            NSLog("threadmill-github-auth: failed to load keychain token: %@", "\(error)")
            self.token = nil
            isAuthenticated = false
            return false
        }
    }

    func currentToken() -> String? {
        token
    }

    private func requestDeviceCode() async throws -> DeviceCodeResponse {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedBody([
            "client_id": clientID,
            "scope": "repo",
        ])

        let (data, response) = try await dataLoader(request)
        guard (200..<300).contains(response.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown GitHub OAuth error"
            throw GitHubAuthError.requestFailed(statusCode: response.statusCode, message: message)
        }

        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    private func pollForAccessToken(deviceCode: String, expiresIn: Int, interval: Int) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        var pollingInterval = TimeInterval(interval)

        while Date() < deadline {
            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formEncodedBody([
                "client_id": clientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])

            let (data, response) = try await dataLoader(request)
            guard (200..<300).contains(response.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? "Unknown GitHub OAuth error"
                throw GitHubAuthError.requestFailed(statusCode: response.statusCode, message: message)
            }

            let tokenResponse = try JSONDecoder().decode(AccessTokenResponse.self, from: data)
            if let accessToken = tokenResponse.accessToken, !accessToken.isEmpty {
                return accessToken
            }

            switch tokenResponse.error {
            case "authorization_pending":
                await sleep(pollingInterval)
            case "slow_down":
                pollingInterval += 5
                await sleep(pollingInterval)
            case "access_denied":
                throw GitHubAuthError.accessDenied
            case "expired_token":
                throw GitHubAuthError.expiredDeviceCode
            case let .some(errorCode):
                throw GitHubAuthError.requestFailed(statusCode: response.statusCode, message: tokenResponse.errorDescription ?? errorCode)
            case .none:
                throw GitHubAuthError.missingAccessToken
            }
        }

        throw GitHubAuthError.expiredDeviceCode
    }

    private func formEncodedBody(_ values: [String: String]) -> Data {
        let body = values
            .map { key, value in
                "\(urlEncode(key))=\(urlEncode(value))"
            }
            .sorted()
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private static func defaultDataLoader(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubAuthError.invalidResponse
        }
        return (data, httpResponse)
    }
}
