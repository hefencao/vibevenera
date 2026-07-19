# Local Comic Translation Models

Android 本地文本翻译使用 **CTranslate2 INT8 + SentencePiece**。模型权重不进入 APK；每个语言方向
独立安装，当前首选方向为 `ja→zh-CN` 与 `ko→zh-CN`。繁中输出复用简中模型后执行应用内 OpenCC
转换，不额外常驻一份权重。

## 1. 转换模型

PC 安装转换依赖：

```bash
python -m pip install ctranslate2 transformers sentencepiece
```

然后执行仓库脚本，例如：

```bash
python tool/comic_translation/convert_marian.py \
  --model <Hugging-Face-Marian-model> \
  --output build/local-models/ja-zh \
  --id opus-mt-ja-zh-int8 \
  --version 1 \
  --name "OPUS-MT Japanese Chinese INT8" \
  --source-language ja \
  --target-language zh-CN \
  --license Apache-2.0
```

脚本调用官方 `ct2-transformers-converter`，复制 `source.spm/target.spm`，并生成 Venera 所需的
`manifest.json` 和逐文件 SHA-256。模型目录至少包含：

```text
manifest.json
model.bin
config.json
source.spm
target.spm
shared_vocabulary.json
```

某些模型使用 `source_vocabulary.json + target_vocabulary.json` 代替 shared vocabulary，也受支持。
设置 → 阅读 → 翻译模型与 API → 本地翻译模型中选择该目录。应用先复制到 staging，逐文件校验，
再原子替换同 ID 的旧版本；Reader 不直接引用用户选择目录。

模型来源、训练数据、许可证和翻译质量必须单独审核。不能因为转换成功就把未经验证的第三方模型
设为默认下载项。

## 2. Android native runtime

构建使用 CTranslate2 4.7.x 与 SentencePiece 0.2.x 的 Android shared library。设置环境变量：

```text
CTRANSLATE2_ROOT=<package containing include/ and lib/<abi>/libctranslate2.so>
SENTENCEPIECE_ROOT=<package containing include/ and lib/<abi>/libsentencepiece.so>
```

`android/app/src/main/cpp/CMakeLists.txt` 检测到二者后构建 `libvenera_translation.so`；未提供时正常
构建仍可使用远程翻译，但本地 backend 的 `isAvailable` 会明确返回 false。生产 APK 若展示本地
backend，必须为其支持的 ABI 同时打包 CTranslate2、SentencePiece 及它们的 native 依赖。

## 3. 运行契约

- Flutter UI isolate 与 Android platform thread 都不执行推理；插件使用独立单线程 worker。
- 每个气泡 unit 合并为一个输入，整页 units 使用一次 `translate_batch`，beam size 为 1。
- 动态 backend 在请求时根据 OCR 源语言与目标语言选 pair；pair ID/version 进入翻译缓存身份。
- 本地模型无跨页上下文，不写入冗余 context cache variant。
- 模型在 Reader session 内保持加载；切换语言对时先释放旧 pair，退出最后一个 session 后释放。
- 本地失败不会回退到网络 API。
