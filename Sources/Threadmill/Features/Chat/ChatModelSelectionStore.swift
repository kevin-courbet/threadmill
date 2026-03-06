import Foundation

enum ChatModelSelectionStore {
    static func key(threadID: String) -> String {
        "threadmill.chat.model-selection.\(threadID)"
    }

    static func selectedModel(threadID: String, userDefaults: UserDefaults = .standard) -> OCMessageModel? {
        guard let storageID = userDefaults.string(forKey: key(threadID: threadID)) else {
            return nil
        }
        return OCMessageModel(storageID: storageID)
    }
}

extension OCMessageModel {
    var storageID: String {
        "\(providerID)::\(modelID)"
    }

    init?(storageID: String) {
        guard let separatorRange = storageID.range(of: "::") else {
            return nil
        }

        let providerID = String(storageID[..<separatorRange.lowerBound])
        let modelID = String(storageID[separatorRange.upperBound...])

        guard !providerID.isEmpty, !modelID.isEmpty else {
            return nil
        }

        self.init(providerID: providerID, modelID: modelID)
    }
}
