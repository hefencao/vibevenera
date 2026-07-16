# Comic Translation Model Guide

## 当前入口

`设置 → 阅读 → 翻译模型与 API`：

- 查看本地 OCR 和远程翻译后端状态；
- 在应用内断点续传下载官方 PP-OCRv6 small 模型并做 SHA-256 校验；
- 打开官方模型/Android 部署文档；
- 配置 OpenAI-compatible Chat Completions endpoint、model 和 API key；
- 选择本地漫画页执行 3/10 轮 benchmark。

## OCR 候选顺序

1. **PP-OCRv6 small**：支持日文、韩文等多语言的移动端主候选；
2. **PP-OCRv5 mobile**：兼容性及日文准确率对照；
3. 韩文 recognition pack：仅在 PP-OCRv6 small 的韩漫实测准确率不足时再引入；
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
模型清单固定到官方仓库提交，共 29.7 MiB；文件先写入 `.part`，服务器支持 Range 时从已有
长度继续，逐文件校验后 rename，最后才写入安装 manifest。模型不随 APK 打包。

OCR MethodChannel 只传文件路径和结构化结果。图片采样、OpenCV 预处理、ONNX 推理均在单独
Android worker 执行，不占用 platform/UI 线程；输入长边按 1600 进行分析。动态 WebP/GIF
仍不会进入该 runtime。

benchmark 可明确选择日文、韩文、中文或英文源语言。它会显示模型加载、检测/识别各阶段、
OCR/翻译 P50/P95、OCR 原文及每轮
RSS 变化，并区分模型加载、边界采样最大值和释放后保留内存。模型约 29.7 MiB 只是磁盘权重大小，
运行峰值还包含 ONNX session、OpenCV Mat、检测 tensor 和文字 crop，必须在目标设备实测，
不能由参数量直接推断。

## 远程翻译

当前 adapter 使用 OpenAI-compatible `/v1/chat/completions` JSON 请求。endpoint 是完整 URL，
因此也可以指向用户自建的兼容服务。请求只发送 OCR 文本、前几页上下文和 glossary，
不上传原图。返回必须是：

```json
{"translations":{"regionId":"translated text"}}
```

API key 保存于应用数据目录的 `comic_translation_secrets.json`，不会进入数据同步。Android
应用私有目录受系统沙箱保护；桌面端文件目前未加密。
