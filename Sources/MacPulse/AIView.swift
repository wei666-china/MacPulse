import MacPulseCore
import SwiftUI

/// 「AI」板块:订阅还剩多少、API 余额还剩多少、今天用了多少。
/// 主角是**剩余**——用量是配角(Wei 拍板的排序)。
struct AIView: View {
    @EnvironmentObject private var model: DashboardModel
    @AppStorage("claudeSubscriptionEnabled") private var claudeSubscriptionEnabled = false
    @AppStorage("grokSubscriptionEnabled") private var grokSubscriptionEnabled = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                subscriptionSection
                apiBalancesCard
                localUsageCard
                privacyFootnote
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .onAppear { model.refreshAIBalances() }
    }

    // MARK: - 订阅额度

    @ViewBuilder
    private var subscriptionSection: some View {
        if let claude = model.claudeQuota {
            quotaCard(
                title: String(localized: "Claude 订阅"),
                subtitle: String(localized: "未文档化接口·数据与 Claude Code 的 /usage 同源"),
                quota: claude
            )
        } else if !claudeSubscriptionEnabled {
            LiquidCard(padding: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.key")
                        .foregroundStyle(MacPulseTheme.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Claude 订阅额度"))
                            .font(.callout.weight(.semibold))
                        Text(String(localized: "用本机 Claude Code 的登录态查 5 小时窗与每周额度。走的是未公开接口,可能随时失效;开启才请求。"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $claudeSubscriptionEnabled)
                        .labelsHidden()
                        .onChange(of: claudeSubscriptionEnabled) { _, enabled in
                            if enabled { model.refreshAIBalances(force: true) }
                        }
                }
            }
        } else {
            // 开着但暂时没数据。三种情形分开说,并给出口——转圈不许无限期。
            LiquidCard(padding: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: model.claudeQuotaRetryDelay != nil ? "clock.badge.exclamationmark" : "hourglass")
                        .foregroundStyle(MacPulseTheme.warm)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Claude 订阅额度暂时读不到"))
                            .font(.caption.weight(.medium))
                        Text(claudeUnavailableReason)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(String(localized: "关闭")) {
                        claudeSubscriptionEnabled = false
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
        if let codex = model.codexQuota {
            quotaCard(
                title: String(localized: "Codex 订阅"),
                subtitle: codex.planType.map {
                    String(format: String(localized: "%@ 方案·读本机会话日志,零网络"), $0)
                } ?? String(localized: "读本机会话日志,零网络"),
                quota: codex
            )
        }
        grokSection
    }

    /// Grok(xAI):复用本机 Grok CLI 的登录态查每周额度。
    @ViewBuilder
    private var grokSection: some View {
        if let grok = model.grokQuota {
            quotaCard(
                title: String(localized: "Grok 订阅"),
                subtitle: String(localized: "复用本机 Grok CLI 登录态·官方计费端点"),
                quota: grok
            )
        } else if GrokQuotaReader.isAvailable, !grokSubscriptionEnabled {
            LiquidCard(padding: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.key")
                        .foregroundStyle(MacPulseTheme.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Grok 订阅额度"))
                            .font(.callout.weight(.semibold))
                        Text(String(localized: "本机装了 Grok CLI 且已登录。开启后用它的登录态查每周额度(Build 与 Chat 分开列),不碰浏览器 cookie。"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $grokSubscriptionEnabled)
                        .labelsHidden()
                        .onChange(of: grokSubscriptionEnabled) { _, on in
                            if on { model.refreshAIBalances(force: true) }
                        }
                }
            }
        }
    }

    /// 读不到的具体原因。限流是最常见的一种,而且服务端明确告诉了要等多久。
    private var claudeUnavailableReason: String {
        if let delay = model.claudeQuotaRetryDelay {
            return String(
                format: String(localized: "接口正在限流,%@ 分钟后自动重试。这个接口每小时只允许很少几次查询。"),
                String(describing: max(1, Int(delay / 60)))
            )
        }
        switch ClaudeSubscriptionReader.tokenState() {
        case .keychainDenied:
            return String(localized: "需要授权 MacPulse 读取 Claude Code 的钥匙串条目——首次刷新时系统会弹一次对话框,选「始终允许」即可长期生效。")
        case .missing:
            return String(localized: "本机没找到 Claude Code 的登录态。装好并登录 Claude Code 后即可读取。")
        case .token:
            return String(localized: "正在读取,下一轮刷新后显示。")
        }
    }

    private func quotaCard(title: String, subtitle: String, quota: SubscriptionQuota) -> some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: title, subtitle: subtitle)
                ForEach(quota.windows) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(window.label)
                                .font(.callout)
                            Spacer(minLength: 0)
                            Text(String(format: String(localized: "剩 %@%%"), String(describing: Int(window.remainingPercent))))
                                .font(.callout.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(window.remainingPercent < 15 ? MacPulseTheme.warm : .primary)
                            if let resets = window.resetsAt {
                                Text(resetText(resets))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        // 进度条画**剩余**,不画已用——满格=满额度,直觉一致。
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.primary.opacity(0.08))
                                Capsule()
                                    .fill(window.remainingPercent < 15 ? MacPulseTheme.warm : MacPulseTheme.ink)
                                    .frame(width: proxy.size.width * window.remainingPercent / 100)
                            }
                        }
                        .frame(height: 5)
                    }
                }
                Text(String(format: String(localized: "快照时间:%@"), quotaAge(quota.fetchedAt)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func resetText(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return String(localized: "即将重置") }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 48 {
            return String(format: String(localized: "%@ 天后重置"), String(describing: hours / 24))
        }
        if hours > 0 {
            return String(format: String(localized: "%@ 小时 %@ 分后重置"), String(describing: hours), String(describing: minutes))
        }
        return String(format: String(localized: "%@ 分钟后重置"), String(describing: max(1, minutes)))
    }

    private func quotaAge(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 90 { return String(localized: "刚刚") }
        if seconds < 3_600 { return String(format: String(localized: "%@ 分钟前"), String(describing: Int(seconds / 60))) }
        return String(format: String(localized: "%@ 小时前"), String(describing: Int(seconds / 3_600)))
    }

    // MARK: - API 余额

    @ViewBuilder
    private var apiBalancesCard: some View {
        if !model.aiBalances.isEmpty || !model.aiBalanceErrors.isEmpty {
            LiquidCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionHeader(
                            title: String(localized: "API 余额"),
                            subtitle: model.aiBalanceRefreshedAt.map { quotaAge($0) }
                        )
                        Spacer(minLength: 0)
                        Button {
                            model.refreshAIBalances(force: true)
                        } label: {
                            Image(systemName: "arrow.clockwise").font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                    ForEach(model.aiBalances) { reading in
                        VStack(alignment: .leading, spacing: 2) {
                            ValueRow(
                                title: reading.provider.displayName,
                                value: reading.primary,
                                symbol: "creditcard",
                                tint: MacPulseTheme.ink
                            )
                            if let detail = reading.detail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 28)
                            }
                        }
                    }
                    ForEach(Array(model.aiBalanceErrors.keys.sorted { $0.rawValue < $1.rawValue }), id: \.self) { provider in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(MacPulseTheme.warm)
                            Text("\(provider.displayName):\(model.aiBalanceErrors[provider] ?? "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else {
            LiquidCard(padding: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "creditcard")
                        .foregroundStyle(MacPulseTheme.ink)
                    Text(String(localized: "在设置页填入 DeepSeek / OpenRouter / Moonshot / 硅基流动的 API key,这里显示各家余额。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - 本地用量

    @ViewBuilder
    private var localUsageCard: some View {
        if let usage = model.claudeCodeUsage {
            LiquidCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: String(localized: "今日用量"), subtitle: String(localized: "本地日志统计,零网络"))
                    ValueRow(
                        title: "Claude Code",
                        value: String(
                            format: String(localized: "入 %@ · 出 %@"),
                            AITokenFormat.text(usage.inputTokens + usage.cacheReadTokens + usage.cacheCreationTokens),
                            AITokenFormat.text(usage.outputTokens)
                        ),
                        symbol: "terminal",
                        tint: MacPulseTheme.ink
                    )
                    Text(String(
                        format: String(localized: "%@ 个会话·「入」含缓存读写,量大属正常"),
                        String(describing: usage.sessionCount)
                    ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var privacyFootnote: some View {
        Text(String(localized: "本页原则:订阅额度优先本地数据(Codex 读日志零网络);API 余额只请求官方接口;key 只存钥匙串;一切读不到都显示读不到,不编数。"))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// token 数的人话格式,AI 页与总览卡共用。
enum AITokenFormat {
    static func text(_ count: Int) -> String {
        switch count {
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.0fK", Double(count) / 1_000)
        default: String(describing: count)
        }
    }
}
