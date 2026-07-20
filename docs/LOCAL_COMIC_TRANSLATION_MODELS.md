# Local Comic Translation Models

Android 本地文本翻译使用 **CTranslate2 INT8 + SentencePiece**。模型权重不进入 APK；简体输出统一执行
繁转简，繁体输出再执行应用内简转繁，不额外常驻一份权重。

## 1. 推荐模型

推荐单模型直连链路：

```text
ja ┐
   ├→ SMaLL-100 INT8 → zh-CN → OpenCC(可选 zh-TW)
ko ┘
```

旧 OPUS-MT 链路 `ja/ko → en → zh` 不再作为推荐模型。问题不是 token 协议：即使语言 token 正确，
`ja/ko → en` 仍可能丢句，旧 `en → zh` 对短口语也会产生 `Hey. → 顿` 一类错误；枢轴第一段丢失的
语义无法在第二段恢复。SMaLL-100 在一个模型内直接覆盖日/韩→中文，不再暴露英语中间文本。

PC 安装固定版本依赖并构建：

```powershell
python -m pip install -r tool/comic_translation/requirements.txt
python tool/comic_translation/build_curated_models.py `
  --output build/local-models `
  --cache .local/comic_translation-model-cache
```

脚本固定使用 `alirezamsh/small100@8ab680e26a596d2e3d2d2d17ae0f68df1037328c`，转换为 INT8，
并强制验证以下退化样例：短日语 `あの`、同组 `何を\nですか？`，以及同时包含“下雨”和“提前预订
租车”的长韩语。任一语义缺失会直接使构建失败。输出目录为 `small100-ja-ko-zh`；只需在
设置 → 阅读 → 翻译模型与 API → 本地翻译模型中导入这一个目录。

`--legacy-opus` 仍可额外构建旧三段模型，供回归比较，不应作为默认安装建议。SMaLL-100 原始 FP32
权重约 1.33 GB；INT8 包仍明显大于旧的单个 Marian 包，应在目标设备实测加载内存、首轮延迟和持续
吞吐。应用只保持一个直连 native handle，而不是同时保持两个枢轴 handle。

## 2. 模型包协议

schema v4 支持通用 CTranslate2 sequence-to-sequence 模型：

```json
{
  "schemaVersion": 4,
  "engine": "ctranslate2-seq2seq",
  "sourceLanguages": ["ja", "ko"],
  "targetLanguage": "zh-CN",
  "sourcePrefixTokens": ["__zh__"],
  "sourceEosToken": "</s>",
  "targetPrefixTokens": ["__zh__"],
  "beamSize": 5
}
```

- `sourceLanguages` 允许一份多语模型服务多个源语言，避免复制相同权重。
- `sourcePrefixTokens` / `sourceEosToken` 直接参与 encoder token 序列。
- `targetPrefixTokens` 通过 CTranslate2 `target_prefix` 约束 decoder，并在 SentencePiece 解码前移除。
- `beamSize` 属于模型包，而不是 native 硬编码参数。SMaLL-100 使用其建议值 5；旧 schema v1-v3
  迁移时保持之前的 beam 2 行为。

SMaLL-100 的契约是 `__zh__ + source pieces + </s>`，decoder 也以 `__zh__` 开始。语言 token 不能拼进
原文再交给 SentencePiece；否则会被拆成普通/未知片段并污染译文。native 对目标前缀做精确校验，协议
不匹配会显式失败而不是静默输出错误文本。

模型目录至少包含：

```text
manifest.json
model.bin
config.json
source.spm
target.spm
shared_vocabulary.json
```

也支持 `source_vocabulary.json + target_vocabulary.json`。应用先复制到 staging、逐文件校验 SHA-256，
再原子替换同 ID 的旧版本；Reader 不直接引用用户选择目录。schema v1-v3 的旧安装清单会迁移为 v4，
但不会自动把旧 OPUS 权重替换成 SMaLL-100。

## 3. 自定义转换

Marian 单语模型仍可使用默认 tokenizer 文件名。多源/多语模型可以重复传入源语言，并分别声明 encoder
和 decoder 控制 token：

```powershell
python tool/comic_translation/convert_marian.py `
  --model <Hugging-Face-seq2seq-model> `
  --output build/local-models/custom `
  --id custom-int8 `
  --version 1 `
  --name "Custom INT8" `
  --source-language ja `
  --source-language ko `
  --target-language zh-CN `
  --license <license> `
  --source-prefix-token __zh__ `
  --target-prefix-token __zh__ `
  --beam-size 5 `
  --source-tokenizer sentencepiece.bpe.model `
  --target-tokenizer sentencepiece.bpe.model
```

转换器会检查 source/target 控制 token 是否真实存在于相应 CTranslate2 词表。转换成功只说明运行协议
兼容；语义质量仍必须用目标场景中的短口语、长句、省略和同组多行文本单独审核。

## 4. Android native runtime

运行库由固定版本源码可复现构建：

```powershell
tool/comic_translation/build_android_runtime.ps1 -Abis arm64-v8a
```

脚本构建 CTranslate2 4.7.2、SentencePiece 0.2.1、Ruy 和 INT8 CPU 路径，并应用 Android 缺少
`pthread_setaffinity_np` 的最小补丁。stripped ARM64 依赖合计约 5.5 MiB，输出到
`.local/comic_translation_native/runtime`；CMake 会自动发现。未提供运行库时仍可构建并使用远程翻译，
本地 backend 的 `isAvailable` 返回 false。

## 5. 运行边界

- Flutter UI isolate 与 Android platform thread 不执行推理；插件使用独立单线程 worker。
- 一个气泡 unit 是一个 batch item；同组 OCR 行/列按阅读顺序合并后整页调用 `translate_batch`。
- direct pair 优先，否则才查找 `source→en→target`；多源直连模型会同时命中日语和韩语。
- 所有权重摘要、控制 token、beam 和 schema 都进入翻译缓存身份。
- 本地模型无跨页上下文；最后一个 session 退出后释放 native handles。
- 本地失败不会回退到网络 API。
