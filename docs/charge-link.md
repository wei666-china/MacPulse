# 充电链路(Charge Link)技术方案

2026-08-12 · 分支 `feature/charge-link` · 状态:第一期实施中

## 要解决的问题

电池页现在只显示「适配器 96.0W」——只知道充电器多大,不知道**这根线行不行**、
**实际协商到了多少**。充电慢的时候,用户分不清瓶颈是充电器、线,还是 Mac 自己不想要。

第一期交付:电池页新增「充电链路」卡片,把 充电器 → 线缆 → Mac 三段各自的上限
和当前协商结果摆出来,配一句话结论(「线缆在拖慢充电」「满速协商」……)。

## 上游与许可证

判定逻辑与 PD 位解码改编自 [WhatCable](https://github.com/darrylmorley/whatcable)
(MIT,Copyright (c) 2026 Darryl Morley)。已核实:其公开仓库内无子目录级 LICENSE,
默认 MIT 全覆盖;专有的 Pro 插件代码只在作者私有仓库,未引入。我们不搬它的
SQLite 认证数据库(体积大、维护重),厂商只显示十六进制 VID。署名已加入
THIRD_PARTY_NOTICES.md(与 mactop 同格式)。

## 数据源(全部是 IORegistry 公开节点,无私有 API,无需权限)

在本机(M5 MacBook Air,macOS 26)实测三类节点齐全:

| 节点类 | 给什么 | 关键属性 |
|---|---|---|
| `AppleHPMInterfaceType10/11`(M1/M2 是 `AppleTCControllerType10/11`) | 物理口状态 | `PortTypeDescription`、`PortNumber`、`ConnectionActive` |
| `IOPortFeaturePowerSource` | 充电器广告档位 + 协商结果 | `PowerSourceName`(USB-PD/Brick ID/TypeC)、`PowerSourceOptions`(PDO 列表)、`WinningPowerSourceOption`、`ParentBuiltInPortType/Number` |
| `IOPortTransportComponentCCUSBPDSOPp` | 线缆芯片(e-marker)身份 | `Metadata.VDOs`(4 字节小端)、`Vendor ID`、`Product ID` |

实测样本(当前插着的 96W 充电器 + 联想线):协商合同 20V×4.8A=96W;
线缆 VDO 解出 被动线 / 5A / 48V 钳制后 240W / 10Gbps / EPR。已存为测试样本。

### 已知坑(全部来自 WhatCable 的实战注释,直接继承其对策)

- **拔线后 PDO 残留**:MagSafe/USB-C 控制器会缓存上一次协商结果,必须用 HPM 口的
  `ConnectionActive` 做门闸,否则拔了充电器还显示在充 96W。
- **批量读属性会崩**:服务拆除中读全字典可能在 `IOCFUnserializeBinary` 里把进程
  带崩,一律逐 key `IORegistryEntryCreateCFProperty`。
- **`PowerSourceOptions` 是 CFSet 不是数组**:ioreg 显示成 `[{…}]` 是假象,解析要同时
  接 NSSet 和 NSArray。
- **无芯片线 ≠ 读不到**:普通 USB 2.0 充电线没有 SOP' 节点是常态,PD 协议把这种线
  按 3A 封顶——这本身就是诊断信息(见下)。但 MagSafe 线不走 SOP' 应答,
  「无芯片」推断只适用于 USB-C 口。
- **系统接口未见于文档**:苹果可能随版本变更。WhatCable 社区活跃,坏了跟上游对齐;
  本方案读不到时的行为是整卡隐藏,不会显示错数据(符合本仓库「绝不编数据」铁律)。

## 分层设计(沿用三层惯例)

### MacPulseCore(纯 Foundation,已完成)

`Sources/MacPulseCore/ChargeLink.swift`:

- `PDPowerOption` — 一个功率档(mV/mA/mW)。
- `CableEmarkerInfo` — 线缆身份:被动/主动、速度档、3A/5A、额定瓦数(50V 按 PD
  实际上限 48V 钳制,5A EPR 线是 240W 不是 250W)、EPR、有无认证 XID。
- `ChargeLinkVDODecoder` — VDO 位解码(ID Header bits 29..27 判线型;Cable VDO
  bits 2..0 速度、6..5 电流、10..9 电压等级、17 EPR)。
- `ChargeLinkSnapshot` — 一次采样:供电口、广告档位、协商档、线缆、待命充电器标记。
- `ChargeLinkDiagnosis.diagnose(...)` — 判定,证据从硬到软(顺序被单测锁死,
  第一版把「疑似线缆」排太靠前,满电涓流全被误判,测试当场抓出来):
  1. 线缆额定 < 充电器(e-marker 铁证)→ **线缆瓶颈**(警告级)
  2. 电池已满 / 系统暂停 —— 协商值低的无辜解释,必须先于任何怀疑
  3. USB-C + 无芯片线 + **正在充电 + 协商电压是最高档 + 电流钉在 3A + 同档还有余量**
     四条同时成立 → **疑似线缆限速**(警告级;涓流走低电压档,不会触发)
  4. 协商 < 充电器上限−max(5W, 10%) → Mac 自限(正常)
  5. 否则 → 满速 / 充电器天花板
  电池状态两个布尔由现有 `ChargeState` 推导(`.full`、`.charging`),不改 BatteryMetrics。

### MacPulse app 层(IOKit)

`Sources/MacPulse/ChargeLinkSampler.swift`(actor,仿 BatterySampler):

- 每次 `sample()` 现场走三类节点(插拔会让服务生灭,不缓存句柄)。
- 选「当前供电源」:USB-PD > Brick ID > TypeC,优先有 winning 合同的(WhatCable 逻辑)。
- 按 (ParentBuiltInPortType, Number) 关联同口的 SOP' 线缆身份与 HPM 口状态。
- `ConnectionActive != true` 或无任何供电源 → 返回 nil(卡片隐藏)。
- 第一期不做 IONotification 即插即用推送,跟随现有 2s/10s 采样节奏;
  也不做「另一口充电器待命」判定(WhatCable 为此维护了整套机型语料,复杂度不值当,
  快照字段已预留)。

### 接线(DashboardModel)

- `@Published private(set) var chargeLink: ChargeLinkSnapshot?`
- 仿 ANE 扫描的可见性门闸:仅电池页可见时采样(「没人看的时候没有理由跑」),
  BatteryView onAppear/onDisappear 上报,页面打开瞬间先采一次,不等下个 tick。

### UI(BatteryView)

「充电与供电」卡片之后插一张 `LiquidCard`:

- 标题「充电链路」+ 口位副标题(如 USB-C 2 号口)。
- 结论行:诊断 summary(警告级带色),detail 作小字。
- 三行 ValueRow:充电器上限(含档位数)、线缆额定(速度/线型/瓦数,无芯片如实说明)、
  实际协商(V×A=W)。
- 仅外接电源时显示;快照为 nil 整卡隐藏,不编数据。

### 测试

- `Tests/MacPulseCoreTests/ChargeLinkTests.swift`:用本机抓的真实 VDO/PDO 样本
  验解码(联想 240W 线、96W 四档充电器),覆盖判定各分支与 48V 钳制、3A 推断门。
- `Tests/MacPulseAppTests/ChargeLinkSamplerTests.swift`:真机测试,遵守
  「不许自己对自己」——采样器走 IOKit API,对照组 shell 出去 `ioreg` 文本解析;
  没插电时 `XCTSkip`。

## 后续候选(本期不做)

- 即插即用(IONotification + interest 通知,WhatCable 有完整参考实现)
- 数据速度诊断 / Thunderbolt 拓扑(牵扯认证数据库与 USB 设备树关联)
- 充电器待命提示、线缆历史记录
