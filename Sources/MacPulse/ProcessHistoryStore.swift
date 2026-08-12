import Foundation
import MacPulseCore
import SwiftData

@Model
final class ProcessHistoryRecord {
    @Attribute(.unique) var recordKey: String
    var timestamp: Date
    var stableIdentifier: String
    var displayName: String
    var bundleIdentifier: String?
    var cpuAveragePercent: Double?
    var cpuPeakPercent: Double?
    var physicalFootprintAverageBytes: Int64?
    var physicalFootprintPeakBytes: Int64?
    var diskReadBytesPerSecond: Double?
    var diskWriteBytesPerSecond: Double?
    var energyNanojoulesPerSecond: Double?
    var compositeScore: Double
    var isMacPulse: Bool

    init(point: ProcessHistoryPoint) {
        recordKey = Self.key(
            timestamp: point.timestamp,
            stableIdentifier: point.stableIdentifier
        )
        timestamp = point.timestamp
        stableIdentifier = point.stableIdentifier
        displayName = point.displayName
        bundleIdentifier = point.bundleIdentifier
        cpuAveragePercent = point.cpuAveragePercent
        cpuPeakPercent = point.cpuPeakPercent
        physicalFootprintAverageBytes = point.physicalFootprintAverageBytes.map(Int64.init)
        physicalFootprintPeakBytes = point.physicalFootprintPeakBytes.map(Int64.init)
        diskReadBytesPerSecond = point.diskReadBytesPerSecond
        diskWriteBytesPerSecond = point.diskWriteBytesPerSecond
        energyNanojoulesPerSecond = point.energyNanojoulesPerSecond
        compositeScore = point.compositeScore
        isMacPulse = point.isMacPulse
    }

    var point: ProcessHistoryPoint {
        ProcessHistoryPoint(
            timestamp: timestamp,
            stableIdentifier: stableIdentifier,
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            cpuAveragePercent: cpuAveragePercent,
            cpuPeakPercent: cpuPeakPercent,
            physicalFootprintAverageBytes: physicalFootprintAverageBytes.flatMap {
                $0 >= 0 ? UInt64($0) : nil
            },
            physicalFootprintPeakBytes: physicalFootprintPeakBytes.flatMap {
                $0 >= 0 ? UInt64($0) : nil
            },
            diskReadBytesPerSecond: diskReadBytesPerSecond,
            diskWriteBytesPerSecond: diskWriteBytesPerSecond,
            energyNanojoulesPerSecond: energyNanojoulesPerSecond,
            compositeScore: compositeScore,
            isMacPulse: isMacPulse
        )
    }

    private static func key(timestamp: Date, stableIdentifier: String) -> String {
        "\(Int64(timestamp.timeIntervalSince1970)):\(stableIdentifier)"
    }
}

@MainActor
final class ProcessHistoryStore {
    static let retentionDays = 7

    private let container: ModelContainer
    private let context: ModelContext
    let storeURL: URL?

    init(inMemory: Bool = false) throws {
        let schema = Schema([ProcessHistoryRecord.self])
        if inMemory {
            let configuration = ModelConfiguration(
                "MacPulseProcessHistoryTests",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            container = try ModelContainer(for: schema, configurations: [configuration])
            storeURL = nil
        } else {
            let directory = try Self.applicationSupportDirectory()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent("process-history.store")
            let configuration = ModelConfiguration(
                "MacPulseProcessHistory",
                schema: schema,
                url: url,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            container = try ModelContainer(for: schema, configurations: [configuration])
            storeURL = url
        }
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func save(_ points: [ProcessHistoryPoint]) throws {
        guard !points.isEmpty else { return }
        for point in points {
            context.insert(ProcessHistoryRecord(point: point))
        }
        try context.save()
    }

    func loadRecent(
        stableIdentifier: String,
        days: Int = retentionDays
    ) throws -> [ProcessHistoryPoint] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let identifier = stableIdentifier
        let descriptor = FetchDescriptor<ProcessHistoryRecord>(
            predicate: #Predicate {
                $0.timestamp >= cutoff && $0.stableIdentifier == identifier
            },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return try context.fetch(descriptor).map(\.point)
    }

    func prune(days: Int = retentionDays) throws {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let descriptor = FetchDescriptor<ProcessHistoryRecord>(
            predicate: #Predicate { $0.timestamp < cutoff }
        )
        let expired = try context.fetch(descriptor)
        expired.forEach(context.delete)
        if !expired.isEmpty {
            try context.save()
        }
    }

    func recordCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<ProcessHistoryRecord>())
    }

    private static func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("MacPulse", isDirectory: true)
    }
}
