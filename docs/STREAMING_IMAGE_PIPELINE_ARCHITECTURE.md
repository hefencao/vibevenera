# Streaming Image Pipeline Architecture

> 当前架构，更新于 2026-07-15。
>
> 本文取代 `IMAGE_PIPELINE_ARCHITECTURE.md` 和
> `WEBP_REFACTOR_ARCHITECTURE.md`。前者是资源策略的早期版本，后者是仅以 WebP
> 为中心的 session 重构记录。

## 1. 目标与边界

Reader 图片管线同时解决三类问题：

1. 当前页必须优先下载、解码和显示，切页不能被邻页工作阻塞。
2. WebP/GIF 应在下载完成前尽早播放，同时保留可恢复的磁盘前缀。
3. UI 只报告阅读位置和交互状态；缓存、下载、解码和驱逐由 policy/session 管理。

当前支持两条流式动画路径：

- **WebP native path**：增量字节源、native frame cursor、帧 holder、可选 Android
  native texture。
- **GIF external-codec path**：共用下载和 artifact，Dart 增量索引完整 GIF frame，按
  可解码快照重建 Flutter `ui.Codec`。

普通静态图仍由普通 `ReaderImageProvider` 路径处理。只有扩展名已知为 WebP/GIF，或
来源已被内容嗅探学习为流式动图源时，才进入本管线。

## 2. 分层与依赖方向

```text
Reader / ComicImage
        |
        v
StreamingImageProvider + _StreamingImageCompleter       显示适配层
        |
        v
PipelineController + policy/window/ranker               资源策略层
        |
        v
StreamingSessionCoordinator                             session 编排层
   |                       |
   v                       v
DownloadSession          WebPDecodeSession              状态与所有权层
   |                       |
   v                       v
StreamingImageTransport  native WebP cursor/holder      格式执行层
   |
   +--> StreamingImageArtifact
   +--> _StreamingImageIngress
   +--> GifStreamRuntime --> GifStreamIndexer/ui.Codec
```

依赖只能向下：

- Reader 不创建连接、不决定缓存和解码水位。
- transport 不读取 UI page 状态，只执行 `DownloadSession` 的 writer lease。
- artifact 不调度网络，只保证连续持久化、恢复、校验和 promote。
- GIF/WebP 格式层不修改预加载窗口；它们只向 session/pipeline 报告可用状态。

## 3. 文件职责

### 3.1 通用入口与显示适配

- `foundation/image_provider/streaming_image.dart`
  - `StreamingImageProvider` 的稳定 identity。
  - 汇总 provider support、播放速度和 completer 三个紧密耦合的 part。
- `runtime/streaming_image_completer.dart`
  - 绑定/释放 visible lease。
  - 订阅 download、WebP holder 和 decode snapshot。
  - 负责帧时序、`ImageStreamCompleter.setImage` 与 Android texture 侧通道。
  - 不读取网络流，也不解析 GIF 容器。
- `pipeline/streaming_provider_support.dart`
  - 统一、稳定的物理解码目标尺寸计算。
  - WebP/GIF URL 的轻量路由判断。
- `runtime/streaming_playback.dart`
  - WebP/GIF 共用播放倍速状态；不再以 WebP 命名。

### 3.2 策略与 session 编排

- `pipeline/pipeline_controller.dart`
  - 接收 current/stable page、阅读方向和 interaction。
  - 通过 window/policy/rank 计算 download/decode/upload demand。
  - external codec 就绪时仍扩展下载窗口，但把非当前页 native decode target 压为 0。
- `session/streaming_session_coordinator.dart`
  - 维护 download/decode registry 和 resource lease。
  - 把 network/decode/upload 任务提交到独立 scheduler lane。
  - detach 只撤销 demand；是否保留连接或物理驱逐由 reconciler 决定。
- `session/download_session.dart`
  - 下载 identity、writer lease、transport 状态、连续长度和 artifact handoff。
  - `DownloadContentKind` 记录 `unknown/webp/gif/fallback`。
  - external content 仅在 session 保存连续长度；字节权威仍是 artifact。
- `session/webp_decode_session.dart`
  - 仅负责 WebP native cursor、decode demand 和 source epoch。
  - GIF/普通 fallback 被识别后 `sourceDecodable == false`，不会继续提交 native decode。

### 3.3 通用下载与持久化

- `network/streaming_image_transport.dart`
  - 网络/本地事件源、resume 决策、writer 生命周期、最终 seal/promote。
  - 不包含格式播放逻辑。
- `network/streaming_image_ingress.dart`
  - 接收顺序 chunk，嗅探 WebP/GIF/其他签名。
  - WebP chunk 追加到 native source；GIF/其他格式发布 external contiguous range。
  - GIF 每 64 KiB 或 50 ms flush/publish，使运行时能在封口前读取 durable prefix。
- `network/streaming_image_artifact.dart`
  - `_partial` 文件的唯一写入者。
  - 恢复既有连续前缀，校验最终文件，之后 promote 到共享 cache。
  - partial 到 final 的路径切换通过 session snapshot handoff，不产生第二份字节源。

### 3.4 格式专用执行层

WebP：

- `session/webp_decode_session.dart`
- `session/webp_frame_holder.dart`
- `renderer/webp_texture_channel.dart`
- `renderer/webp_texture_registry.dart`
- `utils/webp_decoder.dart`

这些文件处理 native WebP source/cursor/frame/texture，保留 WebP 命名是正确的。

GIF：

- `runtime/gif_stream_index.dart`
  - 纯增量容器解析器，只保留解析状态，不保留已经消费的压缩字节。
  - 只发布完整 image block 的数量和安全 `completeOffset`。
- `runtime/gif_stream_runtime.dart`
  - 增量读取 artifact、维护 index/source epoch、处理 partial→final handoff。
  - 从安全 offset 构造 codec snapshot；尚无 trailer 时只给快照补一个合成 trailer。
  - 重建 codec 时跳过已经显示的帧，并把新 codec 交回显示适配层原子替换。

解析、artifact 读取和 codec 构建从 completer 中提取后，GIF 不再侵入 session 绑定、
native WebP pump 和 UI 生命周期代码。

## 4. Identity 与唯一所有权

### 4.1 Download identity

```text
(imageKey, sourceKey, cid, eid)
```

一个 identity 同时只能有：

- 一个 `DownloadSession`；
- 一个 active `DownloadWriterLease`；
- 一个 active transport；
- 一个 authoritative artifact；
- WebP 路径下一个 authoritative native byte source。

版本缓存复用可令逻辑图片 identity 指向另一个 download identity，但 decode identity
仍包含当前漫画/页面/目标尺寸。这样只读复用字节，不共享 frame cursor 和播放时序。

### 4.2 Decode identity

WebP decode identity 包含完整显示键和目标尺寸。旋转或窗口实际 resize 会产生新的
decode identity；安全区/系统栏 inset 的变化不会改变目标尺寸。目标尺寸统一取
`View.physicalSize` 并按 8 像素对齐，避免 provider 与 policy 在不同 build 时刻算出
两个 holder。

### 4.3 Epoch

source reset、下载重新开始或 identity rebinding 都必须改变 epoch。cursor、GIF index
和 codec build 都只接受创建时的 epoch；旧异步结果不能覆盖新 source。

## 5. 下载状态流

```text
idle -> queued -> receiving -> sealed
                    |             |
                    v             v
                  failed       promoted cache
```

关键规则：

1. writer lease 是唯一写权限；取消后迟到 chunk 会因 stale writer 被拒绝。
2. append 必须满足 `offset == committedLength`，不能用广播进度推断字节历史。
3. 正常 page-window detach 不主动断开正在 receiving 的连接。部分源不支持 range，保留
   已建立连接比取消后从零下载更可靠。
4. 只有显式 eviction/clear 才尝试物理清理；运行中的任务必须先退出 writer 生命周期。
5. 命中完整 cache 直接 restore/seal，不广播伪下载进度。

## 6. 内容嗅探与分支

transport 最多暂存 12 字节签名前缀：

```text
RIFF....WEBP -> WebP native source
GIF87a/89a   -> external GIF runtime
other        -> sealed 后交给普通 Flutter codec fallback
```

无扩展名来源由 `StreamingSourceRegistry` 学习。学习结果只负责以后选择
`StreamingImageProvider`，不替代逐文件内容嗅探。旧持久化键
`webpAnimatedSources` 只用于兼容迁移，新键是 `streamingAnimatedSources`。

## 7. WebP 流式播放

1. ingress 将连续 WebP chunk 同步提交 native byte source。
2. `WebPDecodeSession` 根据 policy demand 创建/推进 cursor。
3. holder 只保留策略要求的 frame depth，并对 decode/upload claim 做所有权计数。
4. current 页优先 decode/upload；屏外页只达到 policy 指定水位。
5. Android 支持时 frame address 直接更新 native texture；其他平台通过 Flutter image
   renderer 显示。

`SurfaceProducer.setSize` 和 `ANativeWindow_setBuffersGeometry` 只在纹理尺寸第一次确定或
真实变化时执行，不能在每个动画帧重复配置 buffer queue。viewport 过渡被拆成
`idle / dominant / overlap`：只有当前页可见占比低于 policy 水位、两页明显重叠时才冻结
WebP/GIF present；新页已占据主要 viewport 后，即使 PageView 的减速动画尚未结束也恢复
播放。native WebP 的 holder 继续按水位准备帧但 pump 不提前消费；GIF codec 可提前取得
一帧但不提交，帧时长都从真正 present 后重新计时。

没有离散 `PageMetrics` 的 continuous/custom-slider `scroll` 仍在滚动期间冻结 present；
它们不能伪造页面覆盖度。只有 Gallery 的 PageView 使用 dominant/overlap 提前恢复。

Android 的 `ANativeWindow_lock + memcpy + unlockAndPost` 在专用串行 blit 线程执行，不能
占用 Android platform 主线程。成功提交后必须调用 `SurfaceProducer.scheduleFrame()`；
只更新 Surface 而不调度 engine frame，会在 PageView 滚动停止后表现为 WebP 停播。
MethodChannel 的完成回调仍切回主线程，native frame 地址保持到回调完成后才释放。

目标页在越过 `onPageChanged` 中点前就进入 transition 资源角色：下载、解码、上传优先级
高于普通 near，并按 current 缓冲水位取得 1～数帧的准备深度。Android native texture 的
创建也与首次 blit 分离，目标页有 rendered frame 后可提前创建 texture，恢复播放时不再
串行等待 texture create。

download、decode、upload 分属 scheduler 的 network/decode/upload lane。native 工作不在
`onPageChanged` 或 build 中同步执行。

## 8. GIF 边下边播

Flutter `ui.Codec` 的输入在创建后不可追加，因此 GIF 使用“稳定 artifact + 可解码
快照”而不是伪装成可增长 codec：

1. ingress 定期 flush 已下载前缀并发布 committed external range。
2. `GifStreamRuntime` 从上次 offset 增量读取新字节。
3. `GifStreamIndexer` 找到新增完整 frame 和安全结束 offset。
4. runtime 读取 `[0, completeOffset)`，必要时补 `0x3b` trailer，创建新 codec。
5. 新 codec 跳过已播放帧后，completer 原子替换旧 codec。
6. 下载封口且真实 trailer 已出现后，使用最终 codec 正常循环。

GIF 只允许 current 页持续 pump。屏外 completer 可以保持 lease/首帧，但不能继续消耗
external codec CPU。current 状态由 policy lease 决定，不由 widget 的局部 setState
推断。

### 已知成本

每次出现新 frame 都重建 Flutter codec 会重复解析已有前缀；大 GIF 的累计成本可能趋近
O(n²)。当前实现适合验证和中等文件，也暴露了通用架构边界：下载/缓存/session 可以
复用，但真正高吞吐的 GIF 流式解码最终需要可增长输入的 native GIF cursor。届时只替换
GIF 格式执行层，不应再次修改 transport、artifact、policy 或 provider identity。

## 9. Policy 与 UI 解耦

Reader 只报告：

- current/stable index；
- dragging/scroll/jumping/idle；
- 阅读方向预测输入；
- viewport 的连续覆盖度、运动方向及目标图片键。

Policy 决定：

- 下载连接优先级与并发 lane；
- current/next/previous/far 的窗口角色；
- dominant/overlap 阈值与 transition 资源角色；
- WebP decode frame depth；
- upload 权限；
- keep/evict；
- external codec 模式下是否抑制邻页 native decode。

PageView 的 `onPageChanged` 会在滚动动画越过中点时触发，而不是在动画结束时触发。
PageMetrics 的连续位置先报告当前页覆盖度和运动方向上的目标图片键；policy 在中点前把
目标页提升为 transition，中点处再立即提升为 current。present 只在 `overlap` 阶段冻结，
进入 `dominant` 后由 revision wake signal 立即恢复，不等待 ScrollEnd，也不使用
32/120ms poll。页码文字使用独立 notifier 局部重建，不因页码变化重建整个
ReaderScaffold。静态高分辨率页默认使用双线性 low filter，避免首次进入页面时同步生成
mipmap 造成 raster 峰值。

Gallery 的边界 sentinel 跳回、`animateToPage` Future 完成及 ScrollEnd 都显式收口
transition，不能只依赖某一种 ScrollNotification；章节/旋转/reader detach 也会重置交互
状态。图片尺寸确认和首次流式源识别需要重建 Gallery 时，重建合并到过渡结束后的下一帧，
不与 PageView 的 build/layout/raster 叠在同一滚动帧。

WebP worker 池保留一个 current 槽，但不再要求 current 完全停止解码后才允许 near：一个
worker 可补 current，另一个可预解 transition。是否产生 transition/near 解码任务仍由
FrameDepthTable 水位决定；current 水位不足时目标页只保首帧需求，水位恢复后才加深，
而不是让 worker 自行无限预取。两个 cursor 不会在同一 decoder 上并发。

因此不能向 `onPageChanged` 添加缓存或下载策略参数，也不能由
`_precacheLocalReaderPages` 一类 UI helper 直接拥有 session 生命周期。

## 10. 生命周期与驱逐

- `detach`：撤销 lease/demand，不等于取消、删除或 reset。
- `retain`：无 demand 但正在 receiving 时允许连接完成，避免无 range 源重复下载。
- `evict`：只有没有 lease、没有 active claim、没有 active writer 时才能释放。
- `promote`：artifact 校验后移动到 cache；session 同步发布 final file handoff。
- `dispose`：显式 reader/pipeline 清理，取消 timer/task，再排空可安全驱逐的 session。

`CacheManager` 的容量驱逐与 session 的安全驱逐是两个边界：前者选择候选文件，后者保证
文件没有被 active transport/decode/display 使用。扫描器修复 DB 路径时也不能把同键的
轮转目录文件误当作 orphan 删除。

## 11. 测试边界

- `gif_stream_index_test.dart`：任意 chunk 边界、完整 frame 发布、合成 trailer codec。
- `streaming_image_transport_test.dart`：restore/resume、内容嗅探、封口、GIF 封口前
  artifact 可读。
- `streaming_image_provider_test.dart`：provider identity、GIF/WebP 路由和版本隔离。
- `streaming_session_coordinator_test.dart`：lease、任务合并、detach/evict 和 source 绑定。
- `resource_policy_test.dart` 及 window/ranker 测试：UI 交互与资源策略边界。

新增格式时优先复用 download/artifact/session 边界，只增加格式 index/runtime；只有在
格式确实需要独立 native source/cursor 时，才增加新的 decode session，不应把格式判断
重新写回 Reader UI 或 transport 主循环。
