# WebP 流式重构工作总结与项目排查指南

> **已过时**：本文记录 Phase 3–5 的重构过程，文件名和职责边界已继续演进。当前
> 架构见 [STREAMING_IMAGE_PIPELINE_ARCHITECTURE.md](STREAMING_IMAGE_PIPELINE_ARCHITECTURE.md)。

**文档目的**：总结本次对话中从问题分析、架构设计、补丁迭代到 Phase 3–5 收口所完成的工作，并将由于缺少完整项目仓库、native 实现、Flutter SDK 和测试环境而可能存在的错误或不一致，整理成可逐项执行的排查清单。

**适用版本**：以 `webp_refactor_complete_v3.patch` / `webp_refactor_complete_v3.zip` 为最终审计对象。

**重要结论**：当前成果属于“基于已提供源码片段和架构规范生成的完整候选实现”，不是已经在真实仓库中通过编译、单测、native 构建和设备运行验证的正式版本。已完成的验证主要是补丁应用、文件结构、接口契约和静态文本检查。

---

## 1. 输入材料与边界

本次工作使用了以下材料：

- 初始架构问题说明和迁移进度文本。
- 一个由多个 Dart 源文件拼接而成的源码附件，而不是完整 Git 仓库。
- `WEBP_REFACTOR_SPEC.md`：行为、状态、native source、session、调度和验收要求。
- `implementation_plan.artifact.md`：Phase 1–6 的实施计划。
- `WEBP_REFACTOR_ARCHITECTURE.md`：最终数据流、生命周期和移除项定义。
- 对话中用户反馈的实际编译错误。

未提供或无法完整确认的内容：

- 完整 `pubspec.yaml`、Flutter/Dart 版本和依赖锁定文件。
- `utils/webp_decoder.dart` 的完整 Dart FFI 声明。
- C/C++ native source、playback cursor、增量 RIFF parser 的实现和 ABI。
- `ImageDownloader.loadComicImage`、`ImageDownloadProgress`、`CacheManager`、`ResourceManager`、`ResourceEntry` 等完整实现。
- Android/iOS texture registry、Surface/Texture 生命周期和平台上传代码。
- 完整测试目录、所有自定义 `WebPTransport` 实现及外部调用点。
- 可运行的 Flutter/Dart SDK；因此未执行 `flutter analyze`、`flutter test` 或 native 构建。

这意味着：代码中的项目级接口名、参数、可见性、part 文件关系、异步语义和平台行为都必须在真实仓库中复核。

---

## 2. 从对话开始到现在的工作回顾

### 2.1 初始架构分析

最初确认的问题不是单个漏信号，而是架构边界错误：

1. `ImageDownloadProgress` 同时承担 progress、chunk、reset 和 final bytes，consumer 通过 `currentBytes - chunk.length` 推导 offset，缺少 epoch、sequence 和明确偏移。
2. 网络 transport、输入、demux、holder、播放 cursor 生命周期相互绑定，调度抢占会重建半条流水线。
3. decode/upload policy 会影响 authoritative input，导致关闭 decode 时跳过 chunk。
4. `ResourceEntry`、`DecoderManager`、holder、scheduler、downloader、visible stream 同时保存状态，缺少唯一权威。
5. 网络、decode、precreate 共用并发池，decode 饱和会阻塞 current 下载。
6. native context 混合输入、demux、播放位置和合成画布。
7. visible 重挂载依赖 Dart history 重放，成本高并容易出现 gap。

据此确定最终方向：

```text
NetworkTransport
  -> NativeWebPSource（唯一字节权威）
  -> WebPDecodeSession / WebPPlaybackCursor
  -> WebPFrameHolder
  -> FrameRenderer
  -> WebPImageProvider
```

### 2.2 第一版完整补丁

第一版尝试完成：

- `DownloadSessionRegistry`、`WebPDecodeSessionRegistry`。
- network/decode/upload 独立 lane。
- writer lease、decode/upload task、holder 和 Session completer。
- `WebPImageProvider` 切换到新 Session 链路。

但由于没有完整仓库和真实编译环境，第一版存在接口扩散未收敛的问题。

### 2.3 用户反馈后修复的确定性编译问题

用户实际指出并推动修复了以下问题：

- `DownloadSession.append` 增加 `DownloadWriterLease` 后，多个调用点未同步更新。
- `DownloadSessionRegistry.evict` 未定义。
- `_BlockingTransport.execute` 与 `WebPTransport.execute` override 签名不一致。
- `DownloadSession.markReceiving` 未定义。
- `seal` 参数数量与旧调用不兼容。
- `WebPDecodeSessionRegistry.evict` 未定义。

v2 的修正策略是：

- 保持 `WebPTransport.execute(DownloadSession, { ... })` 的旧公共签名，writer 由 scheduler task 创建，生产 transport 通过 `requireActiveWriter()` 获取。
- `append` 接受可选 writer，生产路径显式传 writer；旧测试和辅助路径暂时兼容。
- 补回 `markReceiving`、`markPaused`、`markFailed`。
- `seal` 同时兼容零参数和 writer/file 参数。
- 两个 registry 都提供严格的 `tryEvict` 和 `evict`。

### 2.4 规范驱动的 v3 收口

收到正式 spec、实施计划和架构文档后，v3 进一步补齐：

- partial 输入到达当前可用帧尾部时只 restart cursor，循环已有完整帧，不 reset/reload source。
- cursor 未 ready 或尚无完整帧时按 committed length 阻塞，避免空 decode busy loop。
- decode/upload 使用独立 revision、claim 和 in-flight 计数。
- source epoch 变化使旧 decode/upload 输出失效。
- source switch 时旧 decode session 进入 retired 集合，等待 in-flight 归零后释放。
- final payload 不允许修补已存在的流式缺口。
- artifact restore/append/reset/flush/promote 生命周期。
- WebP 与 generic fallback 分离。
- static WebP、animated fallback 和非 WebP 通过 Flutter codec 处理。
- `WebPImageProvider` 仅消费 Session/Holder，不再创建第二条 visible stream。
- renderer ownership 规则与 future native texture backend 边界。

---

## 3. 最终候选架构

### 3.1 身份

- Download identity：`(imageKey, sourceKey, cid, eid)`。
- Decode identity：`(fullKey, targetWidth, targetHeight)`。
- `DownloadSessionRegistry` 保证一个下载身份最多对应一个 active/retained source。
- `WebPDecodeSessionRegistry` 保证一个 decode identity 最多对应一个 active cursor。

### 3.2 生命周期

- detach 只删除 demand lease。
- 网络取消/抢占：`receiving -> paused`，保留 source、committed bytes、artifact 和 decode state。
- source switch：增加 epoch，旧 writer 失效。
- 物理释放仅通过显式 eviction。
- retired decode session 等待 decode/upload in-flight 归零再释放 cursor 和 source dependency。

### 3.3 调度

- network lane：3。
- decode lane：2。
- upload lane：2。
- priority promotion 原地更新已有 task。
- stage revision 独立，decode policy 变化不使 network task 失效。

### 3.4 输出

- holder 仅保存 raw/rendered frame queue、watermark、demand 和 waiter。
- `FlutterImageRenderer` 将 native RGBA 转换为 `ui.Image`。
- `NativeTextureRenderer` 只定义稳定 backend contract，未包含项目特定平台实现。

---

## 4. 修改文件总览

最终候选实现涉及 13 个 Dart 文件，共约 5,120 行：

| 文件 | 主要职责 | 重点排查 |
|---|---|---|
| `pipeline/pipeline_controller.dart` | 页面窗口 policy 到 Session lease 的映射 | legacy projection、`resources.clear()` 副作用、scope 生命周期 |
| `pipeline/task_scheduler.dart` | 三个独立调度 lane、priority update、preemption | 与旧 scheduler 调用兼容、running cancel 释放时机 |
| `pipeline/tasks.dart` | WebP download/decode/upload task | task state、cancel/complete 双通知、自定义 transport 兼容 |
| `pipeline/webp_provider_static.dart` | 目标尺寸、旧 holder/precreate 兼容 | 是否仍触发第二条下载/decoder 路径 |
| `renderer/frame_renderer.dart` | native frame ownership、Flutter/native texture renderer | FFI 指针生命周期、错误回调、平台 backend ownership |
| `runtime/webp_session_completer.dart` | Session 到 Flutter ImageStream 的 adapter | Flutter API 版本、播放节奏、fallback、dispose |
| `session/download_session.dart` | source writer、epoch、transport state、registry | native API 对齐、兼容 writer 绕过、seal/reset 语义 |
| `session/webp_decode_session.dart` | cursor、decode/upload claim、registry | cursor API、partial loop、source reset、in-flight 清理 |
| `session/webp_frame_holder.dart` | bounded raw/rendered queues | watermark、帧数量约束、资源释放 |
| `session/webp_session_coordinator.dart` | demand reconcile、任务提交、retired/eviction | dispose 异步收口、换源、pending eviction |
| `webp_image_provider.dart` | Flutter provider 入口和 part 组合 | part 文件存在性、旧 static API 语义、Flutter load API |
| `network/webp_download_artifact.dart` | partial/final artifact | 路径、原子 promote、校验元数据、崩溃恢复 |
| `network/webp_download_transport.dart` | legacy stream 到显式 offset ingress | Range/reset 合同、final event、local file、取消竞态 |

---

## 5. 核心优化修改对照

| 原问题 | 当前修改 | 预期收益 | 仍需确认 |
|---|---|---|---|
| 通过 progress 推导 chunk offset | `_WebPIngress` 自己维护单调 `receivedLength`，append 使用显式 offset | 结构性消除 gap/overlap 推导错误 | legacy downloader 是否始终按顺序发 chunk |
| 旧异步回调可能在抢占后写入 | `DownloadWriterLease` + transport revision + source epoch | stale writer 被拒绝 | native append 是否也验证 epoch/reservation |
| decode policy 关闭时丢输入 | transport 是唯一 chunk consumer，decode/upload 只改变 demand | 输入连续性与页面策略解耦 | 所有外部 chunk consumer 是否已删除 |
| 网络与 decode 共用槽位 | 三个 scheduler lane | current 网络不被 decode/precreate 阻塞 | 完整仓库是否还有旧 scheduler 实例 |
| holder 持有下载/stream/decoder | 新 holder 只保存 frame queue/demand | 生命周期边界简化 | 旧 holder 是否仍被外部调用 |
| partial 尾部无新帧时停止 | cursor restart，循环已有完整帧 | 慢下载可持续播放 | native cursor restart 是否只重置播放状态 |
| 每次 append 可能空 decode 循环 | committed-length blocking | 避免 CPU busy loop | native state.ready 和 frame availability 含义 |
| source switch 立即 dispose cursor | retired decode session 延迟释放 | 避免 upload/decode 与 cursor dispose 并发 | task 完成是否一定触发 reconcile |
| final bytes 作为修复手段 | final 长度必须等于 ingress committed length | 不掩盖不连续输入 | downloader 是否会重复发送“全量 final + chunks” |
| visible 自己下载/重放 history | ImageProvider 只订阅 Session/Holder | 无第二条 stream，无 history replay | 旧 completer/visible loader 是否仍可被构造 |
| static/non-WebP 失败 | sealed 后 Flutter codec fallback | 保持兼容 | local/file URI、超大静态图内存 |
| renderer 直接散落在 holder | 稳定 `FrameRenderer` contract | 后续可切 native texture | 平台 backend 尚未实现 |

---

## 6. 已验证、部分验证和未验证

### 6.1 已验证

- 完整 v3 patch 可对提供的原始快照执行 `patch --dry-run`。
- v2 -> v3 增量 patch 可对 v2 快照执行 `patch --dry-run`。
- 两条应用路径产生的 13 个 Dart 文件与 `modified/lib` 一致。
- 自定义静态契约脚本通过：13 个文件结构、关键 API 和禁止项检查。
- 用户已指出的 registry、transport override、`markReceiving`、`seal` 兼容问题在 v3 候选代码中有对应实现。

### 6.2 仅按规范实现，未真实编译验证

- Dart import、part、类型和 override 是否全部正确。
- Flutter `ImageProvider` / `ImageStreamCompleter` API 与项目锁定版本是否一致。
- custom transport/test double 是否与兼容签名一致。
- 所有旧调用点是否已迁移。

### 6.3 完全依赖完整项目才能验证

- native FFI ABI 和线程安全。
- 增量 RIFF/ANMF parser 的正确性。
- Android/iOS 构建和 texture backend。
- HTTP Range、200/206、换源、cookie、代理、JS callback 行为。
- 真实设备内存、首帧延迟、frame pacing 和 leak。

---

## 7. P0：必须先排查的编译与接口一致性问题

### P0-01 补丁基线是否正确

**风险**：如果仓库已经局部应用 v1/v2、又应用完整 v3，会产生重复代码或冲突。

检查：

```bash
git status --short
git apply --check webp_refactor_complete_v3.patch
# 已应用 v2 时改用：
git apply --check webp_refactor_v2_to_v3.patch
```

预期：只选择一种应用路径。

### P0-02 Dart/Flutter SDK API

重点确认：

- `ImageProvider.loadImage` 的签名和 `ImageDecoderCallback` 是否仍适用。
- `ImageStreamCompleter.onDisposed()`、`reportImageChunkEvent()`、`reportError()` 是否与项目 Flutter 版本一致。
- `ui.decodeImageFromPixels` 和 `ui.instantiateImageCodec` 的签名。
- `ui.Image.dispose()`、`ui.Codec.dispose()` 可用性。

执行：

```bash
flutter --version
dart format lib/foundation/image_provider lib/network
flutter analyze
```

### P0-03 native Dart API 精确对齐

候选代码依赖以下符号：

```text
WebPByteSource
NativeWebPSource
NativeWebPSourceState
WebPFrameCursor
NativeWebPPlaybackCursorState
createNativeWebPSource
createNativeWebPPlaybackCursor
nativePoolRelease
```

并假设 source/cursor 至少具有：

```text
source.epoch
source.state.committedLength
source.append(bytes, offset: ...)
source.reset(epoch: ..., expectedLength: ...)
source.seal()
source.dispose()

cursor.state.ready
cursor.state.targetWidth/targetHeight
cursor.decodeFrames(count)
cursor.restart()
cursor.dispose()
```

逐项对照 `utils/webp_decoder.dart` 和 C ABI。任何名称、参数、返回类型或同步语义不同都会直接编译失败或产生生命周期错误。

### P0-04 part 文件和重复定义

`webp_image_provider.dart` 仍保留旧 part：

```text
webp_stream_session.dart
webp_stream_completer.dart
webp_playback_controller.dart
webp_decoder_holder.dart
webp_decoder_manager.dart
```

同时新增 `webp_session_completer.dart`。必须检查：

- 新 part 文件已经存在于正确目录。
- 旧 part 中没有同名类、extension、top-level 变量或静态函数。
- 旧 completer 不再被构造。
- 旧 stream/coordinator 的引用是否仍从其他库进入。

推荐：

```bash
rg "_WebPImageStreamCompleter|_WebPSessionImageStreamCompleter|WebPStreamDecodeCoordinator|_WebPStreamSession|streamOwner|RESYNC" lib test
```

### P0-05 所有 transport 和测试 override

公共 contract 最终保持：

```dart
Future<File> execute(
  DownloadSession session, {
  CancelToken? cancelToken,
  void Function(WebPTransportProgress progress)? onProgress,
});
```

检查所有：

```bash
rg "implements WebPTransport|extends WebPTransport|Future<File> execute" lib test
```

特别检查 `_BlockingTransport`、fake transport、mock transport。

### P0-06 append/seal/reset 调用点

生产代码应显式使用活动 writer；兼容路径只是临时措施。

```bash
rg "\.append\(|\.seal\(|resetSource\(|markReceiving\(" lib test
```

检查规则：

- 网络生产路径必须传 writer。
- 测试可暂时依赖可选 writer，但应逐步改为显式 writer。
- 不允许 holder、visible 或 decoder 直接 append。

---

## 8. P0/P1：当前候选代码中最值得警惕的兼容与行为风险

### R-01 兼容 writer 会弱化严格 single-writer contract（高）

`DownloadSession._resolveWriter()` 在没有 writer 且没有 active writer 时会自动 `beginTransport()`。这是为旧测试和调用兼容而保留的，但它允许 scheduler 之外直接开始 transport。

建议：

1. 先通过 `rg` 更新全部调用点。
2. 测试改为显式 `beginTransport()`。
3. 最终把 `append/updateExpectedLength/resetSource/seal` 的 writer 改回 required。

### R-02 旧 `DownloadTask`、`PrecreateTask` 和 `ensureHolder` 仍存在（高）

这些类仍可能通过 `fetchImageBytes` 或旧 decoder manager 创建第二条下载/解码路径。当前提供片段中没有看到 PipelineController 提交这些旧任务，但完整仓库可能存在外部调用。

排查：

```bash
rg "DownloadTask\(|PrecreateTask\(|ensureHolder\(|fetchImageBytes\(" lib test
```

目标：WebP 生产路径只能由 `WebPDownloadTask -> WebPTransport -> DownloadSession` 写入。

### R-03 legacy projection/stub 可能静默改变旧调用者行为（高）

`PipelineController` 中保留：

```text
publishExternalHolder
publishExternalBytes
publishExternalDownloadProgress
hasStreamDecodeAttached -> false
waitForStreamResult -> Future.value(null)
ensureStreamWork -> _syncPolicyLeases
```

其中返回 false/null 的 stub 可能让旧 caller 不报错但走错误分支。应逐个查找 caller，决定删除、迁移或提供明确异常，不建议长期保留静默 stub。

### R-04 `resources.clear()` 的真实副作用未知（高）

`setTargetSize()` 和 `detachReaderSession()` 都调用 `resources.clear()`。新注释把 ResourceEntry 定位为 policy projection，但完整 `ResourceManager.clear()` 可能仍会：

- dispose holder；
- 清 cache；
- 触发 callback；
- 取消 task；
- 操作旧 stream coordinator。

必须阅读真实实现。只有确认它不触碰 Native Source/DecodeSession 后，才能满足“detach 只撤 demand”。

### R-05 coordinator dispose 没有等待异步任务退出（高）

`WebPSessionCoordinator.dispose()` 是同步方法：detach lease 后发起 eviction/cancel，但 running network/upload 可能仍在异步退出。随后 `PipelineController.dispose()` 调用 scheduler.clear()，也不等待 native frame/transport 完成。

可能后果：

- 测试 teardown 泄漏。
- app shutdown 时异步 callback 访问已关闭 stream。
- retired session 未最终 evict。

建议新增异步 shutdown：

```text
Future<void> close()
  -> detach leases
  -> cancel tasks
  -> await lane idle
  -> drain retired/pending evictions
  -> close registries/controllers
```

### R-06 HTTP Range 正确性依赖 legacy downloader 的 reset 合同（高）

新 transport 没有直接读取 HTTP status/Content-Range/ETag，而是依赖 `ImageDownloadProgress.reset`。必须确认 `ImageDownloader.loadComicImage` 在以下情况发 reset：

- Range 请求返回 200。
- Content-Range 起点不匹配。
- ETag/Last-Modified 变化。
- source URL/重定向变化。
- partial 文件与服务器对象不一致。

当前 artifact 没有持久化 ETag、Last-Modified 或 source validator。若 legacy downloader 未覆盖，resume 仍可能拼接不同对象。

### R-07 local file 支持未在新 transport 中显式实现（高）

规范要求 local file 继续工作，但 `ImageDownloaderWebPTransport` 统一调用 `ImageDownloader.loadComicImage`。需确认它能处理：

- 本地绝对路径。
- `file://` URI。
- 已缓存 File。
- 无网络但 artifact 已存在的场景。

否则应增加 `LocalFileWebPTransport`，不能假定网络 loader 自动兼容。

### R-08 source/cursor API 同步语义（高）

候选代码假设：

- `source.append` 完成时 frame index 已同步更新或至少状态可立即读取。
- `source.seal` 同步完成最终 parse。
- `cursor.restart` 不访问已释放 source。
- source 有 native refcount，cursor 存活期间 source dispose 安全受控。

这些必须通过 native 单测和 TSAN/ASAN 验证。

### R-09 fullKey 和 target size 双重编码（中高）

`fullKey` 通常已经包含 `@WxH`，`WebPDecodeIdentity` 又单独保存 `targetWidth/targetHeight`。如果 caller 构造不一致，可能出现：

```text
fullKey=image@1080x1920, targetWidth=720, targetHeight=1280
```

建议统一：要么 identity 只保存 canonical fullKey，要么 fullKey 从 imageKey 和 dimensions 内部生成并加 assert。

### R-10 target size 为 0 的 standalone provider（中高）

`WebPImageProvider` 默认 targetWidth/targetHeight 为 0。页面路径通常先调用 `calculateTargetSize/setTargetSize`，但独立使用 provider 时 cursor 是否支持 0 取决于 native 实现。

增加测试：直接构造默认 provider，不调用 `onPageChanged`，检查是否能解码为 intrinsic size。

### R-11 fallback 的 50ms 固定等待（中）

fallback 前固定等待 50ms，假设 native `seal` 和最终 index publication 基本同步。若 native 最终解析是异步的，可能过早 fallback；若同步，则该 delay 只是额外首帧延迟。

更稳妥：使用明确的 `finalIndexPublished` / `decodeAttemptCompleted` 状态，而不是定时器。

### R-12 新播放控制简化了旧逻辑（中）

旧 playback controller 存在 startup watermark、buffer pressure delay、空帧等待和 resume 状态。新 completer 在拿到第一张 rendered frame 后立即播放，并使用简化 delay。

这符合“首帧尽早播放”的目标，但可能改变：

- 缓冲不足时的卡顿概率。
- current 页的动态减速。
- app resume 后恢复行为。
- repetition/partial loop 的节奏。

需要用慢网和 4K 动图对比旧版体验。

### R-13 frame batch 数量缺少 native 返回数量断言（中）

`decodeFrames(reservedFrames)` 理论上不应返回超过 reserved 的帧。holder 当前会全部加入队列。建议 assert：

```text
frames.length <= claim.reservedFrames
```

并在违反时释放多余 frame、记录 native contract error。

### R-14 artifact 路径和原子 promote（中高）

需确认：

- `${CacheManager.cachePath}_partial/$name` 是正确目录，而不是少了路径分隔符。
- `promoteFile` 是否同文件系统原子 rename。
- promote 失败时 partial 是否仍可恢复。
- 多进程/多 isolate 是否可能同时打开同一 partial。
- app crash 后 open sink 数据是否完整落盘。

### R-15 stream watch 的“原子快照”只是 Dart 层近似（中）

`watch()` 先订阅 broadcast stream，再 `add(snapshot)`。由于 controller 是异步 broadcast，通常快照会先到，但必须通过测试确认事件顺序，特别是 source state 在 listen 与 snapshot 之间变化时。

可考虑用单一 sequence/revision，并让 consumer 丢弃旧 revision。

### R-16 native texture 只是接口，不是 Phase 6 完成实现（明确未完成）

`NativeTextureFrameBackend` / `NativeTextureRenderer` 只解决稳定边界。还缺：

- texture id 注册和注销。
- Surface 生命周期。
- GPU upload/复用。
- UI widget 展示。
- app pause/resume。
- frame fence 和 backpressure。

不要把“backend contract 已定义”等同于“原生纹理已完成”。

---

## 9. 文件级逐项排查清单

### 9.1 `download_session.dart`

- [ ] `WebPByteSource` 实际 API 与候选代码完全一致。
- [ ] native source 自己验证 epoch、offset、reservation，而不是只依赖 Dart。
- [ ] 所有生产 append 都显式传 writer。
- [ ] `seal()` 不再被无 writer 的生产代码调用。
- [ ] `expectedLength` 在 unknown/chunked 响应时不会错误阻止 seal。
- [ ] `fallbackContent` 切换会正确 reset native source。
- [ ] `retainDecodeSession/releaseDecodeSession` 成对。
- [ ] `StreamController.close()` 后不会继续 schedule publish。
- [ ] registry evict 测试覆盖 active demand、active writer 和 dependent decode。

### 9.2 `webp_decode_session.dart`

- [ ] cursor state 字段名和含义正确。
- [ ] `decodeFrames(count)` 返回 frame ownership 明确。
- [ ] partial 尾部返回空列表，而不是抛 fatal error。
- [ ] sealed 静态 WebP 的“无 animation frame”能进入 fallback。
- [ ] source reset 后 cursor.restart 是否足够；若 native 需要 cursor recreate，应调整。
- [ ] stale decode/upload 输出全部释放且 in-flight 归零。
- [ ] retired session 最终一定收到 reconcile。
- [ ] `WebPDecodeSessionRegistry.evict` 单测存在并通过。

### 9.3 `webp_frame_holder.dart`

- [ ] current/near watermark 与项目原规则一致。
- [ ] far 时释放 rendered/raw 但保留 session 是产品预期。
- [ ] `finishDecodeClaim` 验证返回帧数不超过 reservation。
- [ ] dispose 与 running claim 不会并发发生。
- [ ] 每个 raw frame 只 release 一次，每个 rendered frame 只 dispose 一次。

### 9.4 `webp_session_coordinator.dart`

- [ ] 同一 source identity 不重复创建 session。
- [ ] source switch 时旧 visible/policy lease 的处理符合 UI 预期。
- [ ] running transport 无 demand 时继续下载的策略符合现有窗口规则。
- [ ] explicit eviction 能取消 receiving transport 并最终 drain。
- [ ] dispose/teardown 改为可等待的异步流程。
- [ ] task key 不会与非 WebP task 冲突。

### 9.5 `task_scheduler.dart` / `tasks.dart`

- [ ] 所有 `SchedulerTask` 子类都有正确 lane。
- [ ] running cancel 不提前释放 permit。
- [ ] 每个 task 只调用一次 completed/failed callback。
- [ ] cancel 后 waiter error 类型符合现有调用者预期。
- [ ] migrateTasks 的 `activeKeys` 是否同时包含三个 lane 的 key。
- [ ] legacy DownloadTask/PrecreateTask 是否还能进入 WebP 路径。
- [ ] decode 是否真的运行在 worker/isolate/native worker；当前 Dart task 本身是同步调用 cursor。
- [ ] upload lane 并发 2 是否符合 Flutter UI 线程限制。

### 9.6 `webp_download_transport.dart`

- [ ] `ImageDownloadProgress` 字段真实存在：`reset/totalBytes/chunkBytes/imageBytes`。
- [ ] event 顺序严格有序。
- [ ] finalBytes 是否可能重复此前 chunks；当前要求长度相等。
- [ ] Range 200/206 和 reset 合同。
- [ ] cancel 时 iterator、HTTP request、artifact sink 全部关闭。
- [ ] source switch 不会让旧 iterator 继续写。
- [ ] local file 和 cache hit 路径。
- [ ] 非 WebP 内容 sniff 前 12 字节逻辑正确。

### 9.7 `webp_download_artifact.dart`

- [ ] partial path 正确。
- [ ] artifact 与 source identity 不会碰撞。
- [ ] 恢复时 source > artifact、source < artifact、artifact <12 bytes 均有测试。
- [ ] ETag/Last-Modified 或等价 validator 已在 downloader 层校验。
- [ ] promote 原子性和失败恢复。
- [ ] file sink flush/close 异常处理。

### 9.8 `webp_session_completer.dart` / `webp_image_provider.dart`

- [ ] Flutter SDK override 编译通过。
- [ ] listener 数量从 0 -> 1 和 1 -> 0 时 attach/detach 正确。
- [ ] ImageInfo/ui.Image ownership 无泄漏或过早 dispose。
- [ ] app paused/resumed 后不会重复 pump。
- [ ] terminal error 后是否应该允许 source retry；当前 `_reportedTerminalError` 会阻止后续错误/恢复提示。
- [ ] fallback animation repetitionCount 与产品预期。
- [ ] standalone provider 的 target size 0。
- [ ] `clearAll()` 新语义是否与旧 caller 预期一致。

### 9.9 `pipeline_controller.dart`

- [ ] `ResourceManager.clear()` 无物理 WebP 清理副作用。
- [ ] page context 判断不能只依赖 `identical(_images, images)`；同一内容的新 List 会被视为 context change。
- [ ] target size 变化不会错误丢失仍需 retained 的 sessions。
- [ ] policy scope id 增长和 detach 不重复。
- [ ] `publishExternal*` caller 已迁移或删除。
- [ ] `waitForStreamResult` / `hasStreamDecodeAttached` 不应静默返回假值。
- [ ] current/near/far download/decode/upload demand 与原窗口行为一致。

### 9.10 `frame_renderer.dart`

- [ ] native RGBA format、stride 和 buffer length 正确。
- [ ] `decodeImageFromPixels` 回调失败/永不回调时有超时或错误处理策略。
- [ ] native frame release 可以安全从 Dart UI callback 调用。
- [ ] custom renderer 遵守 ownership；task 的幂等 release 不掩盖 use-after-free。
- [ ] native texture backend 实现前不要切换生产 renderer。

---

## 10. 建议的测试矩阵

### 10.1 单元测试

#### DownloadSession

- contiguous append 成功。
- gap、overlap、stale writer、stale epoch 被拒绝。
- pause 后 committed length 不变。
- reset 后旧 writer 失效或 epoch 更新符合设计。
- seal 长度匹配/不匹配。
- fallback range 连续性。
- active demand/writer/decode dependency 时 evict 失败。

#### Artifact

- empty restore。
- 小于 12 字节 unknown restore。
- WebP partial restore 到 empty source。
- retained source 与 artifact 同长度时不 replay。
- artifact 比 source 多一 chunk 时只补差量。
- reset、promote、promote failure。

#### DecodeSession/Holder

- claim/complete 计数闭环。
- stale revision 输出释放。
- partial 空 decode 在相同 committed length 不忙循环。
- holder 清队列释放资源。
- upload error、cancel、renderer throw。
- retire 后 in-flight 归零再 evict。

#### Scheduler

- lane 容量互不影响。
- current network 抢占 far network。
- running task cancel 不提前释放 permit。
- same key promotion 不重建 task。
- callback 只执行一次。

### 10.2 集成验收场景

| 编号 | 场景 | 核心断言 |
|---|---|---|
| A1 | 慢速下载 | 首个完整 frame 出现后播放；后续字节继续 append；partial 可循环 |
| A2 | current -> near/far -> current | source/cursor identity 不变，无 holder drop、gap、network restart |
| A3 | 网络抢占 | paused 后 exact committed offset resume，partial 仍可播放 |
| A4 | 非零进度 attach | cursor 从 source offset 0 读取，不依赖 broadcast history |
| A5 | source switch | 旧 epoch chunk 拒绝，新 source 从 0 开始，旧 in-flight 安全释放 |
| A6 | final 到达 | authoritative frame count 更新，不 reload final bytes |
| A7 | reader/gallery 往返 | logical detach，session 按 retention policy 复用 |
| A8 | 快速滑页 | current network 不等待 decode slots，stale display lease 安全释放 |
| A9 | 4K 动图 | watermark 有效，raw/upload queue bounded，无持续内存增长 |
| A10 | leak | source/cursor/frame handle 计数回到 retained/evicted 预期 |
| A11 | static WebP | sealed 后显示静态图，不进入无限 decode |
| A12 | non-WebP | generic fallback 正常，native source 不被污染 |
| A13 | local file | 无 HTTP 仍能完成 source/artifact/codec 路径 |
| A14 | Range 返回 200 | artifact/source 原子 reset，不把完整响应追加到 partial |

---

## 11. 推荐排查顺序

### 第 1 步：建立干净分支

```bash
git checkout -b webp-session-refactor-audit
git status --short
```

不要在已有混合 v1/v2 修改的工作区直接继续堆补丁。

### 第 2 步：只做编译收敛

1. 应用正确 patch。
2. `dart format`。
3. `flutter analyze`。
4. 按错误逐个修正，不先改行为。
5. 重点扫描所有 override、part、FFI symbol 和旧 caller。

### 第 3 步：native contract 测试

先验证 source/cursor，不接 UI：

- reserve/commit/reset/seal。
- incremental frame index。
- cursor partial loop。
- source/cursor 并发和 refcount。

### 第 4 步：transport + artifact

用 fake ordered event stream 测试 offset、reset、cancel、resume，再接真实 Dio/ComicSource。

### 第 5 步：decode/upload/holder

使用 fake source/cursor/renderer，确认 claim、revision、in-flight 和释放。

### 第 6 步：visible adapter

先 current 单页，再 near/far，再快速跳页和 reader detach。

### 第 7 步：删除兼容路径

只有所有 caller 迁移完成后再删除：

- `_resolveWriter` 自动 writer。
- `markReceiving/markPaused/markFailed` 旧 alias。
- legacy `DownloadTask` / `PrecreateTask` 的 WebP 用途。
- `publishExternal*`。
- `waitForStreamResult`、`hasStreamDecodeAttached` stub。
- 旧 stream/completer/owner/resync 文件。

### 第 8 步：性能与泄漏

记录：

```text
current first-frame latency P50/P95
network/decode/upload queue wait
source/cursor create/dispose count
stale writer/decode/upload rejection count
artifact replay bytes
native source memory
raw/rendered frame memory
frame underrun count
page switch source recreation count
```

---

## 12. 建议增加的日志字段

只记录 session 级事件，避免逐帧生产日志：

```text
downloadIdentity
fullKey / targetSize
sourceAddress / sourceEpoch
transportRevision
committedLength / expectedLength
transport transition
policy demand transition
decodeRevision / uploadRevision
cursorAddress
availableFrameCount / authoritativeFinal
raw/rendered/inFlight counts
pause/resume/evict reason
artifact length / resume offset
```

错误日志必须包含：

- source epoch。
- writer revision。
- expected/actual offset。
- committed/final length。
- task lane/key/generation。
- source/cursor identity。

---

## 13. 建议的上线和回滚策略

由于这是大范围架构切换，建议增加临时 feature flag，而不是一次删除旧路径：

```text
useWebPSessionPipeline
```

要求：

- 同一 image identity 同一时刻只能由一条路径写入，不能新旧同时运行。
- flag 只决定入口，不允许在同一 session 中途切换。
- 新链路异常时记录结构化指标并回退到下一次重新加载，不在原 source 中 RESYNC。
- 达到验收标准后删除旧路径和 flag。

回滚触发条件建议：

- native crash / use-after-free。
- gap/overlap invariant error 非零且无法解释。
- current 首帧 P95 明显恶化。
- source/cursor/frame handle 持续增长。
- local/static/non-WebP 回归。

---

## 14. 推荐执行命令

```bash
# 1. 搜索双轨和旧路径
rg "WebPStreamDecodeCoordinator|_WebPStreamSession|streamOwner|RESYNC|progressiveSub" lib test
rg "DownloadTask\(|PrecreateTask\(|ensureHolder\(|fetchImageBytes\(" lib test
rg "publishExternal|waitForStreamResult|hasStreamDecodeAttached" lib test

# 2. 搜索新 API 调用一致性
rg "implements WebPTransport|Future<File> execute" lib test
rg "\.append\(|\.seal\(|resetSource\(|beginTransport\(|requireActiveWriter" lib test
rg "DownloadSessionRegistry|WebPDecodeSessionRegistry|\.evict\(" lib test

# 3. 格式和静态分析
dart format lib/foundation/image_provider lib/network
flutter analyze
flutter test

# 4. native 构建（按项目实际命令替换）
flutter build apk --debug
flutter build ios --debug --no-codesign

# 5. 当前包自带的非编译静态检查
python3 verify_webp_refactor_v3.py lib
```

---

## 15. 最终状态判断

### 已完成的设计与候选代码范围

- 唯一 Native Source 的 Dart session 边界。
- stable Download/Decode registries。
- writer revision 和显式 offset。
- network/decode/upload 独立 lane。
- partial cursor loop。
- holder output-only 化。
- visible Session adapter。
- artifact lifecycle 和 generic fallback。
- renderer/backend 稳定边界。

### 尚不能宣称完成的范围

- 真实仓库零编译错误。
- native ABI 和增量 parser 正确性。
- 所有旧 caller 已删除。
- local file 全路径兼容。
- Range validator 完整性。
- async dispose/teardown 无泄漏。
- Android/iOS native texture backend。
- 所有验收测试通过。

### 建议决策

把 v3 视为“可审查、可分模块接入的参考实现”，不要直接视为可发布代码。优先完成 P0 编译/API 对齐和 R-02/R-03/R-04 双轨清理，再进行慢网、抢占、换源和 leak 测试。只有完整仓库验证通过后，才物理删除旧 stream/coordinator 代码。

---

## 附录 A：本次生成的主要产物

- `phase3_complete.patch`：第一版完整补丁，已被后续版本取代。
- `phase3_compile_fix_v2.patch`：第一版已应用场景的编译修复。
- `phase3_complete_v2.patch`：接口兼容修正版。
- `webp_refactor_v2_to_v3.patch`：v2 到最终候选 v3 的增量补丁。
- `webp_refactor_complete_v3.patch`：从原始快照应用的完整候选补丁。
- `webp_refactor_complete_v3.zip`：完整候选源码、补丁、规范和检查脚本。
- `verify_webp_refactor_v3.py`：SDK 无关的静态契约检查，不代替 Dart 编译。

## 附录 B：排查记录模板

| ID | 状态 | 负责人 | 结果/错误 | 修复提交 | 回归测试 |
|---|---|---|---|---|---|
| P0-01 | 待查 |  |  |  |  |
| P0-02 | 待查 |  |  |  |  |
| P0-03 | 待查 |  |  |  |  |
| P0-04 | 待查 |  |  |  |  |
| P0-05 | 待查 |  |  |  |  |
| P0-06 | 待查 |  |  |  |  |
| R-01 | 待查 |  |  |  |  |
| R-02 | 待查 |  |  |  |  |
| R-03 | 待查 |  |  |  |  |
| R-04 | 待查 |  |  |  |  |
| R-05 | 待查 |  |  |  |  |
| R-06 | 待查 |  |  |  |  |
| R-07 | 待查 |  |  |  |  |
| R-08 | 待查 |  |  |  |  |
| R-09 | 待查 |  |  |  |  |
| R-10 | 待查 |  |  |  |  |
| R-11 | 待查 |  |  |  |  |
| R-12 | 待查 |  |  |  |  |
| R-13 | 待查 |  |  |  |  |
| R-14 | 待查 |  |  |  |  |
| R-15 | 待查 |  |  |  |  |
| R-16 | 待查 |  |  |  |  |
