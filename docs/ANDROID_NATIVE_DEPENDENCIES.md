# Android native 依赖与可复现构建

Android 包含两组从源码构建的 native 能力：流式 WebP 解码，以及本地漫画翻译。第三方仓库、
交叉编译目录和 `.so` 不属于 Venera 项目源码，因此统一放在 Git 已忽略的
`.local/comic_translation_native`；Venera 自己的 JNI/C/C++ 适配层、构建脚本和第三方补丁则必须提交到
仓库。这样既不会把大型 vendor tree 混入项目，也不会依赖某台机器上未记录的源码修改。

目录约定：

```text
.local/comic_translation_native/       # 不提交 Git
├── CTranslate2/                        # 固定提交的第三方源码
├── sentencepiece/                      # 固定提交的第三方源码
├── llama.cpp/                          # 固定 PR 提交的第三方源码
├── libwebp/                            # 固定提交 + 项目补丁
├── build/                              # Android 交叉编译中间产物
└── runtime/                            # CMake 消费的头文件、许可证和 .so

android/app/src/main/cpp/               # 提交 Git：Venera native 适配层
tool/comic_translation/                 # 提交 Git：构建脚本与补丁
```

## 固定依赖

| 依赖 | 固定版本/提交 | 用途 | 许可证 |
| --- | --- | --- | --- |
| CTranslate2 | `v4.7.2` / `9ff9c719e62b98fb8a993c1629833b0ddab447db` | 旧 seq2seq 模型 | MIT |
| SentencePiece | `v0.2.1` / `31646a467d2051eb904e0b45de3a73e91fe1c1e3` | seq2seq tokenizer | Apache-2.0 |
| llama.cpp PR #19357 | `a2baedad71a4d5685c83fe1939bb2e5f94e77f35` | Hy-MT Q2_0c 推理 | MIT |
| KleidiAI | `c6b34654b7654d43a0f808bca3dd1cbc38e2bac9` | llama.cpp arm64 DotProd kernel | Apache-2.0 |
| libwebp | `3757b8afeb54e305eaef18502812a9a88b7ed662` | WebP 解码 | BSD-3-Clause |

项目维护两个可审计补丁：

- `ctranslate2-android-thread-affinity.patch`：Android 不调用 Linux-only thread affinity。
- `libwebp-vp8-thread-buffer-pool.patch`：复用同一解码线程的大块 VP8 工作缓冲区。原来位于 Windows
  外部 libwebp checkout 中的三个 staged 修改已迁移到此补丁，不再依赖 `/mnt/d/...`。

构建完成后，`runtime/versions.json` 会记录实际提交、补丁和 ABI。模型权重仍由应用运行时下载，不进入
APK。

## WSL/Linux

需要 Android SDK CMake 3.22.1、NDK 28.0.13004108、Git 和 Ninja。SDK 可来自
`ANDROID_SDK_ROOT`、`ANDROID_HOME` 或 `android/local.properties`：

```bash
tool/comic_translation/build_android_runtime.sh --abis arm64-v8a
flutter build apk --release --target-platform android-arm64
```

第一条命令会克隆固定第三方提交（KleidiAI 由固定 llama.cpp 提交通过 CMake FetchContent 获取）、
应用项目内补丁并生成 runtime。Release Gradle 配置读取
`runtime/versions.json` 作为 CMake 配置指纹；因此 runtime 从“不存在”变成“已生成”时会自动重新配置，
不再需要依赖手工 `flutter clean`。Release 构建若找不到 CTranslate2、SentencePiece 或 llama.cpp 的
arm64 运行库会直接失败，避免产出表面成功但缺少本地翻译功能的 APK；Debug 构建仍允许省略它们。

若依赖目录不使用默认位置，两条命令应使用同一个根目录：

```bash
VENERA_NATIVE_ROOT=/absolute/path/to/native \
  tool/comic_translation/build_android_runtime.sh \
  --native-root /absolute/path/to/native
VENERA_NATIVE_ROOT=/absolute/path/to/native flutter build apk --release
```

## Windows

PowerShell 脚本保留用于原生 Windows 环境，并与 Linux 脚本使用相同提交和补丁：

```powershell
tool/comic_translation/build_android_runtime.ps1 -Abis arm64-v8a
flutter build apk --release --target-platform android-arm64
```

## 检查 APK

构建结束后可以验证 arm64 APK 至少包含以下运行库：

```bash
unzip -l build/app/outputs/flutter-apk/app-arm64-v8a-release.apk | \
  grep -E 'lib/(arm64-v8a)/(libvenera_(translation|hymt)|libctranslate2|libsentencepiece|libllama|libggml).*\.so'
```

预期包含 `libvenera_translation.so`、`libvenera_hymt.so`、`libctranslate2.so`、
`libsentencepiece.so`、`libllama.so`、`libggml.so`、`libggml-base.so` 和 `libggml-cpu.so`。

升级任一依赖时，应同时更新两个平台脚本中的提交、相关补丁、本文表格，并重新生成
`runtime/versions.json` 后完成真机 smoke test。不要直接修改 `.local` 后仅提交应用源码。
