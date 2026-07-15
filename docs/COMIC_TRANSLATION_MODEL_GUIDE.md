# Comic Translation Model Guide

## 当前入口

`设置 → 阅读 → 翻译模型与 API`：

- 查看本地 OCR 和远程翻译后端状态；
- 打开官方模型下载/Android 部署文档；
- 配置 OpenAI-compatible Chat Completions endpoint、model 和 API key；
- 选择本地漫画页执行三轮 benchmark。

## OCR 候选顺序

1. **PP-OCRv6 small**：支持日文的移动端主候选；
2. **PP-OCRv5 mobile**：兼容性及日文准确率对照；
3. 韩文 recognition pack：仅在韩文样本需要时加载；
4. **PP-OCRv6 tiny**：先用于体积/速度对照；日文覆盖和漫画竖排准确率需实测。

官方 Android 部署文档给出的模型目录结构为：

```text
models/
├─ det/inference.onnx
└─ rec/
   ├─ inference.onnx
   └─ inference.yml
```

当前仓库尚未绑定 OCR native runtime，因此页面只提供明确的下载指引和 benchmark 状态，
不会下载一个无法执行的模型包。完成低、中、高端 Android 真机对照后，再固定 runtime、
下载地址、SHA-256 和模型包 manifest。

## 远程翻译

当前 adapter 使用 OpenAI-compatible `/v1/chat/completions` JSON 请求。endpoint 是完整 URL，
因此也可以指向用户自建的兼容服务。请求只发送 OCR 文本、前几页上下文和 glossary，
不上传原图。返回必须是：

```json
{"translations":{"regionId":"translated text"}}
```

API key 保存于应用数据目录的 `comic_translation_secrets.json`，不会进入数据同步。Android
应用私有目录受系统沙箱保护；桌面端文件目前未加密。
