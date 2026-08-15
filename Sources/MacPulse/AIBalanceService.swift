import Foundation
import MacPulseCore
import Security

/// API key 的唯一存放处:macOS 钥匙串。
/// 不进 UserDefaults、不进任何文件、不进体检报告——key 是钱,按钱对待。
enum AIKeyStore {
    private static let service = "com.local.MacPulse.aikeys"

    static func save(_ key: String, for provider: AIProvider) {
        delete(for: provider)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(for provider: AIProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for provider: AIProvider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static var configuredProviders: [AIProvider] {
        AIProvider.allCases.filter { load(for: $0) != nil }
    }
}

/// 余额取数。每家一个 GET + Bearer,10 秒超时;
/// 失败给人话错误,不给假数字。
actor AIBalanceService {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "MacPulse"]
        session = URLSession(configuration: config)
    }

    func fetch(provider: AIProvider, key: String) async -> Result<AIBalanceReading, AIBalanceFetchError> {
        var request = URLRequest(url: provider.balanceURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                do {
                    return .success(try AIBalanceParser.parse(provider: provider, data: data, now: .now))
                } catch {
                    return .failure(.unexpectedResponse)
                }
            case 401, 403:
                return .failure(.invalidKey)
            default:
                return .failure(.httpStatus(status))
            }
        } catch {
            return .failure(.network)
        }
    }
}

enum AIBalanceFetchError: Error, Equatable {
    case invalidKey
    case network
    case unexpectedResponse
    case httpStatus(Int)

    var message: String {
        switch self {
        case .invalidKey: String(localized: "key 无效或已过期")
        case .network: String(localized: "网络不可达")
        case .unexpectedResponse: String(localized: "响应格式变了,等更新适配")
        case .httpStatus(let code): String(format: String(localized: "服务端返回 %@"), String(describing: code))
        }
    }
}

/// Claude Code 本地用量:扫 ~/.claude/projects/**/*.jsonl。
/// 零网络零配置;只挑今天动过的文件,逐行流式解析,不整读大文件。
enum ClaudeCodeUsageReader {

    static func todayUsage(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")) -> ClaudeCodeUsage? {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: .now)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var usage = ClaudeCodeUsage()
        var seen = Set<String>()
        var sessions = 0
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
                modified >= startOfDay
            else { continue }
            var counted = false
            guard let reader = StreamingLineReader(url: url) else { continue }
            while let line = reader.nextLine() {
                let before = usage
                ClaudeCodeUsageParser.accumulate(
                    line: line, since: startOfDay,
                    seenMessageIDs: &seen, into: &usage
                )
                if usage != before { counted = true }
            }
            if counted { sessions += 1 }
        }
        usage.sessionCount = sessions
        return usage.isEmpty ? nil : usage
    }
}

/// 简单的按行流式读取。会话日志能有几十 MB,整读进内存不体面。
final class StreamingLineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var finished = false
    private let chunkSize = 1 << 16

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle
    }

    deinit { try? handle.close() }

    func nextLine() -> String? {
        while true {
            if let range = buffer.firstRange(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(data: lineData, encoding: .utf8) ?? ""
            }
            if finished {
                guard !buffer.isEmpty else { return nil }
                let rest = String(data: buffer, encoding: .utf8)
                buffer.removeAll()
                return rest
            }
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
            if let chunk, !chunk.isEmpty {
                buffer.append(chunk)
            } else {
                finished = true
            }
        }
    }
}
