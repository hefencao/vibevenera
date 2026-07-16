# Comic Translation Architecture

> 初始架构，更新于 2026-07-15。漫画翻译是 Reader 图片管线的旁路消费者，
> 不属于下载、WebP/GIF 解码或 present 管线。

## 1. 边界

```text
ReaderPageLayer
├─ ComicImage / native Texture                     原始显示层
└─ TranslationOverlay                              独立文字层
          ^
          |
ComicTranslationSession                            页面策略/串行调度
    ├─ ComicTranslationInputResolver               只读完整缓存
    ├─ ComicOcrEngine                              可插拔本地 OCR
    ├─ ComicTextTranslationEngine                  可插拔本地/远程翻译
    └─ ComicTranslationStore                       内容寻址旁路缓存
```

设置中的“翻译模型与 API”是模型、远程后端和 benchmark 的统一入口。远程翻译当前提供
OpenAI-compatible Chat Completions adapter；endpoint、model 可配置，API key 单独写入
本机 `comic_translation_secrets.json`，不进入 appdata、数据同步或翻译 artifact。

Android 本地 OCR 使用独立 `ppocr-sdk` module。Flutter 侧模型管理器负责断点续传、固定
长度/SHA-256 校验和原子发布；原生侧使用单线程 worker 加载 ONNX session、采样图片并执行
PaddleOCR。MethodChannel 不传原图字节，也不在 Android platform 主线程推理。

强制规则：

1. 翻译不得改变图片 provider identity，不得重建下载或播放 session。
2. OCR 不得读取 native WebP 播放 cursor、holder 或 GIF runtime。
3. OCR/翻译不运行在 Flutter UI isolate 或 Android platform 主线程。
4. 没有可用本地后端时不得静默改用远程服务。
5. 图片先显示；翻译状态只局部更新对应页的 overlay。

## 2. 内容身份与分层缓存

图片 URL 和 page index 都不是翻译缓存身份。`InputResolver` 在已有完整缓存文件上计算
SHA-256，并保存文件尺寸/修改时间到摘要的映射：

```text
OCR key = contentDigest + OCR engine/model + source language
Translation key = OCR digest + translation engine/model + target language
                  + context digest
```

因此 CDN authority 改变、版本迁移或页码偏移不会误使结果失效。OCR 与目标语言解耦；
切换翻译语言只重做翻译。SQLite 只保存结构化区域和文字，不保存原图。
Reader 内仅关闭再开启翻译时保留当前 session 的 ready artifact，不重新 OCR 或请求远程翻译；
源/目标语言、模型或上下文确实改变时仍按上述 key 生成新 artifact。

当前容量策略：

- page-content 映射 8192 条；
- OCR artifact 2048 条；
- translation artifact 4096 条。

数据库在独立常驻 isolate 中串行访问，Reader 不同步等待 SQLite I/O。

## 3. 调度

`ComicTranslationPolicy` 单独定义翻译行为，不复用下载 policy 参数：

- 同时只执行一个页面任务；
- current 高于 near；空闲时最多预处理下一逻辑页；
- dragging/continuous scroll 提交延迟 180ms；
- 松手、settling、jumping 立即提交；
- 正在执行的任务完成后保存结果，离开 viewport 只清理尚未开始的垃圾任务。

完整图片尚未 promote 时状态为 `waitingForImage`。`CacheManager.changes` 在原子写入或
promote 完成后发布具体 cache key，翻译 session 据此继续，不轮询目录、不使用人为等待。
WebP 在完整 artifact 上按 RIFF chunk 检查 `ANIM/ANMF`，不因扩展名或漫画源曾出现动图
而误伤静态 WebP；GIF 当前保守归为动图。

## 4. 文字层

`_ReaderTranslationLayer` 位于 `PhotoView` 变换内部：

- 坐标使用相对原图的归一化多边形；
- `BoxFit.contain` 与每张图自身 alignment 决定显示矩形；
- overlay 有独立 `RepaintBoundary`；
- 动图 Texture 更新不重绘文字；
- artifact 通过每页 `ValueListenable` 发布，不调用 Reader `setState`；
- 只有共享同一气泡轮廓的 OCR 行/竖列才按气泡合并；有气泡与无气泡、两个不同气泡不会再按
  距离误合并。仅无气泡轮廓的相邻文字继续按主轴重叠合并。翻译文字在区块内重新换行，
  同一区块只使用一个字体大小。字号同时受气泡实际内侧安全矩形、原文字号及源/目标文字量比例约束；
  较短的中文译文可以适度放大，但不会无限填满整个气泡。
- 竖排区块保持从右到左分列；排版按目标字体的实际 glyph 宽高测量，不以源文字数或
  `fontSize` 近似目标字符尺寸；每一列按自身字数居中，首行/首列也必须落在安全矩形内。
- OCR 后从文字四边形外环采样局部背景色。气泡候选仍来自背景连通域，但必须通过搜索边界、
  文字/候选面积比、尺寸比、紧致度、实心度和凸包实度检查；大面积页面底色、分格框和线稿封闭区
  默认拒绝。bubble polygon 只用于分组、求内侧排版范围和最终裁剪，不再承担擦除。
- 擦除改为在每个 OCR 四边形内逐像素比较局部背景色，经闭运算和一次膨胀得到源文字轮廓；
  overlay 只替换这些文字像素对应的小轮廓，绝不再填满整个气泡或回退涂抹 OCR 外接矩形。
- 无闭合轮廓、渐变或纹理背景仍可能无法得到扩大后的排版空间；像素文字 mask 仍可独立工作。
  OCR 完全漏检的气泡无法由 OCR-box 驱动的分割补回，仍需全局 balloon detector 后做二次 OCR。
  MVP 继续跳过拟声词。

后续 learned balloon detector 与纹理背景 inpainting/clean patch 仍属于 layout/render artifact。

## 5. 动图扩展点

动图翻译已经进入数据协议，但当前明确不执行：

- `ComicTranslationMediaKind.animatedImage`；
- `AnimatedTranslationMode.posterFrame/keyframes`；
- 每个文字区域可带 `AnimatedFrameSpan`；
- OCR engine 声明 `supportsAnimatedPosterFrame`；
- 当前 session 对已确认动图发布 `unsupportedMedia`。

未来实现必须增加独立只读 frame sampler，从完整 artifact 生成代表帧/关键帧。它不能
共享播放 source、cursor 或 epoch。静态 overlay 可扩展为按播放时间筛选 `frameSpan`，
不需要更改图片管线。

## 6. 模型验证顺序

`ComicTranslationBenchmark` 已提供统一测量入口，记录：

- OCR/翻译模型加载耗时；
- 输入解析、检测预处理/推理/后处理、识别预处理/推理/后处理和翻译耗时；
- 区域数量、成功气泡数、源文字 mask 数、逐区 OCR 置信度、OCR 原文和翻译结果；
- 模型加载、边界采样最大值、释放后 RSS，以及每页推理前后 RSS。

真机结果显示高性能设备的 OCR P50 约 0.5 秒，旧设备约 2.4 秒。任务仍保持单路后台
执行，不为追求吞吐增加并发。普通页以 1600 长边为准确率基线；若整页缩放后的宽度会低于
900 分析像素，则按保留文字宽度的 1600 高窗口分块，窗口重叠 256 分析像素并按检测框中心
去重。因此 1080×3055 页面不再因未达到旧的 3:1 比例而错误地只运行一个 tile。首轮 RSS
上升后趋于稳定不是逐页泄漏，但瞬时
占用仍偏高，因此检测预处理改为从 8-bit Mat 直接生成 CHW tensor，移除
float Mat、通道 Mat 和逐通道数组的重复副本；Bitmap 已是 ARGB8888 时也不再复制。

候选顺序：

1. PP-OCRv6 small det/rec：日文漫画的移动端主候选；
2. PP-OCRv5 mobile det/rec：兼容性和日文准确率基线；
3. 手动指定韩文时切换到 `korean_PP-OCRv5_mobile_rec`；切换时释放前一个 recognition session，
   不让两套 ONNX recognition 权重同时常驻；
4. 本地 Marian/Bergamot 与显式远程翻译后端。

PP-OCRv6 tiny 先只作为体积/速度基线；其日文覆盖和漫画竖排准确率必须以实际模型包验证，
不能仅凭通用 OCR 指标作为默认模型。

必须在低、中、高端真机上以同一漫画样本比较 P50/P95、峰值 RSS、温升，以及推理期间
WebP/GIF frame timing。验证前不把某个未经实测的 Flutter OCR 插件固定进核心架构。

## 7. 当前实现状态

已完成：旁路模型、内容寻址数据库、独立调度、缓存完成事件、Reader overlay、设置入口、
动图协议、Android PaddleOCR runtime、应用内模型下载和 benchmark harness。

已提供 OpenAI-compatible 远程翻译 adapter。未完成：iOS/桌面 OCR runtime、本地文本翻译、
独立 balloon detector、用户校正、拟声词和动图实际分析。OCR 引擎未注册时 UI 明确报告模型
未安装，不进行网络回退。
