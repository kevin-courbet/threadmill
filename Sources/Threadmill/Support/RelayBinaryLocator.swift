import Foundation

enum RelayBinaryLocator {
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleExecutablePath: String = Bundle.main.executablePath ?? "",
        commandLineExecutablePath: String = CommandLine.arguments.first ?? "",
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> String? {
        if let overridePath = environment["THREADMILL_RELAY_PATH"],
           FileManager.default.isExecutableFile(atPath: overridePath)
        {
            return overridePath
        }

        var candidates = [String]()
        let executableURLs = [bundleExecutablePath, commandLineExecutablePath]
            .compactMap { executableURL(for: $0, currentDirectoryPath: currentDirectoryPath) }

        for executableURL in executableURLs {
            var searchDirectory = executableURL.deletingLastPathComponent()
            for _ in 0..<6 {
                candidates.append(searchDirectory.appendingPathComponent("threadmill-relay").path)
                let parentDirectory = searchDirectory.deletingLastPathComponent()
                if parentDirectory.path == searchDirectory.path {
                    break
                }
                searchDirectory = parentDirectory
            }
        }

        candidates.append(
            URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(".build/debug/threadmill-relay")
                .path
        )

        var visited = Set<String>()
        for candidate in candidates where visited.insert(candidate).inserted {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func executableURL(for path: String, currentDirectoryPath: String) -> URL? {
        guard !path.isEmpty else {
            return nil
        }

        let executableURL: URL
        if (path as NSString).isAbsolutePath {
            executableURL = URL(fileURLWithPath: path)
        } else {
            executableURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(path)
        }

        return executableURL.standardizedFileURL
    }
}
