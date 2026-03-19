import Foundation
import SwiftUI

enum DebugArtifacts {
    static let directory = URL(fileURLWithPath: "/tmp/threadmill-debug", isDirectory: true)

    static func write<T: Encodable>(_ value: T, named name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(value) else {
            return
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
    }
}

struct DebugSnapshotWriter<Value: Encodable & Equatable>: View {
    let name: String
    let value: Value

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: value) {
                DebugArtifacts.write(value, named: name)
            }
    }
}
