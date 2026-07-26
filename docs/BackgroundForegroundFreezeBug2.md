# Bug2 修复文档:iOS 直播播放中「后台→前台」概率卡死

> 状态:待运行时证据确认 · 2026-06-21
> 平台:iOS(iPhone,KSPlayer 内核,Metal 渲染)
> 现象:横屏/竖屏播放中按 Home 进后台,再返回前台,**有概率**画面定格;此时点「重新加载」新画面仍卡,只有**退出直播间重进**才能恢复。
> 2026-07-14 更新:F5 已在 KSPlayer Phase 3 修复，Room 会话恢复真实 `isLive`；其余后台/前台与 Metal 假设仍需真机验证。

---

## 0. 重要前提:先抓现场,别靠读代码定论

参考 Axiom `axiom-graphics` 技能结论:**Metal 渲染层卡死类问题必须用运行时证据定位(GPU Frame Capture / `currentDrawable` 是否为 nil),靠读代码猜「猜要 1–4 小时,抓现场 5–10 分钟」。**

本文已确认的部分是「代码事实」(带 `file:line`),候选根因是「待证据区分的假设」。**动手修之前必须先用 §3 的观察矩阵把方向锁死**,否则可能修错层。

---

## 1. 代码层已确认的事实(非推测)

| # | 事实 | 位置 |
|---|------|------|
| F1 | 进后台且 `canBackgroundPlay=false`(默认)时,KSPlayer 内核必定 `pause()` | `KSPlayer/AVPlayer/KSPlayerLayer.swift:921-939` |
| F2 | 回前台(非画中画)只调 `player.enterForeground()`,**只恢复 Metal 渲染定时器,不调用 `play()`** | `KSPlayerLayer.swift:941-967` / `MEPlayer/MetalPlayView.swift:257` |
| F3 | App 自己的 `didBecomeActive` 处理**只关画中画**,不重连/不踢播放 | `PlayerContainerView.swift:150-164` |
| F4 | `MetalPlayView.enterBackground` 在 `!isPaused` 时会按 fps 在后台继续 `draw`;但 F1 的 `pause()` 已把 `isPaused` 置真,故正常不会在后台跑 GPU | `MetalPlayView.swift:248-255` |
| F5 | **已解决:** KSPlayer 先同步停止旧 decode operation 再关闭 context，三端 Room 使用真实 `isLive`，允许内核重连直播边缘 | `KSPlayer/MEPlayerItem.swift` / `MEPlayerItemTrack.swift` |
| F6 | 恢复协调器采样对 **KSAVPlayer(HLS 流)直接返回 nil** → 这类流**没有零吞吐 stall 检测** | `PlaybackRecoveryAdapter.swift:98-112` |
| F7 | 手动 reload / 恢复动作都走 `changePlayUrl`,复用全局 `@StateObject playerCoordinator`(`.id("stable_player")` 永不重建);URL 变化时 `KSPlayerLayer.set(url:)` 只 `player.replace(url:)`,**复用同一个 player 实例**;只有退房间才会重建 coordinator | `DetailPlayerView.swift:22` / `KSPlayerLayer.swift:199-224` |
| F8 | `assignCurrentPlayURL`:URL 相同走 `nil→url` 真重建;URL 变化只换地址,**跳过重建** | `RoomInfoViewModel.swift:342-362` |
| F9 | 手动 reload 调 `episodeChanged(streamKey: roomId)`,同房间 early-return,**不会重新武装已熔断的监控** | `PlaybackRecoveryCoordinator.swift:196-208` |

由 F1+F2+F3 可知:回前台后内核停在「暂停 + 仅恢复渲染」状态,App 这层没有任何主动恢复动作。这是后续所有候选根因的共同土壤。

---

## 2. 候选根因(待证据区分)

### A. 渲染/Drawable 失效(Metal 层)
后台→前台过程中 `CAMetalLayer` 的 drawable 失效或渲染管线被打断,回前台 `nextDrawable` 拿不到/管线未恢复 → **声音在播,画面定格在最后一帧**。属图形层,需 GPU Frame Capture 确认。

### B. 直播管线陈旧(解复用/网络)
后台期间直播连接被服务器掐断或直播边缘漂移过远;回前台 demuxer 想从旧位置续读但数据已不存在。KSPlayer 现可安全重连，但仍需真机确认后台挂起/恢复时是否一定触发该路径。

### C. 暂停未被恢复(纯生命周期)
F2 表明前台不自动 `play()`。若没有别处补 `play()`,就停在暂停态 → **画面是「暂停的最后一帧」,手动点播放可能能恢复(或恢复后再走 B)**。

> 三者都被 F6/F7/F8/F9 放大成「救不回」:HLS 无 stall 采样(F6)、reload 复用死实例(F7/F8)、熔断后不再武装(F9)。这解释了「reload 无效、只能退房间」。

---

## 3. 观察矩阵:复现时按这几条定方向

| 卡死时观察 | 指向 | 含义 |
|---|---|---|
| 声音继续 + 画面定格 + 左上角网速 HUD 还在跳 | **A** | 管线活着,卡在渲染/drawable |
| 声音停 + 网速归零/不动 | **B** | 管线整体死(网络/解复用) |
| 声音停 + 手动点播放能恢复 | **C** | 仅暂停未恢复 |
| 看日志 `[PlayerFlow] KS state changed ->` 最终停在 `.paused` | 倾向 **C** | 内核停在暂停 |
| 停在 `.buffering` 且不前进 | 倾向 **B** | 在等永远不来的包 |
| 停在 `.bufferFinished`/`.readyToPlay` 但画面不动 | 倾向 **A** | 状态在播但没出帧 |

复现步骤:真机连 Xcode,Console 过滤 `[PlayerFlow]`,播放→进后台停 30s+→回前台,记录上表 + 进/出后台与回前台各打印了什么;再点重新加载,看 state 走到哪。A 类再补一次 GPU Frame Capture。

---

## 4. 修复方案

### 4.1 先做无副作用现场采集

当前实现已补齐以下 Debug 证据,但**不会自动调用 `play()`、`pause()`、`readNextFrame()` 或重建播放器**:

- AngelLive 在 `willResignActive`、`didEnterBackground`、`willEnterForeground`、`didBecomeActive` 记录 `engineState`、`playerState`、`isPlaying`、进后台前播放意图、playhead、buffer、bytes、network speed、FPS 和播放 surface 状态;
- 回前台 watchdog 在 `+1/+2/+3/+5s` 采样同一组状态,只读判定 A/B/C;
- Debug KSPlayer 分支记录 `KSPlayerLayer` 实际收到的前后台事件、实际执行的 `player.enterBackground()` / `player.enterForeground()` / `play()` / `pause()`;
- `MetalPlayView` 记录 `isPaused`、后台标记、display link 状态、渲染路径和视图/Drawable 几何信息;
- 回前台后第一次真正进入 `CAMetalLayer.nextDrawable()` 时记录成功,或记录 `nextDrawable` 不可用;不会为了探测而额外调用 `nextDrawable()`;
- iOS Debug scheme 已打开 Metal API Validation 和 GPU Frame Capture。真机卡住时使用 Xcode 的 Capture GPU Frame,不能用 FPS 单独推断 Drawable。

KSPlayer 诊断分支位于本机相邻路径 `/Users/pangchong/Desktop/Git/KSPlayer`,分支 `codex/foreground-diagnostics`;远程依赖没有这些埋点时,AngelLive 侧日志仍可用,但缺少内部 `enterForeground`/Drawable 证据。

### 4.2 按证据修复,不预设是 KSPlayer

- **C 类:暂停未恢复** — 只有在日志确认「进后台前在播、回前台后 `.paused`、没有实际 `play()`」时,在 AngelLive 生命周期层对原本在播的会话补一次幂等 `play()`。用户原本暂停的会话不能自动播放。
- **A 类:渲染循环/Drawable** — 只有在 playhead 或音频仍推进、FPS 为 0,并且 KSPlayer 日志/GPU Frame Capture 确认 display link 或 `nextDrawable` 异常时,才修改 KSPlayer 的 `MetalPlayView`/Metal 渲染生命周期。
- **B 类:直播管线** — 只有在 playhead 停止、buffer 耗尽并且日志确认取流、demux 或 reconnect 断供时,才修 AngelLive 取流/重连策略或 KSPlayer 管线;不能仅凭“画面卡住”就重建。

### 4.3 播放器重建的边界

`hardReloadPlayer()` 不作为自动回前台策略,也不作为 A/B/C 的默认判定结果。只有以下两种情况允许使用:

1. 用户明确点击“重新加载”或确认恢复;
2. 有运行时证据证明当前 player 实例不可恢复,且 `play()`、渲染恢复、管线重连均已失败。

即使需要重建,也应记录触发原因、旧实例状态和新实例首帧结果,避免把重建当成根因修复。

---

## 5. 验证

1. **复现回归**:横屏 + 竖屏各跑「进后台 30s+ → 回前台」×20 次,统计卡死率(修前 vs 修后)。
2. **HLS 专项**:挑确定走 KSAVPlayer 的 m3u8 直播间,重点验 4.3。
3. **reload 路径**:卡死后点重新加载必须能恢复,不允许「只能退房间」。
4. **不回归 Bug1**:横屏回前台仍保留横屏(见 `DetailPlayerView.reassertLandscapeOrientation()`)。
5. **协调器单测**:为 4.4 的 `rearm()` 补 `PlaybackRecoveryCoordinatorTests` 用例。

---

## 6. 关联

- `PlaybackRecoveryCoordinator` — 已上线的统一恢复协调器实现
- `docs/PlaybackResilienceRoadmap.md` — 整体韧性栈
- Bug1(横屏回前台变竖屏)修复:`DetailPlayerView.swift` `reassertLandscapeOrientation()` + scenePhase 记录 `wasLandscapeBeforeBackground`
