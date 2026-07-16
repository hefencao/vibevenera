# Comic Translation Model Guide

## 当前入口

`设置 → 阅读 → 翻译模型与 API`：

- 查看本地 OCR 和远程翻译后端状态；
- 在应用内断点续传下载官方 PP-OCRv6 small 和韩文 recognition 模型并做 SHA-256 校验；
- 打开官方模型/Android 部署文档；
- 配置 OpenAI-compatible Chat Completions endpoint、model 和 API key；
- 选择本地漫画页执行 3/10 轮 benchmark。

## OCR 候选顺序

1. **PP-OCRv6 small**：支持中文、英文、日文和 46 种拉丁字母语言的移动端主候选，
   **不支持韩文**；
2. **PP-OCRv5 mobile**：兼容性及日文准确率对照；
3. **korean PP-OCRv5 mobile recognition**：手动指定韩文时使用；
4. **PP-OCRv6 tiny**：先用于体积/速度对照；日文覆盖和漫画竖排准确率需实测。

官方 Android 部署文档给出的模型目录结构为：

```text
models/
├─ det/inference.onnx
└─ rec/
   ├─ inference.onnx
   └─ inference.yml
```

Android 已接入 PaddleOCR 官方 Android SDK、ONNX Runtime 1.21.1 和 OpenCV 4.13.0。
模型清单固定到官方仓库提交，共约 42.6 MiB；文件先写入 `.part`，服务器支持 Range 时从已有
长度继续，逐文件校验后 rename，最后才写入安装 manifest。模型不随 APK 打包。

OCR MethodChannel 只传文件路径和结构化结果。图片采样、OpenCV 预处理、ONNX 推理均在单独
Android worker 执行，不占用 platform/UI 线程；默认分析长边为 1600，实际值由每次 OCR 输入
传入。只有整页分析宽度低于有效下限的极长页才动态分块，窗口重叠不超过 128 分析像素。
动态 WebP/GIF 仍不会进入该 runtime。

benchmark 可明确选择日文、韩文、中文或英文源语言。它会显示模型加载、检测/识别各阶段、
OCR/翻译 P50/P95、OCR 原文、检测总输入像素、每个 tile 的 tensor shape 及每轮 RSS 变化，
浅色气泡补检 proposal 时间、候选/补回数和 inpainting clean-overlay PNG 大小，
并区分模型加载、边界采样最大值和释放后保留内存。RSS 是整个 App 进程的边界采样，不是推理
瞬时峰值。约 42.6 MiB 只是磁盘权重大小，
运行峰值还包含 ONNX session、OpenCV Mat、检测 tensor 和文字 crop，必须在目标设备实测，
不能由参数量直接推断。

自动语言当前使用 PP-OCRv6 recognition，因此不能识别韩文；韩文必须明确选择“韩文”，切换到独立的
`korean_PP-OCRv5_mobile_rec`。检测模型与文字识别模型相互独立：两条路径共享同一检测模型文件，
但当前 SDK 以完整 OCR session 为切换单位，
因此切换语言时先释放旧 session，避免两套 recognition 权重同时常驻。benchmark 会显示 tile、
实际使用的 recognizer、检测框/非空原始解码/阈值接受数量、逐区置信度、OCR 原文和翻译、
成功气泡数、源文字 mask 数和分割耗时。识别置信度是闭集类别内的概率；不支持的文字仍可能被
高置信度误识别成其他字符，不能据此推断模型支持该语言。

## 远程翻译

当前 adapter 使用 OpenAI-compatible `/v1/chat/completions` JSON 请求。endpoint 是完整 URL，
因此也可以指向用户自建的兼容服务。请求只发送 OCR 文本、前几页上下文和 glossary，
不上传原图。返回必须是：

```json
{"translations":{"unitId":"translated text"}}
```

同一气泡内的多行 OCR 作为一个 unit 的有序 `sourceLines` 发送，远程模型必须只返回一份完整译文。
OCR 置信度只描述识别可靠性，不作为跳过翻译的条件。请求只发送 OCR 文字；
韩文识别问题由手动选择韩文 recognition 模型解决，不通过增加远程翻译重试掩盖。

API key 保存于应用数据目录的 `comic_translation_secrets.json`，不会进入数据同步。Android
应用私有目录受系统沙箱保护；桌面端文件目前未加密。
