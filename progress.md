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

## 关键决策

- WebP 阅读器不是视频播放器模型；不同 WebP 高频切换，因此不采用全局 FrameQueue 作为主抽象。
- 保留并强化每个 `DecoderHolder` 自己的 FrameBuffer / raw frame queue / streaming state。
- `FrameQueue` 只可作为内部 raw-frame 管道，不作为播放器对外模型。
- 完全 Native Texture 播放器是长期可选 renderer backend，不作为当前第一阶段重构目标。
- 第一阶段重构只做 `part/part of` 文件拆分，保持行为不变，避免 private API 大量 public 化。
- UI 进度显示应暴露真实状态，不用显示层平滑掩盖 cache/resume 问题。
- Running download 离开窗口后应继续下载；只有并发压力下才按 rank 被高优任务抢占。

## 未完成的代办

1. 继续按行为边界收窄 `PipelineController`：下一步优先拆出 work submission。
2. 继续按行为边界收窄 IO：`image_loader.dart` 仍包含 disk cache 读取，后续可评估 cache/file/network loader 的接口收敛。
3. 在行为稳定后评估 Android-only `NativeTextureRenderer` 原型。
4. 对快速切页、拖动 slider、退出 reader 再进入、慢速 WebP partial 播放进行回归测试。
