# Comic Translation Architecture

> 当前架构，更新于 2026-07-19。漫画翻译是 Reader 图片管线的旁路消费者，
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

设置中的“翻译模型与 API”是模型、远程后端和 benchmark 的统一入口。远程翻译提供
OpenAI-compatible Chat Completions 和 DeepL adapter；配置 profile 带 backend 身份，避免把
OpenAI endpoint/model 解释为 DeepL 配置。endpoint、model 可配置，API key 单独写入
本机 `comic_translation_secrets.json`，不进入 appdata、数据同步或翻译 artifact。
OCR 行/列先以字号×字符数重建逻辑文字矩形，再结合 bubble、背景、主/副轴接触和归一化距离合并为翻译 unit。远程模型联合理解整个 unit，再返回与
`regionIds/sourceLines` 等长且一一对应的译文数组。译文分别写回原 region，不再只放在 anchor region。
纯标点/无意义字符不进入远程请求。拟声词默认不翻译，用户显式开启后才进入 unit；该选项参与
translation cache key。Reader 将 clean overlay 裁剪到实际有译文的 region mask；跳过的拟声词等区域保留原文，
不会因一个跳过区块而放弃其他区域的原生修复。
协议和用户追加提示词的版本摘要纳入 translation cache key。DeepL 每个气泡 unit 作为一个
`text`，只在客户端保留 unit ID，按响应数组顺序映射回原 unit；一个气泡的 OCR 行联合翻译，
再按保留的原文权重分配回 region。两种 client 都在 translator load/unload 生命周期内复用连接，
不再逐页重建。

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

OCR 与本地文本翻译的模型生命周期已拆开：`ComicOcrModelManager` 只管理 PaddleOCR，
`ComicLocalTranslationModelManager` 管理按源语言集合/目标语言安装的 CTranslate2 INT8 包。本地文本引擎通过
独立单线程 MethodChannel 调用 CTranslate2 + SentencePiece；同组 OCR 行/列先按阅读顺序组成一个 unit，
以换行保留原分段并作为一个 batch item，绝不逐 region 调用模型。返回值
按请求顺序映射，不向模型发送 region/unit ID，也不经过 JSON 协议。选择策略优先直连 pair，否则使用
`ja/ko→zh-CN` 多源直连 SMaLL-100；仅当未安装直连模型时才允许完整枢轴链路。插件在同一个 worker
内按 model key 保持 native handle，不会在切页时反复卸载。简中结果先统一繁转简，繁中目标再走现有
OpenCC 字符转换。本地模型不使用
跨页 prompt，因此不会因前页上下文改变重复生成缓存；远程 OpenAI-compatible/DeepL 继续声明
`previousPages` 能力并保留原有上下文语义。

多语模型的语言前缀是词表 token。native 必须先用 SentencePiece 编码正文，再将
`sourcePrefixTokens` 原样插入 encoder token 序列，并通过 CTranslate2 `target_prefix` 传入
`targetPrefixTokens`。decoder 返回后先精确移除该前缀再做 SentencePiece 解码。禁止把语言 token 拼进
字符串交给 SentencePiece；否则会被拆成普通/未知片段并直接污染译文。beam 由 schema v4 模型包声明，
不再硬编码为 2。

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

翻译 engine 不再暴露一个与请求无关的固定 model version，而是通过 `identityFor(request)` 返回
实际直连/枢轴链路中全部模型的身份、权重摘要、源/目标前缀、EOS 和 beam。`contextMode=none` 的本地 engine 使用
空上下文及稳定摘要；声明
`previousPages` 的远程 engine 才读取、散列和发送前页内容。这样同一个动态本地 backend 切换
`ja→zh-CN` / `ko→zh-CN` 时不会串用 artifact，也不会把无效上下文变体写入数据库。

查询 translation 时先命中完整 key；若 Reader 刚重建、当前还没有前页内存上下文，则回退到
`OCR digest + engine/model + target language` 相同的最近 artifact。上下文参与首次翻译，但不应因
Reader session 销毁后无法重建完全相同的运行时上下文而重复请求远程模型。

translation artifact 同时持久化 unit 成员、顺序、band 和方向，overlay 的内存布局缓存不
持久化。读取 artifact 时必须将这四项与当前 grouping 结果逐项核对；仅有相同 unit 成员并不
足以复用旧排版元数据。该契约版本参与 translation model key，grouping/overlay 契约变化时
旧 artifact 会失效。设置中的“清除缓存”同时清空翻译 SQLite，并 checkpoint/VACUUM 回收文件。

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
- OCR detector 产生的 region 是文字边界而不是语义分组。Dart 侧以副轴墨迹宽度为基础；bubble
  正文再结合 `主轴长度 / 字符数` 的字符步进估算字号，避免正常正文仅因字形较窄而被当作小字。两项按
  几何均值平滑组合，不对输出字号做事后钳制。随后使用 source mask 的副轴墨迹中心、OCR 主轴中心和
  `font size × character count` 主轴长度重建逻辑矩形；不回退到带大量空白的 OCR 矩形做关系判定。
- unit 关系分两个互补分支：`sameBand` 处理副轴重叠足够的同行/列碎片；
  `adjacentBand = !sameBand` 处理相邻行/列，必须同时通过连续的加权距离、主轴重叠/端点接触和气泡边界检查。
  两分支不得使用不同门槛将一段数值区间同时排除。合并边按距离排序，任意成员存在方向分离冲突时拒绝连通分量合并。
  原生 bubble group 只是弱证据：相同 ID 只提供方向、字号和候选关系语境，不强制合并；不同 ID 也不再直接拒绝关系。
  分格线、人物/气泡交界线可能把一个联通气泡切成多个原生 group，韩文条漫对此尤其敏感，因此其 ID 权重进一步降低，
  最终仍由重建文字矩形、背景、主/副轴接触和可用 bubble 几何共同决定关系。局部背景采样也只是权重而非硬拒绝，
  允许被分界线切断或跨过渐变背景的相邻正文保持连通；同一 bubble 内与正文无副轴接触的远距离单字则使用更窄的接触上限，
  避免气泡边缘符号仅凭主轴端点重叠并入正文。
- unit 与 band 是两层语义：同一气泡的多列属于同一 unit，但仍是多个 band。band 仅在逻辑矩形副轴重叠
  `>= 0.45` 或中心距离 `<= 0.55 × 主字号` 时合并。unit 内存在多字正文时，单字不单独投票而继承正文；
  整个 unit 都是单字时仍使用矩形方向，
  无有效多数时再使用语言默认方向。
- translation artifact 只持久化 OCR、译文和修复素材，不再写入 unit/order/band/orientation 等排版元数据。
  overlay 在每个图片 widget 的 `_TranslationLayoutCache` 内按当前 grouping contract 解析 block，随图片生命周期释放；
  翻译文本仍可跨 Reader session 复用，但改排版算法不需要修改远程模型版本或重新请求翻译。
  source band 是排版先验，不是译文的强制容器；bubble 的安全内接区域才是硬边界。
- 每个 bubble block 枚举保持句序的连续 band 合并方案；每种方案同时评估贴近原 band 的 anchored lane 与在
  bubble 内重新分配的 distributed lane。对每个方案以目标字体真实 glyph/paragraph 测量候选字号、横排换行数
  或竖排换列数，最小化“目标墨迹面积相对源面积及字符数变化”“源字号偏差”“列/行拓扑偏差”和“位置偏差”的加权
  代价。这样会优先尊重原排版，但在译文长度或气泡空间需要时允许换行、换列或合并句子，而不是把译文硬塞进 OCR 框
  或无条件铺满气泡。若译文行/列数少于 source band，且候选通过缩小字号才不断行/列，两者作为联合惩罚，
  避免将原本均衡的两列压成小字单列。排版枚举和 `TextPainter.layout` 不在 `CustomPainter.paint`
  内执行：overlay 获得显示尺寸后，以 idle scheduler 每次只执行一次字号测量；二分搜索、候选字号和 block
  之间都可被下一帧或输入抢占，不将一个 block 换成 Paint 之外的 UI isolate 长任务。最终 glyph/paragraph 的
  `TextPainter`、offset、mask path 和 bubble geometry 同样在 idle task 中准备；同一 OCR region 的全部 mask polygon
  先合并为一个 path，不按每个轮廓拆成独立 idle task。`paint` 只提交已缓存的绘制命令。
  每个完整 block 发布后更新同一个 repaint notifier；文字 painter 和 clean-overlay clipper 同时监听它，clipper
  直接读取已完成的 region id，因此无需页面 `setState` 就能渐进显示对应修复层和译文，也不会暴露半个 block。
  plan cache 在 clean-overlay 解码完成、查看原文及颜色变化导致 painter 重建时继续复用；颜色变化只重建绘制命令，只有 artifact、字号比例或显示矩形变化才重算排版。
- 联通气泡只将 OCR 区块中心分配到已经分离的距离核心，不再使用文字位置聚类创造拆分。气泡候选降低最低
  凸包实度以接纳凹形轮廓，普通近凸气泡仍不执行 Voronoi 拆分。
- overlay 在图片生命周期内重新解析空间分组和方向，不消费持久化 unit orientation。方向由当前 source mask 的实际宽高、
  OCR 方向和正文字符票共同计算；因此更改排版逻辑不受旧 translation artifact 影响。
- Reader session 以本次阅读首个完成的 current artifact 汇总源/目标长度缩放值，作为整个 session 稳定的
  字号先验；后续预翻译页不再改写该值，避免每完成一页就使所有可见 overlay 失效并重排。它不是字号上限。
  源字号使用与 engine 相同的“副轴墨迹宽度 + 正文字符步进”估算，同一 band 的碎片先合并成一句译文，再参与
  候选排版评分，避免包含两列文字的宽 OCR box 被误当成双倍字号。若小模型只从一条正文识别出部分字符，使用
  `主轴墨迹长度 / 副轴字符尺寸` 补足几何字符数，避免把漏识别后的整行长度除以一个字符而高估字号。
  中日韩方形字形的短行不能直接使用 `主轴长度 / 字符数`：以副轴字符尺寸扣除一个首尾字形后，再按
  `字符数 - 1` 估算中心步进，消除短句比长句系统性偏小的页间差异。
  字号搜索仍枚举完整可容纳区间，避免原字号虽然勉强能放下却越出气泡。正文从可容纳候选中选择接近
  `本 block 源字号 × session 统一缩放比例` 且处于 `1/1.15–1.15×` 的方案，没有可用方案时才回退完整搜索结果。
  不能再把整页正文钳制到同一个绝对字号：统一的是缩放比例，不是字号本身，否则会破坏原图的大/小字层级。
  艺术字、明确拟声词等非正文不钳制。
  但全页均为短句时，本页 OCR 无法自行发现一致的源字号低估。Session 因此按图宽保存至少四字符正文的归一化
  源字号，以有效字符数加权中位数作为跨页普通正文下限；只抬升低于基准的正文，不压低原本的大字。约束空间
  放不下该基准时仍由 fit 搜索回退，从而保留刻意的小气泡文字。
- 未被 bubble 分割覆盖的文字不会再因“偏大”“倾斜”或“片假名”任一单项证据就被推断为拟声词；
  自动排除至少需要两项证据同时成立，并且只在 unit 合并后判断。模型未直接输出可靠语义类别前，不在合并前按 region
  猜测并删除拟声词，避免一次误判使正文断裂；进一步的非模型拟声词推断暂缓。
- bubble 轮廓只有在能形成有效内接排版区域时才作为硬裁剪；联通尾部、开放或错误合并的轮廓若把
  内接矩形压缩得小于原文占用范围，或候选不能覆盖每个 region 的文字墨迹核心，会改用完整原文区域锚定排版，
  而不是把四行正文挤进局部轮廓、把气泡边缘大字缩小，或把已有译文 block 静默标记为 skipped。
  grouping 完成后不再只取 block 中面积最大的单个 region 轮廓，而是对全部有效 bubble polygon 做 path union，
  再以合并后的边界重新检查全部文字核心并求内接区域。联通气泡的两个分段轮廓因此不会因任选其中一段而退化到
  文字边界；只有合并边界仍不能覆盖正文时才使用开放区域。
  `g-` 只表示 native 没有确认 bubble id，仍与其他 OCR 一样参加 Dart 的位置/字符/背景 grouping。native 会另行
  保留较宽松的浅色轮廓候选，但候选不反向覆盖文字分组结果。Dart grouping 完成后，若确认 polygon 不能形成
  有效边界，open block 会在约 1.5 个正文厚度的邻域内探索整页候选及其与确认轮廓的组合：先要求完整文字核心
  覆盖，再允许“中心在内且五个核心采样至少覆盖三个”的伪 open 边界。短文本、漏字及联通气泡的残缺/分段轮廓
  因此能在最终 group 上重新形成排版面积；仍无有效候选才退化到“原文框膨胀 0.7 字号”的开放区域。
  Reader 与 OCR benchmark 共用 `bubble_boundary.dart` 的同一探索器；benchmark 的 `Open boundary exploration`
  会列出初始 open group 的附近候选数、是否形成边界、候选来源及是否使用宽松覆盖，避免诊断与实际 overlay 分叉。
  浅色候选与正式 native 分割采用不同标准：正式分割始终使用原始像素；候选则对白色前景执行一次 `3×3 OPEN`，
  专门切断气泡边线小缺口形成的窄白色泄漏通道，把贯穿页面白底的伪 open 恢复为局部联通气泡。随后使用
  `RETR_CCOMP` 只接受白色连通分量，不把深色文字孔洞当成气泡。候选还必须在宽高两轴都比对应 OCR 框至少大
  15%，避免气泡外的大型拟声词字形成为候选；禁止对白色前景做 close，因为它会抹掉细气泡线并制造泄漏。
  候选的外接框只用于证明边界已恢复，不直接作为排版面积。联通气泡的葫芦形内接区域按宽度采样、独立二分
  高度，不能再从整个外接框等比缩小宽高；否则收腰在一轴上的限制会连带压缩另一轴，并错误回退到原文框。
  内接矩形必须在扣除边距后仍覆盖原文宽高，多个锚点之间也优先选择满足该条件的结果。
  有效 bubble 内接矩形可沿“原文中心→轮廓质心”最多移动一个原文字号，并在该范围选择面积最大的矩形；
  为目标字体争取换字形后的空间，同时限制译文从原位置漂移。
- 渐进准备的完成条件按当前 block key 逐项核对，并要求不存在进行中的 search/render；不能再用
  `prepared.length + skipped.length` 推断整页完成。字号二分搜索先实际找到一个可容纳译文的下界，
  不再假定 `2px` 必然可用；长条页中的窄气泡因此不会使 `_best` 为空、终止 idle 任务链并永久停在部分结果。
- 远程配置支持保存多组 endpoint/model/prompt/API key 并即时切换；API key 仍只写入本机 secrets 文件。
- OpenAI-compatible 一页翻译按完整气泡 unit 分批，每批最多 16 个 unit/960 个源字符，并发 2 批；普通漫画页通常只发一个请求，单个 unit 不拆分。
  不限制 completion token，避免兼容接口的隐藏推理占满预算后返回空正文。benchmark 记录每批耗时、unit 数、字符数和原始响应，
  用于区分连接延迟与大请求的模型生成/排队延迟。
- 当前翻译协议要求整批 JSON 与逐 region 一一对应，且实测慢模型约 94% completion token 是正文前的隐藏推理；仅打开 SSE
  不能让这些模型在一秒内产生可显示译文。流式显示需要后端支持按 unit 输出 NDJSON/SSE，并在 session 增加 partial artifact，
  因此不以破坏原子缓存和排版一致性的方式直接设置 `stream=true`。完整 OCR/translation artifact 已按内容、模型、语言和上下文缓存；
  短句级缓存会忽略人物、语气和上下文，暂不作为正确性缓存。内建 prompt 保留输出协议所需规则但已压缩；不设置固定
  `max_tokens`，避免推理模型把预算消耗在隐藏 reasoning 后返回空或不完整 JSON。
- DeepL 不要求模型生成 ID/JSON map：每批最多 50 个 `text`，并在编码后的请求体达到 DeepL
  128 KiB 上限前分批。响应数量必须与请求数量完全相同，随后按索引建立现有
  `ComicTranslationResult`。这消除了生成式 JSON 漏字段造成的整批失败，但不能补回 OCR 漏检、
  无意义文本过滤或错误分组造成的缺失。
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
- 原生 OCR 在 bubble 分割后仅剔除“低置信度、无 bubble、至多一个有效字符、且与其他文字不构成空间组”的
  孤立 region；它们既不进入 OCR artifact/远程请求，也不写入 clean overlay，避免眼睛、线稿等误识别被擦除或翻译。
  多字符对白不会因 bubble 漏分割而在此丢失；已检测到 bubble 的单字加标点短句也保留到翻译 unit。
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
- 每个 region 的 unit/order/band/orientation，以及统一的 `Relation diagnostics`。性能测试可只显示
  `related=true` 或 `related=false`，也可用一个条目编号查看它与全部条目的关系，或用多个编号限制待检查的条目对。
  输出包含逻辑矩形、字号、副轴距离/重叠、主轴接触、边界可靠性、native group 权重和方向冲突，
用于在调参前确定真正生效的分支。诊断关系一次性生成，也可完全关闭关系/边界诊断输出；结果过滤和条目筛选不重跑 OCR；可临时关闭翻译，
默认测试轮数为 1，避免关系排查重复执行昂贵 OCR/翻译。
性能测试还可绕过 OCR/分组，手动输入一个完整 unit，并显示枢轴每阶段的真实输入和输出，用于区分 OCR 输入、
分组、模型解码和译文回填问题。本地后端启用时默认运行翻译，其他后端默认仅 OCR。

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
4. 本地 CTranslate2 sequence-to-sequence（多源日/韩→中文直连优先）与显式远程翻译后端。

PP-OCRv6 tiny 先只作为体积/速度基线；其日文覆盖和漫画竖排准确率必须以实际模型包验证，
不能仅凭通用 OCR 指标作为默认模型。

必须在低、中、高端真机上以同一漫画样本比较 P50/P95、峰值 RSS、温升，以及推理期间
WebP/GIF frame timing。验证前不把某个未经实测的 Flutter OCR 插件固定进核心架构。

## 7. 当前实现状态

已完成：旁路模型、内容寻址数据库、独立调度、缓存完成事件、Reader overlay、设置入口、
动图协议、Android PaddleOCR runtime、应用内模型下载和 benchmark harness。

已提供 OpenAI-compatible、DeepL 和 Android CTranslate2 sequence-to-sequence adapter。本地模型采用带 SHA-256
manifest 的目录导入，构建端必须随 APK 提供 CTranslate2/SentencePiece ARM64 runtime；仓库提供固定
revision 的 runtime/精选 SMaLL-100 直连模型构建与语义回归脚本，但不捆绑第三方权重。未完成：应用内直接下载、
iOS/桌面 OCR 与本地翻译 runtime、learned balloon detector、用户校正、拟声词和动图实际分析。OCR/本地翻译 runtime
或对应语言对模型缺失时 UI/任务明确报错，不进行网络回退。
