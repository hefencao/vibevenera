param(
    [string]$AndroidSdk = $env:ANDROID_SDK_ROOT,
    [string]$NdkVersion = "28.0.13004108",
    [string[]]$Abis = @("arm64-v8a"),
    [int]$Jobs = [Environment]::ProcessorCount
)

$ErrorActionPreference = "Stop"
$gitRoot = Split-Path (Split-Path (Get-Command git).Source -Parent) -Parent
if (Test-Path "$gitRoot\usr\bin") { $env:PATH = "$gitRoot\usr\bin;$env:PATH" }
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
if (!$AndroidSdk) {
    $sdkProperty = Get-Content "$repo\android\local.properties" |
        Where-Object { $_.StartsWith("sdk.dir=") } | Select-Object -First 1
    if ($sdkProperty) {
        $AndroidSdk = $sdkProperty.Substring($sdkProperty.IndexOf('=') + 1) -replace '\\\\', '\'
    }
}
if (!$AndroidSdk -or !(Test-Path $AndroidSdk)) { throw "Android SDK not found; set ANDROID_SDK_ROOT" }
$root = "$repo\.local\comic_translation_native"
$ct2 = "$root\CTranslate2"
$spm = "$root\sentencepiece"
$llama = "$root\llama.cpp"
$webp = "$root\libwebp"
$ct2Git = $ct2.Replace('\', '/')
$spmGit = $spm.Replace('\', '/')
$llamaGit = $llama.Replace('\', '/')
$webpGit = $webp.Replace('\', '/')
$runtime = "$root\runtime"
$ct2Commit = "9ff9c719e62b98fb8a993c1629833b0ddab447db"
$spmCommit = "31646a467d2051eb904e0b45de3a73e91fe1c1e3"
$llamaCommit = "a2baedad71a4d5685c83fe1939bb2e5f94e77f35"
$llamaBranch = "pr-19357-sme2-int2"
$kleidiaiCommit = "c6b34654b7654d43a0f808bca3dd1cbc38e2bac9"
$webpCommit = "3757b8afeb54e305eaef18502812a9a88b7ed662"
$cmake = "$AndroidSdk\cmake\3.22.1\bin\cmake.exe"
$ninja = "$AndroidSdk\cmake\3.22.1\bin\ninja.exe"
$toolchain = "$AndroidSdk\ndk\$NdkVersion\build\cmake\android.toolchain.cmake"
$strip = "$AndroidSdk\ndk\$NdkVersion\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strip.exe"

function Run([scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code $LASTEXITCODE" }
}

New-Item -ItemType Directory -Force $root | Out-Null
if (!(Test-Path "$ct2\.git")) {
    Run { git clone --recursive https://github.com/OpenNMT/CTranslate2.git $ct2 }
}
if (!(Test-Path "$spm\.git")) {
    Run { git clone https://github.com/google/sentencepiece.git $spm }
}
if (!(Test-Path "$llama\.git")) {
    Run { git clone https://github.com/ggml-org/llama.cpp.git $llama }
}
if (!(Test-Path "$webp\.git")) {
    Run { git clone https://github.com/webmproject/libwebp.git $webp }
}
Run { git -c "safe.directory=$ct2Git" -C $ct2 checkout --detach $ct2Commit }
Run { git -c "safe.directory=$ct2Git" -C $ct2 submodule update --init --recursive }
Run { git -c "safe.directory=$spmGit" -C $spm checkout --detach $spmCommit }
Run { git -c "safe.directory=$llamaGit" -C $llama checkout --detach --force }
Run { git -c "safe.directory=$llamaGit" -C $llama fetch --force origin "pull/19357/head:$llamaBranch" }
Run { git -c "safe.directory=$llamaGit" -C $llama checkout --detach --force $llamaCommit }
Run { git -c "safe.directory=$llamaGit" -C $llama diff --quiet }
Run { git -c "safe.directory=$webpGit" -C $webp checkout --detach --force $webpCommit }

$threadPool = Get-Content -Raw "$ct2\src\thread_pool.cc"
if (!$threadPool.Contains("defined(__ANDROID__)")) {
    Run { git -c "safe.directory=$ct2Git" -C $ct2 apply "$PSScriptRoot\patches\ctranslate2-android-thread-affinity.patch" }
}
$vp8Decoder = Get-Content -Raw "$webp\src\dec\vp8_dec.c"
if (!$vp8Decoder.Contains("VP8MemPoolAcquire")) {
    Run { git -c "safe.directory=$webpGit" -C $webp apply "$PSScriptRoot\patches\libwebp-vp8-thread-buffer-pool.patch" }
}

if (Test-Path $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force }
New-Item -ItemType Directory -Force "$runtime\ctranslate2\include", "$runtime\sentencepiece\include", "$runtime\llama\include", "$runtime\licenses" | Out-Null
Copy-Item -Recurse "$ct2\include\*" "$runtime\ctranslate2\include\"
Copy-Item "$spm\src\*.h" "$runtime\sentencepiece\include\"
Copy-Item "$ct2\LICENSE" "$runtime\ctranslate2\LICENSE"
Copy-Item "$spm\LICENSE" "$runtime\sentencepiece\LICENSE"
Copy-Item "$llama\include\*.h" "$runtime\llama\include\"
Copy-Item "$llama\ggml\include\*.h" "$runtime\llama\include\"
Copy-Item "$llama\LICENSE" "$runtime\llama\LICENSE"
Copy-Item "$ct2\third_party\ruy\LICENSE" "$runtime\licenses\ruy.txt"
Copy-Item "$ct2\third_party\ruy\third_party\cpuinfo\LICENSE" "$runtime\licenses\cpuinfo.txt"
Copy-Item "$ct2\third_party\spdlog\LICENSE" "$runtime\licenses\spdlog.txt"
Copy-Item "$spm\third_party\protobuf-lite\LICENSE" "$runtime\licenses\protobuf-lite.txt"
Copy-Item "$spm\third_party\absl\LICENSE" "$runtime\licenses\abseil.txt"

foreach ($abi in $Abis) {
    $ct2Build = "$root\build\ctranslate2\$abi"
    $spmBuild = "$root\build\sentencepiece\$abi"
    $llamaBuild = "$root\build\llama\$abi"
    Run {
        & $cmake -S $ct2 -B $ct2Build -G Ninja "-DCMAKE_MAKE_PROGRAM=$ninja" `
            "-DCMAKE_TOOLCHAIN_FILE=$toolchain" "-DANDROID_ABI=$abi" `
            -DANDROID_PLATFORM=android-24 -DCMAKE_BUILD_TYPE=Release `
            -DBUILD_SHARED_LIBS=ON -DBUILD_CLI=OFF -DBUILD_TESTS=OFF `
            -DWITH_MKL=OFF -DWITH_DNNL=OFF -DWITH_OPENBLAS=OFF `
            -DWITH_RUY=ON -DOPENMP_RUNTIME=NONE -DENABLE_CPU_DISPATCH=OFF
    }
    Run { & $cmake --build $ct2Build --target ctranslate2 -j $Jobs }
    Run {
        & $cmake -S $spm -B $spmBuild -G Ninja "-DCMAKE_MAKE_PROGRAM=$ninja" `
            "-DCMAKE_TOOLCHAIN_FILE=$toolchain" "-DANDROID_ABI=$abi" `
            -DANDROID_PLATFORM=android-24 -DCMAKE_BUILD_TYPE=Release `
            -DSPM_ENABLE_SHARED=ON -DSPM_BUILD_TEST=OFF -DSPM_ENABLE_TCMALLOC=OFF
    }
    Run { & $cmake --build $spmBuild --target sentencepiece -j $Jobs }
    Run {
        & $cmake -S $llama -B $llamaBuild -G Ninja "-DCMAKE_MAKE_PROGRAM=$ninja" `
            "-DCMAKE_TOOLCHAIN_FILE=$toolchain" "-DANDROID_ABI=$abi" `
            -DANDROID_PLATFORM=android-24 -DCMAKE_BUILD_TYPE=Release `
            -DBUILD_SHARED_LIBS=ON -DLLAMA_BUILD_COMMON=OFF `
            -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=OFF `
            -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF `
            -DLLAMA_BUILD_APP=OFF -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF `
            "-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod" `
            -DGGML_CPU_KLEIDIAI=ON -DGGML_LLAMAFILE=OFF
    }
    Run { & $cmake --build $llamaBuild --target llama -j $Jobs }
    New-Item -ItemType Directory -Force "$runtime\ctranslate2\lib\$abi", "$runtime\sentencepiece\lib\$abi", "$runtime\llama\lib\$abi" | Out-Null
    Copy-Item "$ct2Build\libctranslate2.so" "$runtime\ctranslate2\lib\$abi\"
    Copy-Item "$spmBuild\src\libsentencepiece.so" "$runtime\sentencepiece\lib\$abi\"
    foreach ($library in @("libllama.so", "libggml.so", "libggml-base.so", "libggml-cpu.so")) {
        $built = Get-ChildItem $llamaBuild -Recurse -Filter $library | Select-Object -First 1
        if (!$built) { throw "$library was not built" }
        Copy-Item $built.FullName "$runtime\llama\lib\$abi\$library"
        Run { & $strip "$runtime\llama\lib\$abi\$library" }
    }
    Run { & $strip "$runtime\ctranslate2\lib\$abi\libctranslate2.so" }
    Run { & $strip "$runtime\sentencepiece\lib\$abi\libsentencepiece.so" }
}

@{
    ctranslate2 = @{ version = "4.7.2"; commit = $ct2Commit }
    sentencepiece = @{ version = "0.2.1"; commit = $spmCommit }
    llama = @{ commit = $llamaCommit; source = "pull/19357/head"; feature = "official Q2_0c/KleidiAI DotProd" }
    kleidiai = @{ commit = $kleidiaiCommit; source = "llama.cpp FetchContent" }
    libwebp = @{ commit = $webpCommit; patch = "vp8-thread-buffer-pool" }
    abis = $Abis
} | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 "$runtime\versions.json"
Write-Host "Runtime package: $runtime"
