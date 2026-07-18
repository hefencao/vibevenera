# Comic Translation Architecture

> 当前架构，更新于 2026-07-17。漫画翻译是 Reader 图片管线的旁路消费者，
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
OCR 行/列先以字号×字符数重建逻辑文字矩形，再结合 bubble、背景、主/副轴接触和归一化距离合并为翻译 unit。远程模型联合理解整个 unit，再返回与
`regionIds/sourceLines` 等长且一一对应的译文数组。译文分别写回原 region，不再只放在 anchor region。
纯标点/无意义字符不进入远程请求。拟声词默认不翻译，用户显式开启后才进入 unit；该选项参与
translation cache key。Reader 将 clean overlay 裁剪到实际有译文的 region mask；跳过的拟声词等区域保留原文，
不会因一个跳过区块而放弃其他区域的原生修复。
协议和用户追加提示词的版本摘要纳入 translation cache key。OpenAI-compatible client 在 translator
load/unload 生命周期内复用连接，不再逐页重建。

跨页 batch 不应通过翻译模块另开图片下载连接。翻译开启时，翻译 policy 把图片管线的有效
预载下限提高到 4，并最多向现有 session 提交后续 4 张静态图；输入解析器仍只消费已封口的
完整缓存，不创建下载连接，也不改变设置中的下载线程上限。这只能把图片等待和 OCR 提前，
不能提高串行远程服务的稳态吞吐：远程单页经常需要 10 秒时，快速翻页仍会追上预取窗口。
后续批处理应拆成单路 OCR
准备队列和单路远程队列：当前页 OCR 完成后立即发送，不等待凑批；远程请求进行时顺序 OCR
已缓存的近邻静态页，再把已准备的 3～4 页机会式合并到下一次请求。这样不会增加当前页首屏
等待或 OCR 并发内存，也不会绕过图片下载的 rank、并发和驱逐策略。动图仍不进入该预取/batch。

查看原文不切换 session：Reader 现有单击判定在排除双击、长按和拖动后查询译文气泡命中，
只隐藏该气泡 1.5 秒后恢复。Overlay 本身保持 `IgnorePointer`，不会从气泡区域抢走翻页或缩放手势。

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

查询 translation 时先命中完整 key；若 Reader 刚重建、当前还没有前页内存上下文，则回退到
`OCR digest + engine/model + target language` 相同的最近 artifact。上下文参与首次翻译，但不应因
Reader session 销毁后无法重建完全相同的运行时上下文而重复请求远程模型。

因此 CDN authority 改变、版本迁移或页码偏移不会误使结果失效。OCR 与目标语言解耦；
切换翻译语言只重做翻译。SQLite 保存结构化区域、文字和稀疏透明 clean-overlay PNG；后者只含
文字 mask 内的修复像素，不保存整张原图，也不重复写入 translation artifact。
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
- current 高于 near；空闲时最多预处理后续 4 张物理图片，对应图片预载下限也是 4；
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
- OCR detector 产生的 region 是文字边界而不是语义分组。Dart 侧先估算
  `sqrt(OCR area / character count)` 字号，使用 source mask 的副轴墨迹中心、OCR 主轴中心和
  `font size × character count` 主轴长度重建逻辑矩形；不回退到带大量空白的 OCR 矩形做关系判定。
- unit 关系分两个互补分支：`sameBand` 处理副轴重叠足够的同行/列碎片；
  `adjacentBand = !sameBand` 处理相邻行/列，必须同时通过连续的加权距离、主轴重叠/端点接触和气泡边界检查。
  两分支不得使用不同门槛将一段数值区间同时排除。合并边按距离排序，任意成员存在方向分离冲突时拒绝连通分量合并；
  bubble ID 只提供容器语境，不强制合并。
- unit 与 band 是两层语义：同一气泡的多列属于同一 unit，但仍是多个 band。band 仅在逻辑矩形副轴重叠
  `>= 0.45` 或中心距离 `<= 0.55 × 主字号` 时合并。unit 内存在多字正文时，单字本身不对横/竖排投票，而是继承正文；
  整个 unit 都是单字时仍使用矩形方向，无有效几何多数时再使用语言默认方向。
- engine 将 unit id、region order、band index 和 unit orientation 写入 translation artifact，overlay 只消费该结果，
  不在绘制阶段重新分组。source band 是排版先验，不是译文的强制容器；bubble 的安全内接区域才是硬边界。
- 每个 bubble block 枚举保持句序的连续 band 合并方案；每种方案同时评估贴近原 band 的 anchored lane 与在
  bubble 内重新分配的 distributed lane。对每个方案以目标字体真实 glyph/paragraph 测量候选字号、横排换行数
  或竖排换列数，最小化“目标墨迹面积相对源面积及字符数变化”“源字号偏差”“列/行拓扑偏差”和“位置偏差”的加权
  代价。这样会优先尊重原排版，但在译文长度或气泡空间需要时允许换行、换列或合并句子，而不是把译文硬塞进 OCR 框
  或无条件铺满气泡。若译文行/列数少于 source band，且候选通过缩小字号才不断行/列，两者作为联合惩罚，
  避免将原本均衡的两列压成小字单列。解析出的 plan 按显示矩形缓存在 painter，滚动重绘不重新测量。
- 联通气泡只将 OCR 区块中心分配到已经分离的距离核心，不再使用文字位置聚类创造拆分。气泡候选降低最低
  凸包实度以接纳凹形轮廓，普通近凸气泡仍不执行 Voronoi 拆分。
- 排版方向以 OCR polygon 的宽高关系重新确认，竖向区块不会因为识别方向阈值过高而进入横排。
- Reader session 汇总同一漫画已完成区块的源/目标长度缩放值作为字号先验；它不是字号上限。
  源字号按 `sqrt(OCR box area / source character count)` 估算，同一 band 的碎片先合并成一句译文，再参与
  候选排版评分，避免包含两列文字的宽 OCR box 被误当成双倍字号。
- 远程配置支持保存多组 endpoint/model/prompt/API key 并即时切换；API key 仍只写入本机 secrets 文件。
- 一页远程翻译按完整气泡 unit 分批，每批最多 16 个 unit/960 个源字符，并发 2 批；普通漫画页通常只发一个请求，单个 unit 不拆分。
  不限制 completion token，避免兼容接口的隐藏推理占满预算后返回空正文。benchmark 记录每批耗时、unit 数、字符数和原始响应，
  用于区分连接延迟与大请求的模型生成/排队延迟。
- 当前翻译协议要求整批 JSON 与逐 region 一一对应，且实测慢模型约 94% completion token 是正文前的隐藏推理；仅打开 SSE
  不能让这些模型在一秒内产生可显示译文。流式显示需要后端支持按 unit 输出 NDJSON/SSE，并在 session 增加 partial artifact，
  因此不以破坏原子缓存和排版一致性的方式直接设置 `stream=true`。完整 OCR/translation artifact 已按内容、模型、语言和上下文缓存；
  短句级缓存会忽略人物、语气和上下文，暂不作为正确性缓存。内建 prompt 保留输出协议所需规则但已压缩；不设置固定
  `max_tokens`，避免推理模型把预算消耗在隐藏 reasoning 后返回空或不完整 JSON。
- 长条页分 tile 时先给 group id 加 tile namespace，合并结果后再以背景色和重叠轮廓对跨 tile 的
  同一气泡去重，避免一个跨分块气泡被拆成两段。
- 竖排区块保持从右到左分列；排版按目标字体的实际 glyph 宽高测量，不以源文字数或
  `fontSize` 近似目标字符尺寸；每一列按自身字数居中，首行/首列也必须落在安全矩形内。
- OCR 后从文字四边形外环采样局部背景色。气泡候选仍来自背景连通域，但必须通过搜索边界、
  文字/候选面积比、尺寸比、紧致度、实心度和凸包实度检查；大面积页面底色、分格框和线稿封闭区
  默认拒绝。bubble polygon 只用于分组、求内侧排版范围和最终裁剪，不再承担擦除。
- 擦除在每个 OCR 四边形周围逐像素比较局部背景色；轮廓经 `3×3 close + 5×5 dilate`，
  最终区域可超出 OCR quad 约 2 分析像素，以覆盖抗锯齿边缘。原生端以这些 mask 一次性执行
  OpenCV Telea inpainting，并输出与分析图同尺度、其余像素透明的 clean overlay；Reader 先合成
  clean overlay 再画译文，因此渐变和纹理不再被单色块替换。没有可靠像素 mask 时以 OCR quad
  作为修复 mask，而不是让原文完整残留。未膨胀的强前景像素仍用于采样译文字色。
- 原生 OCR 在 bubble 分割后剔除“低置信度、无 bubble、且与其他文字不构成空间组”的孤立 region；它们既不进入
  OCR artifact/远程请求，也不写入 clean overlay，避免眼睛、线稿等误识别被擦除或翻译。
- OCR 主检测后会用轻量全局轮廓扫描寻找“未包含任何 OCR 中心、内部存在文字笔画”的浅色闭合
  气泡，只对这些候选 crop 做一次二次 OCR；正常页没有候选时不会增加 ONNX 推理。该路径补回
  完全漏检的常见白色气泡，但不覆盖彩色/无边框气泡、框外旁白或艺术字。benchmark 显示
  proposal 时间、候选/补回数量和 clean-overlay PNG 大小，便于直接发现误检与性能退化。

后续 learned balloon detector 仍用于覆盖彩色、开放轮廓和复杂艺术气泡；当前 clean patch 是
传统 inpainting，不是生成式语义补全。

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
- 实际 recognizer，检测框/非空原始解码/阈值接受数量，区域数量、唯一气泡数、源文字 mask 数、
  逐区 group id/OCR 置信度、OCR 原文和翻译结果、气泡补检候选/补回数量及 clean patch 大小；
- 模型加载、检测总输入像素及每个 tile 的 tensor shape、释放后 RSS，以及每页任务前后 RSS。
  RSS 均为整个进程的边界采样，不代表 OCR 推理瞬时峰值。
- 每个 region 的 unit/order/band/orientation，以及 `Split diagnostics` 和 `Merge diagnostics`。
  前者输出同一 native bubble 却分属不同 unit 的失败关系，后者输出实际促成同 unit 的 related 边，
  包含逻辑矩形、字号、副轴距离/重叠、主轴接触、边界可靠性和方向冲突，用于在调参前确定真正生效的分支。

真机结果显示高性能设备的 OCR P50 约 0.5 秒，旧设备约 2.4 秒。任务仍保持单路后台
执行，不为追求吞吐增加并发。普通页默认以 1600 长边为准确率基线，但实际值来自每次
`ComicOcrInput`。只有整页缩放后的宽度低于最低有效分析宽度时才分块；tile 高度按该宽度
动态计算，重叠不超过 128 分析像素并按检测框中心去重。1080×3055 默认保持单 tile，极长页
才以少量较高窗口保留文字宽度，避免固定 1600 高窗口把检测输入放大数倍。首轮 RSS
上升后趋于稳定不是逐页泄漏，但瞬时
占用仍偏高，因此检测预处理改为从 8-bit Mat 直接生成 CHW tensor，移除
float Mat、通道 Mat 和逐通道数组的重复副本；Bitmap 已是 ARGB8888 时也不再复制。

候选顺序：

1. PP-OCRv6 small det/rec：中文、英文、日文和拉丁字母语言的移动端主候选；其通用 recognition
   不包含韩文；
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
learned balloon detector、用户校正、拟声词和动图实际分析。OCR 引擎未注册时 UI 明确报告模型
未安装，不进行网络回退。
