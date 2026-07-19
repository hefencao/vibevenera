# Local Comic Translation Models

Android 本地文本翻译使用 **CTranslate2 INT8 + SentencePiece**。模型权重不进入 APK；繁中输出复用
简中结果再执行应用内 OpenCC，不额外常驻一份权重。

## 1. 已验证模型组

当前验证通过的是固定 commit 的 Helsinki-NLP/OPUS-MT 枢轴链路：

```text
ja → en ┐
        ├→ zh-CN → OpenCC(可选 zh-TW)
ko → en ┘
```

原因不是匹配计算昂贵，而是目前可直接转换的日/韩→中文 Marian 模型质量或 CTranslate2 兼容性不足。
枢轴增加一次推理，但避免依赖未验证的直连权重。模型管理器仍优先选择已安装的直连 pair；没有直连时才
要求完整的 `source→en + en→target` 链路。

PC 安装固定版本依赖并构建三套目录：

```powershell
python -m pip install -r tool/comic_translation/requirements.txt
python tool/comic_translation/build_curated_models.py `
  --output build/local-models `
  --cache .local/comic_translation-model-cache
```

脚本下载以下精确 revision、转换为 INT8，并以真实句子验证每段及完整枢轴输出：

- `Helsinki-NLP/opus-mt-ja-en@0770961a39ba6bd66305b149c3f4110bcafca2e6`
- `Helsinki-NLP/opus-mt-ko-en@e42d1f41b66194e6d10512f8a27bebc1f4f5097e`
- `Helsinki-NLP/opus-mt-en-zh@408d9bc410a388e1d9aef112a2daba955b945255`

三套 INT8 包合计约 234 MiB；日文或韩文单独使用时与共享的 `en→zh` 合计约 155–158 MiB。分别在
设置 → 阅读 → 翻译模型与 API → 本地翻译模型中导入输出的 `ja-en`、`ko-en`、`en-zh` 目录。

## 2. 自定义模型

单模型转换示例：

```powershell
python tool/comic_translation/convert_marian.py `
  --model <Hugging-Face-Marian-model> `
  --revision <exact-commit> `
  --output build/local-models/ja-zh `
  --id opus-mt-ja-zh-int8 `
  --version 1 `
  --name "OPUS-MT Japanese Chinese INT8" `
  --source-language ja `
  --target-language zh-CN `
  --license Apache-2.0 `
  --source-url <model-source-url>
```

脚本生成 schema v2 `manifest.json` 和逐文件 SHA-256。`sourceEosToken` 明确记录 Marian 源端句尾
token；遗漏 `</s>` 会使部分转换模型重复生成直到最大长度。需要目标语言前缀的多语模型通过
`--source-prefix` 写入 manifest。模型目录至少包含：

```text
manifest.json
model.bin
config.json
source.spm
target.spm
shared_vocabulary.json
```

也支持 `source_vocabulary.json + target_vocabulary.json`。应用先复制到 staging、逐文件校验，再
原子替换同 ID 的旧版本；Reader 不直接引用用户选择目录。转换成功不代表语义正确，模型来源、许可、
终止行为和实际翻译都必须单独审核。

## 3. Android native runtime

运行库由固定版本源码可复现构建：

```powershell
tool/comic_translation/build_android_runtime.ps1 -Abis arm64-v8a
```

脚本构建 CTranslate2 4.7.2、SentencePiece 0.2.1、Ruy 和 INT8 CPU 路径，并应用 Android 缺少
`pthread_setaffinity_np` 的最小补丁。stripped ARM64 依赖合计约 5.5 MiB，输出到
`.local/comic_translation_native/runtime`；CMake 会自动发现。外部发行构建也可显式设置：

```text
CTRANSLATE2_ROOT=<package containing include/ and lib/<abi>/libctranslate2.so>
SENTENCEPIECE_ROOT=<package containing include/ and lib/<abi>/libsentencepiece.so>
```

未提供运行库时仍可构建并使用远程翻译，本地 backend 的 `isAvailable` 返回 false。生产 APK 必须为
每个支持 ABI 同时打包 CTranslate2、SentencePiece 及 `libvenera_translation.so`。

## 4. 运行契约

- Flutter UI isolate 与 Android platform thread 不执行推理；插件使用独立单线程 worker。
- 一个气泡 unit 是一个 batch item；同组 OCR 行/列按阅读顺序合并后整页调用 `translate_batch`，beam size 为 2。
  Greedy/beam 1 会使当前 OPUS 枢轴在短口语上选择重复或明显错误的低质量路径，例如把 `いえいえ` 译成重复语气词；
  beam 2 是当前质量/移动端开销的基线。
- native 在 SentencePiece 编码后追加 manifest 声明的源 EOS，不以字符串预处理猜测。
- 一个 Reader session 同时保持枢轴所需的两个 native handle；切换页面不重复装载模型。
- direct pair 优先，否则按 `source→en→target` 逐段批处理；所有 pair ID、版本、权重摘要、前缀和 EOS
  都进入翻译缓存身份。
- 本地模型无跨页上下文；最后一个 session 退出后统一释放 native handles。
- 本地失败不会回退到网络 API。
