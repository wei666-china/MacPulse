import Foundation
import MacPulseCore
import SwiftData

@Model
final class HistoryRecord {
    var timestamp: Date
    var batteryPercent: Double
    var batteryPowerWatts: Double?
    var batteryTemperature: Double?
    var hotspotTemperature: Double?
    var systemPowerWatts: Double?
    var cpuUsagePercent: Double?

    init(point: HistoryPoint) {
        timestamp = point.timestamp
        batteryPercent = point.batteryPercent
        batteryPowerWatts = point.batteryPowerWatts
        batteryTemperature = point.batteryTemperature
        hotspotTemperature = point.hotspotTemperature
        systemPowerWatts = point.systemPowerWatts
        cpuUsagePercent = point.cpuUsagePercent
    }

    var point: HistoryPoint {
        var snapshot = MetricSnapshot()
        snapshot.timestamp = timestamp
        snapshot.battery.percentage = batteryPercent
        snapshot.battery.netPowerWatts = batteryPowerWatts
        snapshot.battery.temperatureCelsius = batteryTemperature
        snapshot.deep.hotspotTemperature = hotspotTemperature
        snapshot.deep.systemPowerWatts = systemPowerWatts
        snapshot.deep.cpuUsagePercent = cpuUsagePercent
        return HistoryPoint(snapshot: snapshot)
    }
}

/// 升级前备份的结果，供设置页如实展示。
enum UpgradeBackupState: Equatable {
    /// 本次启动新建了备份。
    case created(URL, byteCount: Int64)
    /// 之前已经备份过，未重复执行。
    case alreadyExists(URL)
    /// 原库尚不存在（全新安装），无需备份。
    case notNeeded
    /// 备份失败。不阻断启动，但要让用户看见。
    case failed(String)
}

@MainActor
final class HistoryStore {
    static let retentionDays = 7

    /// 备份完成标记。值是备份目录名，便于将来引入 v3 时换 key 再备一次。
    private static let backupDefaultsKey = "MacPulse.schemaBackup.v2"
    /// 遗留 default.store 迁移完成标记，成功后永不再尝试。
    private static let legacyMigrationDefaultsKey = "MacPulse.legacyStoreMigrated"

    private let container: ModelContainer
    private let context: ModelContext
    let storeURL: URL?
    private(set) var migratedRecordCount = 0
    private(set) var backupState: UpgradeBackupState = .notNeeded

    init(inMemory: Bool = false) throws {
        let schema = Schema([HistoryRecord.self])

        if inMemory {
            let configuration = ModelConfiguration(
                "MacPulseHistoryTests",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            container = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
            storeURL = nil
        } else {
            let directory = try Self.applicationSupportDirectory()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent("history.store")
            // 打开容器之前先做一次性备份。SwiftData 的轻量迁移会就地改写文件，
            // 一旦开始就没有回头路，所以备份必须早于 ModelContainer 构造。
            backupState = Self.makeUpgradeBackupIfNeeded(storeURL: url)
            let configuration = ModelConfiguration(
                "MacPulseHistory",
                schema: schema,
                url: url,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            container = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
            storeURL = url
        }

        context = ModelContext(container)
        context.autosaveEnabled = false
        if !inMemory {
            // 绝不能用 `try`。遗留的 default.store 是用**当前** schema 以 allowsSave:false
            // 打开的：只要 HistoryRecord 加过任何一列，那个容器就需要迁移，而只读模式下
            // 迁移无法进行，构造直接抛错。若让它冒泡出 init，DashboardModel 会把
            // historyStore 置为 nil —— 主存储明明完好，App 却彻底失去历史读写。
            // 一个早已完成的历史遗留迁移，没有资格拖垮主存储。
            migratedRecordCount = (try? migrateLegacyStore(schema: schema)) ?? 0
        }
    }

    func loadRecent(days: Int = retentionDays) throws -> [HistoryPoint] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let descriptor = FetchDescriptor<HistoryRecord>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return try context.fetch(descriptor).map(\.point)
    }

    func save(_ point: HistoryPoint) throws {
        context.insert(HistoryRecord(point: point))
        try context.save()
    }

    func prune(days: Int = retentionDays) throws {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let descriptor = FetchDescriptor<HistoryRecord>(
            predicate: #Predicate { $0.timestamp < cutoff }
        )
        let expired = try context.fetch(descriptor)
        expired.forEach(context.delete)
        if !expired.isEmpty {
            try context.save()
        }
    }

    private func migrateLegacyStore(schema: Schema) throws -> Int {
        // 迁移是一次性的。成功跑过一次就再也不碰 default.store —— 它每多打开一次，
        // 就多一次因 schema 演进而抛错的机会，而它已经没有任何东西可以贡献了。
        guard !UserDefaults.standard.bool(forKey: Self.legacyMigrationDefaultsKey) else {
            return 0
        }

        let legacyURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("default.store")

        guard
            legacyURL.standardizedFileURL != storeURL?.standardizedFileURL,
            FileManager.default.fileExists(atPath: legacyURL.path)
        else {
            UserDefaults.standard.set(true, forKey: Self.legacyMigrationDefaultsKey)
            return 0
        }

        let legacyConfiguration = ModelConfiguration(
            "MacPulseLegacyHistory",
            schema: schema,
            url: legacyURL,
            allowsSave: false,
            cloudKitDatabase: .none
        )
        let legacyContainer = try ModelContainer(
            for: schema,
            configurations: [legacyConfiguration]
        )
        let legacyContext = ModelContext(legacyContainer)
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        let recentDescriptor = FetchDescriptor<HistoryRecord>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let legacyRecords = try legacyContext.fetch(recentDescriptor)
        guard !legacyRecords.isEmpty else {
            // 空结果也算完成。审计时发现这条路径没设标记，导致每次启动都
            // 重新打开 default.store——今天无害，但那正是「schema 一变就
            // 全盘皆输」那颗地雷的引信，必须掐灭。
            UserDefaults.standard.set(true, forKey: Self.legacyMigrationDefaultsKey)
            return 0
        }

        let currentRecords = try context.fetch(FetchDescriptor<HistoryRecord>(
            predicate: #Predicate { $0.timestamp >= cutoff }
        ))
        var existingTimestamps = Set(currentRecords.map {
            Int64(($0.timestamp.timeIntervalSince1970 * 1_000).rounded())
        })
        var inserted = 0

        for record in legacyRecords {
            let key = Int64((record.timestamp.timeIntervalSince1970 * 1_000).rounded())
            guard existingTimestamps.insert(key).inserted else { continue }
            context.insert(HistoryRecord(point: record.point))
            inserted += 1
        }

        if inserted > 0 {
            try context.save()
        }
        UserDefaults.standard.set(true, forKey: Self.legacyMigrationDefaultsKey)
        return inserted
    }

    /// 在首次以新 schema 打开主库之前，把 store 及其伴随文件整组拷出来。
    ///
    /// 必须三个文件一起拷。SQLite 的 WAL 里可能压着尚未 checkpoint 的事务
    /// （实测 history.store-wal 有 486KB），只拷主文件等于拷了个残缺副本，
    /// 真要回滚时才发现少了最近若干小时的数据。
    private static func makeUpgradeBackupIfNeeded(storeURL: URL) -> UpgradeBackupState {
        let manager = FileManager.default
        guard manager.fileExists(atPath: storeURL.path) else { return .notNeeded }

        let destination = storeURL.deletingLastPathComponent()
            .appendingPathComponent("history.store.v1backup", isDirectory: true)

        if UserDefaults.standard.bool(forKey: backupDefaultsKey),
           manager.fileExists(atPath: destination.path) {
            return .alreadyExists(destination)
        }

        let companions = ["", "-wal", "-shm"].map {
            storeURL.deletingLastPathComponent()
                .appendingPathComponent(storeURL.lastPathComponent + $0)
        }

        do {
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)

            var copied: Int64 = 0
            for source in companions where manager.fileExists(atPath: source.path) {
                let target = destination.appendingPathComponent(source.lastPathComponent)
                try manager.copyItem(at: source, to: target)
                let size = try manager.attributesOfItem(atPath: target.path)[.size] as? Int64
                copied += size ?? 0
            }

            UserDefaults.standard.set(true, forKey: backupDefaultsKey)
            return .created(destination, byteCount: copied)
        } catch {
            // 备份失败不阻断启动，但绝不静默：设置页会显示这条原因。
            return .failed(error.localizedDescription)
        }
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
