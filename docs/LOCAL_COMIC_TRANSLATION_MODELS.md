# Local Comic Translation Models

Android 本地文本翻译默认使用 **Hy-MT1.5-1.8B 2-bit GGUF + llama.cpp**。模型权重不进入 APK；
设置页按固定 revision 下载、断点续传并校验 SHA-256。简体输出统一执行繁转简，繁体目标再执行应用内
简转繁，不额外常驻一份翻译权重。

## 1. 推荐模型

推荐直连链路：

```text
ja/ko → Hy-MT1.5-1.8B 2-bit → zh-CN → OpenCC(可选 zh-TW)
```

设置 → 阅读 → 翻译模型与 API → 本地翻译模型中点击“下载 Hy-MT 2-bit”。下载完成后该模型会成为
“当前本地模型”；也可切回自动选择或选择已导入的其他模型。官方 GGUF 固定为
`AngelSlim/Hy-MT1.5-1.8B-2bit-GGUF@ef3a410f443c23a155e563814defc5a933a3a35c`，文件
600,535,360 bytes，SHA-256 为
`46e587d917fc4f6f5bda602f10c4a53da8840240355824bcc0e227559c9cba3e`。它使用官方 PR #19357
定义的 Q2_0c tensor type 40；运行库不修改 llama.cpp 源码。

旧 OPUS-MT `ja/ko → en → zh` 的问题不是 token 协议：第一段可能丢句，旧 `en → zh` 对短口语也会
产生 `Hey. → 顿` 一类错误，枢轴第一段丢失的语义无法恢复。SMaLL-100 和自定义 Marian/CTranslate2
包仍可导入用于比较，但不再是默认安装建议。

## 2. 模型包协议

schema v5 支持两个 engine。Hy-MT GGUF：

```json
{
  "schemaVersion": 5,
  "engine": "llama.cpp-hymt",
  "id": "hy-mt1.5-1.8b-2bit",
  "sourceLanguages": ["ja", "ko"],
  "targetLanguage": "zh-CN",
  "promptTemplate": "Translate the following segment into Chinese, without additional explanation：{text}",
  "contextSize": 1024,
  "maxOutputTokens": 64,
  "files": {"model.gguf": "<sha256>"}
}
```

旧 CTranslate2 sequence-to-sequence 包继续使用：

```json
{
  "schemaVersion": 5,
  "engine": "ctranslate2-seq2seq",
  "sourceLanguages": ["ja", "ko"],
  "targetLanguage": "zh-CN",
  "sourcePrefixTokens": ["__zh__"],
  "sourceEosToken": "</s>",
  "targetPrefixTokens": ["__zh__"],
  "beamSize": 5,
  "promptTemplate": "",
  "contextSize": 0,
  "maxOutputTokens": 0
}
```

所有文件摘要、engine、prompt、上下文参数和生成上限都进入翻译缓存身份。应用先复制到 staging、逐文件
校验 SHA-256，再原子替换同 ID 的旧版本；Reader 不直接引用用户选择目录。schema v1-v4 的旧安装
清单会迁移到 v5，不会自动替换其权重。

## 3. Hy-MT 运行协议

Flutter 只发送模型包中的翻译指令，native 按官方 chat template 构造：

```text
<｜hy_begin▁of▁sentence｜><｜hy_User｜>{instruction}<｜hy_Assistant｜>
```

llama.cpp 参数为 `top_k=20`、`top_p=0.6`、`temperature=0.7`、`repetition_penalty=1.05`；每个 unit
开始前清空上下文。一个气泡中的 OCR 行先按阅读顺序合并为一个输入，插件在独立单线程 worker 中顺序
生成，不阻塞 Flutter UI 或 Android platform thread，也不同时保留多份大上下文。

Android runtime 直接使用官方 `pr-19357-sme2-int2` 源码，以
`GGML_CPU_ARM_ARCH=armv8.2-a+dotprod` 和 `GGML_CPU_KLEIDIAI=ON` 交叉编译静态 CPU backend。这样
Q2_0c 使用 PR 自带的 DotProd KleidiAI 内核，同时不引入自定义 tensor enum、动态 backend 装载或第三方
C/C++ 补丁。

若某个旧模型对噪声/符号 unit 返回空串，该 unit 保留原文并在 benchmark 原始响应中标记 `[empty]`；
其余 unit 仍正常回填，不再由一个空结果使整页进入失败状态。

## 4. 自定义 CTranslate2 转换

Marian/多语 sequence-to-sequence 模型仍可用转换脚本生成兼容包：

```powershell
python tool/comic_translation/convert_marian.py `
  --model <Hugging-Face-seq2seq-model> `
  --output build/local-models/custom `
  --id custom-int8 --version 1 --name "Custom INT8" `
  --source-language ja --source-language ko --target-language zh-CN `
  --license <license>
```

转换成功仅说明运行协议兼容；语义质量仍必须用目标场景中的短口语、长句、省略和同组多行文本审核。

## 5. Android native runtime

运行库由固定版本源码构建：

```powershell
tool/comic_translation/build_android_runtime.ps1 -Abis arm64-v8a
```

脚本执行官方的 `git fetch origin pull/19357/head:pr-19357-sme2-int2` 与 checkout，然后构建
CTranslate2/SentencePiece 和未修改的 llama.cpp，输出到
`.local/comic_translation_native/runtime`，CMake 自动发现。未提供某个运行库时仍可构建并使用其他后端；
选择对应本地模型时 `isAvailable` 会明确失败，不会回退网络 API。
