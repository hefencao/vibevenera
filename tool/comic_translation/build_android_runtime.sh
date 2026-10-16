#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/../.." && pwd -P)"

android_sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
ndk_version="28.0.13004108"
abis=("arm64-v8a")
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')"
native_root="${VENERA_NATIVE_ROOT:-$repo_root/.local/comic_translation_native}"

ct2_commit="9ff9c719e62b98fb8a993c1629833b0ddab447db"
spm_commit="31646a467d2051eb904e0b45de3a73e91fe1c1e3"
llama_commit="031ddb2e08962837c899374297da75f91cc0157d"
llama_source_commit="a2baedad71a4d5685c83fe1939bb2e5f94e77f35"
llama_patch="$script_dir/patches/llama-q2-0c.patch"
kleidiai_commit="c6b34654b7654d43a0f808bca3dd1cbc38e2bac9"
libwebp_commit="3757b8afeb54e305eaef18502812a9a88b7ed662"

usage() {
  printf '%s\n' \
    "Usage: $0 [options]" \
    "" \
    "Options:" \
    "  --android-sdk PATH   Android SDK root (defaults to ANDROID_SDK_ROOT," \
    "                       ANDROID_HOME, or android/local.properties)" \
    "  --ndk-version VALUE  Android NDK version (default: $ndk_version)" \
    "  --abis LIST          Comma-separated Android ABIs (default: arm64-v8a)" \
    "  --jobs NUMBER        Parallel build jobs (default: $jobs)" \
    "  --native-root PATH   Third-party source/runtime root (default: $native_root)" \
    "  -h, --help           Show this help"
}

while (($#)); do
  case "$1" in
    --android-sdk)
      android_sdk="$2"
      shift 2
      ;;
    --ndk-version)
      ndk_version="$2"
      shift 2
      ;;
    --abis)
      IFS=',' read -r -a abis <<< "$2"
      shift 2
      ;;
    --jobs)
      jobs="$2"
      shift 2
      ;;
    --native-root)
      native_root="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$android_sdk" && -f "$repo_root/android/local.properties" ]]; then
  android_sdk="$(
    sed -n 's/^sdk\.dir=//p' "$repo_root/android/local.properties" |
      head -n 1 |
      sed 's/\\\\/\\/g'
  )"
fi

if [[ -z "$android_sdk" || ! -d "$android_sdk" ]]; then
  printf '%s\n' \
    'Android SDK not found. Set ANDROID_SDK_ROOT or pass --android-sdk.' >&2
  exit 1
fi
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Invalid job count: %s\n' "$jobs" >&2
  exit 2
fi
if ((${#abis[@]} == 0)); then
  printf 'At least one ABI is required.\n' >&2
  exit 2
fi
for abi in "${abis[@]}"; do
  if [[ "$abi" != "arm64-v8a" ]]; then
    printf 'Hy-MT Q2_0c runtime currently supports only arm64-v8a, not %s.\n' \
      "$abi" >&2
    exit 2
  fi
done

cmake="$android_sdk/cmake/3.22.1/bin/cmake"
ninja="$android_sdk/cmake/3.22.1/bin/ninja"
toolchain="$android_sdk/ndk/$ndk_version/build/cmake/android.toolchain.cmake"
strip="$android_sdk/ndk/$ndk_version/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
for tool in git "$cmake" "$ninja" "$strip"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required tool not found: %s\n' "$tool" >&2
    exit 1
  fi
done
if [[ ! -f "$toolchain" ]]; then
  printf 'Android NDK toolchain not found: %s\n' "$toolchain" >&2
  exit 1
fi

ct2="$native_root/CTranslate2"
spm="$native_root/sentencepiece"
llama="$native_root/llama.cpp"
libwebp="$native_root/libwebp"
build_root="$native_root/build"
runtime_final="$native_root/runtime"
runtime="$native_root/runtime.building"

clone_if_missing() {
  local url="$1"
  local path="$2"
  if [[ -e "$path" && ! -d "$path/.git" ]]; then
    printf 'Dependency path exists but is not a Git checkout: %s\n' "$path" >&2
    exit 1
  fi
  if [[ ! -d "$path/.git" ]]; then
    git clone --filter=blob:none "$url" "$path"
  fi
}

checkout_commit() {
  local path="$1"
  local commit="$2"
  local fetch_ref="${3:-$commit}"
  local current
  current="$(git -C "$path" rev-parse HEAD)"
  if [[ "$current" == "$commit" ]]; then
    return
  fi
  if ! git -C "$path" diff --quiet ||
     ! git -C "$path" diff --cached --quiet; then
    printf 'Dependency checkout has local changes: %s\n' "$path" >&2
    printf 'Move or revert those changes before switching revisions.\n' >&2
    exit 1
  fi
  if ! git -C "$path" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$path" fetch --depth=1 origin "$fetch_ref"
  fi
  git -C "$path" checkout --detach "$commit"
}

apply_patch_once() {
  local path="$1"
  local patch_file="$2"
  if git -C "$path" apply --reverse --check "$patch_file" 2>/dev/null; then
    return
  fi
  if ! git -C "$path" diff --quiet ||
     ! git -C "$path" diff --cached --quiet; then
    printf 'Cannot apply %s: checkout has unrelated changes: %s\n' \
      "$(basename "$patch_file")" "$path" >&2
    exit 1
  fi
  git -C "$path" apply "$patch_file"
}

verify_expected_changes() {
  local path="$1"
  shift
  local entry
  local allowed
  local expected
  while IFS= read -r entry; do
    allowed=false
    for expected in "$@"; do
      if [[ "$entry" == " M $expected" ]]; then
        allowed=true
        break
      fi
    done
    if [[ "$allowed" != true ]]; then
      printf 'Unexpected dependency source change in %s: %s\n' \
        "$path" "$entry" >&2
      exit 1
    fi
  done < <(git -C "$path" status --porcelain --untracked-files=all)
}

mkdir -p "$native_root"
clone_if_missing https://github.com/OpenNMT/CTranslate2.git "$ct2"
clone_if_missing https://github.com/google/sentencepiece.git "$spm"
clone_if_missing https://github.com/ggml-org/llama.cpp.git "$llama"
clone_if_missing https://github.com/webmproject/libwebp.git "$libwebp"

checkout_commit "$ct2" "$ct2_commit"
git -C "$ct2" submodule update --init --recursive
checkout_commit "$spm" "$spm_commit"
checkout_commit "$llama" "$llama_commit"
checkout_commit "$libwebp" "$libwebp_commit"

if ! grep -q 'defined(__ANDROID__)' "$ct2/src/thread_pool.cc"; then
  apply_patch_once \
    "$ct2" \
    "$script_dir/patches/ctranslate2-android-thread-affinity.patch"
fi
if ! grep -q 'VP8MemPoolAcquire' "$libwebp/src/dec/vp8_dec.c"; then
  apply_patch_once \
    "$libwebp" \
    "$script_dir/patches/libwebp-vp8-thread-buffer-pool.patch"
fi
apply_patch_once "$llama" "$llama_patch"
if ! git -C "$libwebp" apply --reverse --check \
    "$script_dir/patches/libwebp-vp8-thread-buffer-pool.patch" 2>/dev/null; then
  printf 'libwebp source does not exactly match the tracked project patch.\n' >&2
  exit 1
fi
verify_expected_changes "$ct2" src/thread_pool.cc
verify_expected_changes "$spm"
mapfile -t llama_patched_files < <(git -C "$llama" apply --numstat "$llama_patch" | cut -f3)
verify_expected_changes "$llama" "${llama_patched_files[@]}"
verify_expected_changes \
  "$libwebp" \
  src/dec/frame_dec.c \
  src/dec/vp8_dec.c \
  src/dec/vp8i_dec.h

runtime_parent="$(dirname -- "$runtime")"
if [[ "$runtime_parent" != "$native_root" || "$runtime" == "/" ]]; then
  printf 'Refusing to replace unexpected runtime path: %s\n' "$runtime" >&2
  exit 1
fi
if [[ -d "$runtime" ]]; then
  rm -rf -- "$runtime"
fi
mkdir -p \
  "$runtime/ctranslate2/include" \
  "$runtime/sentencepiece/include" \
  "$runtime/llama/include" \
  "$runtime/licenses"

cp -R "$ct2/include/." "$runtime/ctranslate2/include/"
find "$spm/src" -maxdepth 1 -type f -name '*.h' \
  -exec cp -t "$runtime/sentencepiece/include/" {} +
cp "$ct2/LICENSE" "$runtime/ctranslate2/LICENSE"
cp "$spm/LICENSE" "$runtime/sentencepiece/LICENSE"
find "$llama/include" "$llama/ggml/include" -maxdepth 1 -type f -name '*.h' \
  -exec cp -t "$runtime/llama/include/" {} +
cp "$llama/LICENSE" "$runtime/llama/LICENSE"
cp "$ct2/third_party/ruy/LICENSE" "$runtime/licenses/ruy.txt"
cp "$ct2/third_party/ruy/third_party/cpuinfo/LICENSE" \
  "$runtime/licenses/cpuinfo.txt"
cp "$ct2/third_party/spdlog/LICENSE" "$runtime/licenses/spdlog.txt"
cp "$spm/third_party/protobuf-lite/LICENSE" \
  "$runtime/licenses/protobuf-lite.txt"
cp "$spm/third_party/absl/LICENSE" "$runtime/licenses/abseil.txt"

for abi in "${abis[@]}"; do
  ct2_build="$build_root/ctranslate2/$abi"
  spm_build="$build_root/sentencepiece/$abi"
  llama_build="$build_root/llama/$abi"

  "$cmake" -S "$ct2" -B "$ct2_build" -G Ninja \
    "-DCMAKE_MAKE_PROGRAM=$ninja" \
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain" \
    "-DANDROID_ABI=$abi" \
    -DANDROID_PLATFORM=android-24 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_CLI=OFF \
    -DBUILD_TESTS=OFF \
    -DWITH_MKL=OFF \
    -DWITH_DNNL=OFF \
    -DWITH_OPENBLAS=OFF \
    -DWITH_RUY=ON \
    -DOPENMP_RUNTIME=NONE \
    -DENABLE_CPU_DISPATCH=OFF
  "$cmake" --build "$ct2_build" --target ctranslate2 -j "$jobs"

  "$cmake" -S "$spm" -B "$spm_build" -G Ninja \
    "-DCMAKE_MAKE_PROGRAM=$ninja" \
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain" \
    "-DANDROID_ABI=$abi" \
    -DANDROID_PLATFORM=android-24 \
    -DCMAKE_BUILD_TYPE=Release \
    -DSPM_ENABLE_SHARED=ON \
    -DSPM_BUILD_TEST=OFF \
    -DSPM_ENABLE_TCMALLOC=OFF
  "$cmake" --build "$spm_build" --target sentencepiece -j "$jobs"

  "$cmake" -S "$llama" -B "$llama_build" -G Ninja \
    "-DCMAKE_MAKE_PROGRAM=$ninja" \
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain" \
    "-DANDROID_ABI=$abi" \
    -DANDROID_PLATFORM=android-24 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DLLAMA_BUILD_COMMON=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_APP=OFF \
    -DGGML_OPENMP=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod \
    -DGGML_CPU_KLEIDIAI=ON \
    -DGGML_LLAMAFILE=OFF
  "$cmake" --build "$llama_build" --target llama -j "$jobs"

  mkdir -p \
    "$runtime/ctranslate2/lib/$abi" \
    "$runtime/sentencepiece/lib/$abi" \
    "$runtime/llama/lib/$abi"
  cp "$ct2_build/libctranslate2.so" \
    "$runtime/ctranslate2/lib/$abi/libctranslate2.so"
  cp "$spm_build/src/libsentencepiece.so" \
    "$runtime/sentencepiece/lib/$abi/libsentencepiece.so"

  for library in libllama.so libggml.so libggml-base.so libggml-cpu.so; do
    built="$(find "$llama_build" -type f -name "$library" -print -quit)"
    if [[ -z "$built" ]]; then
      printf 'llama.cpp did not build %s for %s\n' "$library" "$abi" >&2
      exit 1
    fi
    cp "$built" "$runtime/llama/lib/$abi/$library"
    "$strip" "$runtime/llama/lib/$abi/$library"
  done
  "$strip" "$runtime/ctranslate2/lib/$abi/libctranslate2.so"
  "$strip" "$runtime/sentencepiece/lib/$abi/libsentencepiece.so"
done

abi_json=''
for abi in "${abis[@]}"; do
  if [[ -n "$abi_json" ]]; then
    abi_json+=', '
  fi
  abi_json+="\"$abi\""
done
cat > "$runtime/versions.json" <<EOF
{
  "ctranslate2": {"version": "4.7.2", "commit": "$ct2_commit"},
  "sentencepiece": {"version": "0.2.1", "commit": "$spm_commit"},
  "llama": {"commit": "$llama_commit", "source_commit": "$llama_source_commit", "patch": "q2-0c", "feature": "Q2_0c/KleidiAI DotProd"},
  "kleidiai": {"commit": "$kleidiai_commit", "source": "llama.cpp FetchContent"},
  "libwebp": {"commit": "$libwebp_commit", "patch": "vp8-thread-buffer-pool"},
  "abis": [$abi_json]
}
EOF

runtime_previous="$native_root/runtime.previous"
if [[ -d "$runtime_previous" ]]; then
  rm -rf -- "$runtime_previous"
fi
if [[ -d "$runtime_final" ]]; then
  mv -- "$runtime_final" "$runtime_previous"
fi
mv -- "$runtime" "$runtime_final"
if [[ -d "$runtime_previous" ]]; then
  rm -rf -- "$runtime_previous"
fi

printf 'Android native dependencies: %s\n' "$native_root"
printf 'Translation runtime package: %s\n' "$runtime_final"
printf '%s\n' \
  'The next release build will detect this versions.json and reconfigure CMake.'
