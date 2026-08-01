# Swift 6 / Sendable 适配现状

审计日期: 2026-04-29 · 复核日期: 2026-07-31 · **迁移进行中,进度见下节**
范围: iOS / macOS / tvOS app + AngelLiveCore + AngelLiveDependencies + SharedAssets
工作区 .swift 文件数: 268(排除 SPM `.build` 产物)

整体进度估算: **70-75%**。基础设施已切到"渐进路径"档位,核心数据模型 Sendable 化基本完成,服务层 actor 化方向正确,剩余欠账集中在插件子系统和弹幕引擎。

---

# 迁移进度(2026-08-01)

分支 `swift6-migration`。**目标是 Swift 6 语言模式**;工具链实测 Swift 6.4 / Xcode 27.0,
包里的 `swift-tools-version: 6.2` 只是最低工具版本,与语言模式无关,不需要改。

## 并发警告(命令行 `SWIFT_STRICT_CONCURRENCY=complete`,已排除 KSPlayer)

| | 基线 | 当前 | 剩余分布 |
|---|---:|---:|---|
| iOS | 82 | **3** | 全部为 `DanmakuAsyncLayer` |
| macOS | 88 | **16** | app 层 13 + `DanmakuAsyncLayer` 3 |
| tvOS | 275 | **44** | `QRCodeViewModel` 16、`RoomInfoViewModel` 13、其余零散 |

`AngelLiveCore` 单独测量:**76 → 3**(只剩 `DanmakuAsyncLayer`)。
三端均 `BUILD SUCCEEDED`、零错误,77 个单测全过。

> **测量注意**:增量构建不会为未改动文件重新输出警告,中途数字会虚低。
> 只有 `swift package clean` 后的全量构建可比。本表均为全量数据。

## 已完成

| 提交 | 内容 |
|---|---|
| `eb80670` | `NetworkRequestDetail` / `NetworkResponseDetail` 标 Sendable(`parameters` 改字符串化快照);`HostWebSocketRegistry` 改 `OSAllocatedUnfairLock`;`NativeStreamProvider` 标 Sendable;`Sentinel` 摘 `@unchecked` |
| `3b4d855` | `WebSocketConnection` / `HTTPPollingDanmakuConnection` 及 delegate 协议收口 `@MainActor`;`PluginJSDanmakuDriver`、`LiveCategoryModel` 标 Sendable;`isolated deinit` |
| `30a0b41` | JSRuntime `requestHeaders` 快照、native stream 提前序列化 |
| `cdaf308` | `StreamBookmarkService` CloudKit I/O 改 static;`onRemoteChange` 标 `@MainActor`;`FavoriteStateModel` 快照 + Sendable 进度闭包;`LiveState` 标 Sendable;JSRuntime payload 转移盒 |
| `023e462` | 合并 tvOS `Third/DanmakuKit` 副本到共享引擎;tvOS 主 target 补 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` |

## 未完成

- `DanmakuAsyncLayer` 3 条(`sending self`,`CALayer` 上游仍 main-actor-only)
- `GifAnimator` 的 `@unchecked`(拟标 `@MainActor`)
- **`DanmakuGraphicsContextStack` 疑似真实并发 bug** —— 详见 `DanmakuRenderingRoadmap.md`,应按 bug 单独修
- 各端 app 层:macOS 13、tvOS 44
- Phase 5 翻开关:`AngelLiveCore` 摘 `.swiftLanguageMode(.v5)`、三端 `SWIFT_VERSION` → 6.0

## 逃生舱账目

`@unchecked Sendable` 总数仍为 **27**,但构成变了:摘掉 `Sentinel`(本就多余),
新增 `JSRuntime.PluginPayloadTransferBox`。**净持平。**

新增的这一个是本次迁移唯一的逃生舱:文件私有、类型文档写明了为何不用 `sending`、
为何不用 JSON 往返、安全依据(Dictionary 值语义 + payload 契约),并标注禁止外移。

**全程未使用 `nonisolated(unsafe)`** —— 目标是减少逃生舱,不是换个马甲。

## 两条已证伪的路(勿重走)

1. **给 `payload` 标 `sending`** —— 该修饰符沿调用链向上传播,
   `LiveParsePluginManager.call` / `callDecodable`、`PluginJSDanmakuDriver.call`、
   `LiveParsePluginUpdater`、`LiveParseJSPlatformManager` 逐个被要求标注,
   公开 API 被污染,警告总数不降反升(13 → 16),且 JSRuntime 内的闭包捕获始终未清。
2. **给 `withTaskGroup` 的 body 标 `@Sendable`** —— 它随即无法捕获
   `platformStats` / `fetchedModels` 等可变局部变量,1 条变 14 条。
   正解是固化不可变快照 + 把 actor 状态回写抽成独立的 `@Sendable` 闭包。

## 流程教训

`3b4d855` 只验证 iOS 就提交,把 tvOS 编译打破了,直到后续阶段才暴露
(tvOS 主 target 当时没有 `SWIFT_DEFAULT_ACTOR_ISOLATION`,其 ViewModel 为 nonisolated,
无法访问刚标成 `@MainActor` 的连接类)。

**`AngelLiveCore` 是三端共享包,任何改动其隔离模型的提交都必须三端都构建过再提交。**

## 真机验收挂起(未验证前不应视为完成)

1. **弹幕连接层**:四处 `MainActor.assumeIsolated` 的线程前提(判断错会 trap 而非警告)、
   删除手工主线程收口后的重入行为、`isolated deinit` 的拆除。
   场景:弹幕连通、断线重连、快速切房间、WebSocket 与轮询型平台各一。
2. **收藏 / 书签同步**:CloudKit I/O 改 static、`onRemoteChange` 改 `@MainActor`
   (历史问题路径)、刷新进度是否仍逐条更新。场景:两台设备互相增删。
3. **tvOS 弹幕观感**:合并后选轨是否仍顶部优先、切字号时在飞弹幕行为
   (共享版与旧副本此处行为不同)、GIF 弹幕、`MAX_FLOAT_X` 改动。

---

> ## ⚠️ 2026-07-31 复核:欠账在扩大,P0 未执行
>
> **`@unchecked Sendable` 从 15 处增至 27 处(+12)。** 增量几乎全部来自审计后新写的代码,而非旧账恶化:
>
> | 来源 | 新增 | 说明 |
> |---|---:|---|
> | DLNA 投屏(新功能) | 6 | `DLNAService` ×2、`DLNAMediaProxy` ×3、`SSDPDiscoverer` ×1 |
> | DLNA 测试桩 | 2 | `DLNATests` 内 stub/recorder,风险可忽略 |
> | 收藏同步 | 1 | `FavoriteSyncEngine` |
> | 插件子系统 | 1 | `PluginSourceManager.ConsoleEntryIdBox` |
> | 其他桥接 | 2 | `KSPlayerConsoleBridge`、`HostWebSocketSession` |
>
> **这说明 P0 一直没做的实际代价**:没有 strict concurrency 基线,新功能默认沿用 `@unchecked` 逃生舱,欠账随功能线性增长。DLNA 这一个功能就贡献了 6 处——若基线在位,其中网络层几处本可以直接写成 `actor`。
>
> **P0 的优先级应上调**:它不再只是"看一眼基线",而是**止血**。
>
> 其余结论(actor 用对了位置、数据模型已 Sendable、`@preconcurrency` 克制、DanmakuKit 与 `PlayerOptions` 应保留 `@unchecked`)复核后仍然成立。`SWIFT_VERSION` 三端仍以 5.0 为主(tvOS 部分子目标已 6.0)。

---

## Build Settings 现状

| Target | SWIFT_VERSION | Default Actor Isolation | Approachable | Strict Concurrency |
|---|---|---|---|---|
| iOS app | 5.0 | MainActor ✅ | YES ✅ | (Xcode 默认,未显式 complete) |
| macOS app | 5.0 | MainActor ✅ | YES ✅ | (同上) |
| tvOS app | 5.0 + 部分 6.0 混合 | (未设) | 部分 YES | 部分 |
| AngelLiveCore (SPM) | tools 6.2 + `swiftLanguageMode(.v5)` | nonisolated | n/a | n/a |
| AngelLiveDependencies (SPM) | tools 6.2 | n/a | n/a | n/a |

**含义**:
- 三个 app target 都开了 **MainActor by default + Approachable Concurrency**(Xcode 16/26 推荐路径)
- `SWIFT_VERSION` 仍在 5.0,`SWIFT_STRICT_CONCURRENCY` 没显式设 `complete`
  → Sendable 违规目前是**警告级**,不是编译错误,留有缓冲
- AngelLiveCore 用 swift-tools 6.2,但 `swiftLanguageMode(.v5)` 显式压回 Swift 5 模式

---

## 量化指标(workspace,排除 .build)

| 指标 | 计数 |
|---|---|
| `: Sendable` 显式声明 | 85 |
| `@unchecked Sendable`(逃生舱) | ~~15~~ → **27**(2026-07-31 复核) |
| `@preconcurrency` | 7 |
| `@MainActor` | 165 |
| `nonisolated` | 44 |
| `actor` 类型 | 6 |
| `@Observable` / `ObservableObject` | 35 / 8 |
| `Task {}` / `async func` | 217 / 157 |
| `DispatchQueue` | 79 |
| 锁(NSLock / os_unfair_lock / NSRecursiveLock / OSAllocatedUnfairLock) | 8 |

按模块的 Sendable 声明分布:
- AngelLiveCore: 76
- AngelLiveDependencies: 7
- iOS app: 1
- macOS app: 0
- TV: 1

---

## `@unchecked Sendable` 全部 27 处清单(2026-07-31 复核)

行号为复核时实际值,与 4 月审计有偏移。**🆕** 标记 4 月之后新增。

### 插件 / JS 子系统(8 处) — `AngelLiveCore`
- `LiveParse/Plugin/JSRuntime.swift:4` — `public final class JSRuntime: @unchecked Sendable`(JSContext 包装,串行 DispatchQueue 同步)
- `LiveParse/Plugin/LiveParsePluginManager.swift:3`
- `LiveParse/Plugin/LiveParsePluginUpdater.swift:44`
- `Services/PluginSourceManager.swift:38` — `RemotePluginDisplayItem`
- `Services/PluginSourceManager.swift:51` — `PluginSourceManager`
- `Services/PluginSourceManager.swift:748` — 内嵌 `ConsoleEntryIdBox` **🆕**
- `Services/PluginConsoleService.swift:85` — `PluginConsoleService`
- `Services/PluginAvailabilityService.swift:14` — `PluginAvailabilityService`

### DLNA 投屏(6 处) **🆕 全部为新增** — `AngelLiveDependencies`
审计后新写的功能,是本次增量的主要来源。网络层若在 strict concurrency 基线下开发,多数可直接写成 `actor`。

- `DLNA/SSDPDiscoverer.swift:11` — `SSDPDiscoverer`(GCDAsyncUdpSocketDelegate 桥接)
- `DLNA/DLNAService.swift:4` — `DLNAService`
- `DLNA/DLNAService.swift:104` — `DLNAAVTransportClient`
- `DLNA/DLNAMediaProxy.swift:135` — `DLNAMediaProxyStore`
- `DLNA/DLNAMediaProxy.swift:195` — `DLNAMediaProxyHTTPHandler`(NIO ChannelInboundHandler)
- `DLNA/DLNAMediaProxy.swift:278` — `DLNAProxyUpstreamRequest`(URLSessionDataDelegate)

### 弹幕引擎(4 处) — `AngelLiveCore/DanmakuKit`(UIKit / CoreAnimation 强耦合)
- `Core/DanmakuAsyncLayer.swift:31` — `DanmakuAsyncLayer: CALayer`
- `Core/DanmakuAsyncLayer.swift:17` — `Sentinel`
- `Core/DanmakuPlatform.swift:145` — `DanmakuGraphicsContextStack`
- `Gif/GifAnimator.swift:15` — `GifAnimator`

### 测试桩(2 处) **🆕** — 风险可忽略,不计入迁移目标
- `AngelLiveCoreTests/DLNATests.swift:165` — `StubSSDPDiscoverer`
- `AngelLiveCoreTests/DLNATests.swift:179` — `RequestRecorder`

### 其他(7 处)
- `Services/Sync/FavoriteSyncEngine.swift:22` — `FavoriteSyncEngine` **🆕**
- `Models/PlatformCapability.swift:81` — 内嵌 `Cache`
- `Services/PlatformCredentialSyncService.swift:671` — 内嵌 `SendState`
- `AngelLiveDependencies/Sources/PlayerOptions.swift:4` — `PlayerOptions: KSOptions`(受 KSPlayer 上游限制)
- `AngelLiveDependencies/.../KSPlayerConsoleBridge.swift:15` — `KSPlayerConsoleBridge: LogHandler` **🆕**
- `.../HostWebSocketBridge.swift:8` — `HostWebSocketSession` **🆕**
- `TV/.../RoomInfoViewModel.swift:22` — 内嵌 `LiveFlagTimerHandle`

---

## `@preconcurrency` 7 处

均为合理的边界库桥接,无需消除:
- `LiveParse/Danmu/HTTPPollingDanmakuConnection.swift:2` — `@preconcurrency import Alamofire`
- `LiveParse/Plugin/JSRuntime.swift:2` — `@preconcurrency import JavaScriptCore`
- `DanmakuKit/Core/DanmakuTrack.swift:68` / `:259` — `CAAnimationDelegate` 一致性
- `AngelLiveDependencies/Sources/KSPlayerFallback.swift:13` / `:16` — `@preconcurrency import UIKit / AppKit`
- `TV/.../QRCodeViewModel.swift:170` — `@preconcurrency actor QRCodeActor: SyncManagerDelegate`

---

## 已经做对的部分

- **6 个原生 actor 用在了对的位置**(网络/缓存/会话/插件):
  - `FavoriteStateModel`
  - `LiveParseLoadedPlugin`
  - `PlatformSessionManager`
  - `PluginSourceKeyService`
  - `PlatformLoginRegistry`
  - `RemoteAvatarDataLoader`(macOS)

- **核心数据模型 Sendable 化完成**:
  - `LiveModel`、`LiveParseDanmakuPlan`、Plugin manifest、`RoomPlaybackResolver`、`PlatformSessionManager` 都明确标注

- **VM 层基本迁完**: `@Observable` 35 vs `ObservableObject` 8,大头是新观察体系

- **`@preconcurrency` 用得克制**: 仅 7 处,且都是合理的边界库

## 评分

| 维度 | 分数 | 说明 |
|---|---|---|
| 基础设施(build settings) | 7/10 | MainActor 默认 + Approachable 已开,SWIFT_VERSION 还是 5.0 |
| 数据模型 Sendable | 8/10 | 核心 model 都标了 |
| 服务层 actor 化 | 7/10 | 设计现代 |
| 服务层 Sendable | 5/10 | 5 个插件相关 service 还在 `@unchecked` |
| 弹幕引擎 | 4/10 | UIKit 桥接,改造代价大,4 处 `@unchecked` |
| VM 层 | 8/10 | 已迁到 `@Observable` |

---

## 收尾路径(按 ROI 排序)

### P0 — 几乎零风险,立即可做(**2026-07-31 复核后优先级上调**)

**显式开启 strict concurrency 看 baseline**

把 iOS / macOS app target 的 `SWIFT_STRICT_CONCURRENCY = complete` 打开。在 SWIFT_VERSION = 5.0 下这只是警告,不会破坏构建。先看一眼警告基线在哪里。

> **复核后这一项从「摸底」变成「止血」。** 四月至今新增 12 处 `@unchecked Sendable`,其中 DLNA 一个功能占 6 处——因为没有基线,新代码默认走逃生舱最省事。基线开着的话,这些在写的时候就会被警告推向 `actor`。
>
> 每晚一天,后面要迁移的量就多一点。**建议在下一个新功能动工前先做掉。**

### P1 — 逐步推进

**1. 插件子系统 6 个 `@unchecked` → actor 化**

`JSRuntime` 已经用串行 DispatchQueue 做内部同步,本质上就是手写 actor。直接平移:
- `actor JSRuntime` 替代 `final class JSRuntime: @unchecked Sendable`
- `queue.sync { ... }` → 改为 actor 内方法,调用点 `await`
- JSContext 仍需在固定线程运行 → 用 `@globalActor` 或 `DispatchSerialExecutor` 桥接

其他 5 个 plugin manager(`LiveParsePluginManager`、`LiveParsePluginUpdater`、`PluginSourceManager`、`PluginConsoleService`、`PluginAvailabilityService`)类似处理。

**2. 三个内嵌类**

`PlatformCapability.Cache` / `PlatformCredentialSyncService.SendState` / `LiveFlagTimerHandle` 都是小作用域,改成 `actor` 或并入父 actor 即可。

### P2 — 大工程,留到最后

**3. DanmakuKit 4 处** 涉及 `CALayer` / `CoreAnimation` 子类,受限于 Apple 框架自身的 Sendable 状态(`CALayer` 仍是 main actor only)。**保留 `@unchecked Sendable` + 加文档说明**比强行改造更务实,直到 Apple 上游推进。

**4. `PlayerOptions: KSOptions`** 受限于 KSPlayer 上游,等上游标 Sendable。

### P3 — 终态

P0-P2 走完后:
- `SWIFT_VERSION` 切到 6.0
- `AngelLiveCore` 的 `swiftLanguageMode(.v5)` 摘掉
- `RemotePluginDisplayItem` 这种 UI 引用类型可考虑改为 `@MainActor` 而非 `@unchecked Sendable`

---

## 备注

- `DispatchQueue` 79 处、锁 8 处:迁移 actor 时优先消化,但不强求全清(底层桥接仍合理)
- `@MainActor` 165 处:多数是非 UI 类的 actor 跳板,而不是修复战
- TV target 部分子目标已经在 SWIFT_VERSION = 6.0,可作为参考路径
