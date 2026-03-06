import Foundation

struct SystemStatsResult: Codable, Equatable {
    let loadAvg1m: Double
    let memoryTotalMb: UInt32
    let memoryUsedMb: UInt32
    let opencodeInstances: UInt32
    
    enum CodingKeys: String, CodingKey {
        case loadAvg1m = "load_avg_1m"
        case memoryTotalMb = "memory_total_mb"
        case memoryUsedMb = "memory_used_mb"
        case opencodeInstances = "opencode_instances"
    }
}

struct SystemCleanupResult: Codable {
    let cleaned: Bool
    let message: String
}
