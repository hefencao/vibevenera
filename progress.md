# Project Progress

## 已完成的事项

### Bug 修复 / 行为修正

- WebP 可边下载边播放；root: 完整下载后才创建 animated holder，current 首帧被全量 bytes 阻塞。
- partial cache / resume 已引入；root: 连接中断/缺损 WebP 被当作失败重下，已有有效 bytes 未复用。
- current 页迟迟不下载 / stale 状态修复；root: `download.inProgress=true` 但 scheduler/shared download 已不存在，只 ATTACH 不重启。
- 跳出 3 页外不再立刻取消 running download；root: migration 对 out-of-window running DownloadTask 强制 cancel，慢页回来需重下/等待。
- 下载 rank 加入方向、并发、in-progress、非线性进度；root: 原 rank 只看窗口优先级，未保护快完成/无压力的旧下载。
- UI 下载进度取消强制单调和 holder 抬高；root: 显示层 smoothing 掩盖 cache/resume 真实状态，难定位回退/重放问题。
- 顶部下载进度条已加入；root: 流式播放后转圈消失，partial 卡死时无法判断是否仍在下载。
- `CustomSlider` 左右跳转修复保留 reader `toPage` 修改；root: scaffold 双层按钮逻辑修改方向错误，真正入口在 reader 跳页。

### 重构进展

- 已确认 `stream chunk gap`、holder detach/replay 和 visible/pipeline 双路径属于旧流式架构缺陷，停止继续修补 coordinator。
- 已重写 WebP ARCHITECTURE/SPEC/PLAN，目标改为 native-owned authoritative source、稳定 Download/Decode Session、logical detach 和独立调度 lane。
- 已开始实现最终 `NativeWebPSource` ABI：一次 ingress copy、epoch/offset 连续性、reserve/commit/reset/seal 和增量 RIFF/ANMF 索引。
- 已增加 `DownloadSessionRegistry` 与 demand lease 基础；reader/display detach 只移除逻辑 demand，不执行清理或取消。
- 已实现 `WebPPlaybackCursor` native ABI：source/index 与目标尺寸、合成画布、播放位置分离；cursor 持有 source 引用，source append 不再依赖 holder。
- 已实现 `WebPDecodeSessionRegistry` 与独立 decode/upload demand revision；source commit 通过状态通知唤醒稳定 session，不回放历史 chunk。
- 已将旧 `TaskScheduler` 拆成 network/decode/upload 独立 lane；decode/precreate 饱和不再占用 transport permit 或延迟 current 下载。
- 已将 `ResourceEntry.executionEpoch` 拆为 download/decode/upload revision；decode/upload policy 变化不再使运行中的网络任务失效。
- 已提交：`e1eb066 Improve WebP streaming download scheduling`。
- 已生成 WebP 重构 ARCHITECTURE/SPEC。
- `webp_image_provider.dart` 已用 `part` 拆分，主文件约 143 行。
- 已抽出 `WebPFrameBuffer`、provider loader/static、holder、decode service、manager、completer part。
- 已抽出 `WebPStreamSession`，visible streaming / resume streaming 由 session 承载，loader 保留薄代理。
- 已抽出 `WebPPlaybackController`，completer 只保留 Flutter 生命周期、chunk 上报、结果分发；播放循环/reload/resume 已迁出。
- 已抽出 `webp_load_result.dart`，加载结果类型与 stream completer 解耦。
- `WebPPlaybackController` 主循环已 helper 化，renderability/startup/null-frame 等等待逻辑独立。
- 已按行为/依赖边界拆分 pipeline/task scheduler：`pipeline/resource_entry.dart` 承载 policy/resource 数据，`pipeline/resource_manager.dart` 承载资源生命周期，`pipeline/tasks.dart` 承载任务执行，`pipeline/task_scheduler.dart` 只保留调度/迁移；`PrecreateTask` 已通过 holder factory 脱离 `WebPImageProvider` 直接依赖。
- 已按目录边界移动到 `pipeline/`、`decoder/`、`runtime/`、`cache/`、`io/`；通用文件去掉 `webp`，WebP 专用文件保留 `webp_` 前缀。
- 已开始非 `part` 拆分的真实重构：`WebPStreamDecodeCoordinator` 承载 pipeline 流式解码 attach/append/detach，`DownloadProgressPublisher` 承载当前页进度和速度采样。
- 已抽出 `DownloadRanker` 与 `PrefetchBudget`，下载评分和移动端/桌面预下载预算不再散落在 `PipelineController`。
- 已抽出 `PipelineWindowPlanner`，动态窗口/相对页码/跳页保护窗口计算从 `PipelineController` 分离。
- 已抽出 `PipelinePolicyApplier`，资源优先级与 `ResourcePolicy` 应用从 `PipelineController` 分离。

### Native Texture 渲染管道（动图卡顿根治）

- Stage 1 平台纹理管道已落地：`WebPTexturePlugin.kt`（SurfaceProducer create/update/dispose）、`webp_texture_blit.c`（JNI + ANativeWindow 从 native 帧地址直接 memcpy 进 Surface）、`webp_texture_channel.dart`（MethodChannel 侧）、CMake 编译 blit 并链接 `android`/`log`、MainActivity 注册插件并在 `cleanUpFlutterEngine` 调 `disposeAll`。
- Stage 2 接入真实解码帧已落地：Android 端 `PipelineController` 选 `NativeTextureRenderer(AndroidWebPTextureBackend())`，其余平台用 `FlutterImageRenderer`；`AndroidWebPTextureBackend.submit` 用 `NativeFrameHandle.detachAddress()` 把 native RGBA 帧所有权移交 `NativeAddressFrameHandle`，使上传任务的 `frame.release()` 变 no-op、帧存活到显示层按播放节奏上传；completer `_pump` 按帧 duration 取帧、`_presentTextureFrame` 惰性建纹理并 blit，像素字节不进 Dart、不经 MethodChannel 序列化。
- Stage 3 显示层改造已落地：`WebPTextureRegistry`（fullKey→`WebPTextureInfo` 侧通道）+ `ComicImage` 用 `ValueListenableBuilder` 监听同一 fullKey，有纹理渲染 `Texture(textureId)`、否则回退 `RawImage`；静态/非 WebP/fallback 仍走 `ui.Image`/generic codec 路径。
- Stage 4 预加载策略：运行时目标（近邻页不抢当前页解码核）由 completer `_pump` 的 gate 达成——近邻页屏外不播放→不消费帧→不重解，`decodeDispatch.near` 播放期归零；未采用「near 页完全不解码」的字面实现，改用 `FrameDepthTable` 水位背压（近邻预解少量帧换翻页秒回，已验证体验），近邻帧目标数组由用户定档。
- Stage 5 回归与收口已完成：单测全绿（22/22）；重写 `resource_policy_test.dart`（原断言 `frameTarget`/`renderedFrameTarget`/`allowPlayback` 等重构后已删字段，改为校验当前 `ResourcePolicy` 授权表）；`WebPPerf.enabled`/`timeline` 置 false，诊断埋点零开销、不再刷 logcat（复测置 true 即恢复，整文件可删）；临时测试页 `webp_texture_test_page.dart` 已移除、无悬空引用；`flutter analyze` 无新增问题、profile APK 端到端构建通过。

## 关键决策

- WebP 阅读器不是视频播放器模型；不同 WebP 高频切换，因此不采用全局 FrameQueue 作为主抽象。
- 保留每个 WebP 自己的 FrameBuffer；holder 将收窄为帧输出，不再拥有 stream/download/native input 状态。
- `FrameQueue` 只可作为内部 raw-frame 管道，不作为播放器对外模型。
- source/decode/renderer 使用稳定接口；Native Texture 作为最终高性能 renderer backend，不得要求重写前两层。
- detach 仅表示 lease/demand 撤销；pause、retain、evict 由 session reconciler 统一决定。
- Dart 网络 chunk 直接复制一次到最终 native-owned storage，不建设临时 Dart ByteStore。
- UI 进度显示应暴露真实状态，不用显示层平滑掩盖 cache/resume 问题。
- Running download 离开窗口后应继续下载；只有并发压力下才按 rank 被高优任务抢占。
- 动图卡顿根治采用 native texture 而非缓存全部解码帧：原架构无逐帧清理导致内存崩溃，流式逐帧释放不可回退；native 帧地址经 JNI 直读 blit，UI isolate 不再做每帧 ~10MB 整块拷贝 + setState。
- 近邻页屏外不播放由播放泵 gate（`decode.isCurrent`）实现，且循环用 poll-continue 不 return——复刻重构前 `WebPPlaybackController._run` 死循环行为，翻页 current 标志未同步时也能自恢复，避免 return 版一停即冻死。

## 未完成的代办

1. 将现有网络下载迁移到唯一 DownloadSession/NativeWebPSource，并以 committedLength 作为 Range resume 唯一偏移。
2. 将 pipeline policy 接入 DownloadSession/DecodeSession demand lease。
3. 收窄 holder、迁移 visible display lease，删除 owner/history replay/resume 双路径。
4. 完成 source/cursor Android 设备级增量解码与并发 append 回归。
5. ~~在稳定 renderer 接口后实现 Android NativeTextureRenderer。~~ 已完成（见「Native Texture 渲染管道」Stage 1-5）。
6. 本轮改动（`resource_policy_test.dart` 重写 + `WebPPerf` 埋点关闭 + progress.md）尚未提交。
