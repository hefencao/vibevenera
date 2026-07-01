# Mihon WebP 图片处理架构参考

> 本文档分析 [Mihon](https://github.com/mihonapp/mihon) 项目中 WebP 图片的完整处理流程，
> 包括格式检测、解码、缓存和画廊渲染，作为 Venera 项目功耗优化的架构参考。
>
> 分析基于 Mihon v0.17.x 代码库，Coil 3.5.0，自研 `libimagedecoder` native 库。

---

## 目录

1. [整体架构概览](#1-整体架构概览)
2. [依赖与版本](#2-依赖与版本)
3. [格式检测](#3-格式检测)
4. [Native 解码层](#4-native-解码层)
5. [Coil 集成解码](#5-coil-集成解码)
6. [缓存机制](#6-缓存机制)
7. [画廊渲染层](#7-画廊渲染层)
8. [页面加载管线](#8-页面加载管线)
9. [动图 WebP 处理要点](#9-动图-webp-处理要点)
10. [Venera 对比与迁移建议](#10-venera-对比与迁移建议)

---

## 1. 整体架构概览

```
┌─ Android View / Fragment ───────────────────────────────────────────┐
│  PagerViewer / WebtoonViewer                                       │
│    ├── PagerPageHolder (ViewPager 每一页)                           │
│    └── WebtoonPageHolder (RecyclerView 每一项)                      │
│         └── ReaderPageImageView                                      │
│              ├── [静态] SubsamplingScaleImageView (SSIV)             │
│              └── [动图] PhotoView / AppCompatImageView + Coil       │
└──────────────────────────────────────────────────────────────────────┘
         │ setImage(source, isAnimated, config)
         ▼
┌─ Coil 3 ImageLoader ────────────────────────────────────────────────┐
│  components:                                                        │
│    ├── OkHttpNetworkFetcherFactory  (网络 → 原始字节流)              │
│    ├── TachiyomiImageDecoder.Factory (自定义解码器)                   │
│    ├── BufferedSourceFetcher.Factory (内存源加载器)                   │
│    └── MangaCoverFetcher.*          (封面专用加载器)                  │
│  MemoryCache: maxSizePercent(context)                               │
│  fetcher: IO(8), decoder: IO(3)                                     │
└──────────────────────────────────────────────────────────────────────┘
         │ decode()
         ▼
┌─ TachiyomiImageDecoder ────────────────────────────────────────────┐
│  delegate to: ImageDecoder.newInstance(inputStream, ...) → JNI     │
└──────────────────────────────────────────────────────────────────────┘
         │ nativeNewInstance / nativeDecode
         ▼
┌─ libimagedecoder.so (C++ native) ──────────────────────────────────┐
│  ├── libwebp  → decoder_webp.cpp  (WebP lossy/lossless/animated)   │
│  ├── libjpeg-turbo → decoder_jpeg.cpp                               │
│  ├── libpng        → decoder_png.cpp                                │
│  ├── libheif       → decoder_heif.cpp   (HEIF / AVIF)              │
│  └── libjxl        → decoder_jxl.cpp    (JPEG-XL)                  │
└──────────────────────────────────────────────────────────────────────┘
         │ 缓存层
         ▼
┌─ ChapterCache ─────────────────────────────────────────────────────┐
│  DiskLruCache (cacheDir/chapter_disk_cache/, ~50MB)                │
│  ├── putImageToCache(url, response)  → 原始HTTP响应体              │
│  ├── isImageInCache(url)             → MD5 key 检查                │
│  └── getImageFile(url)               → 返回 File inputStream       │
└──────────────────────────────────────────────────────────────────────┘
```

### 设计哲学

Mihon 的 WebP 处理遵循以下原则：

| 原则 | 体现 |
|------|------|
| **平台优先** | WebP 静态/动图均由 Android 平台或 Coil 原生支持，优先使用系统解码器 |
| **native 库兜底** | `libimagedecoder` 处理 Coil/平台不支持的格式（AVIF, JXL, HEIF）及需要裁剪白边/色彩管理的场景 |
| **缓存原始字节流** | ChapterCache 存 HTTP 响应体而非解码后 Bitmap，解码延迟到渲染时 |
| **动图不缓存** | 动图 WebP 在 Coil 中禁用 memory/disk cache，避免大内存占用 |
| **单页生命周期** | 页面离开 → ViewHolder 回收 → Decoder 释放；无全局播放数限制或 pause/resume |

---

## 2. 依赖与版本

```toml
# gradle/libs.versions.toml
coil = "3.5.0"
image-decoder = "e03b81e18a"    # GitHub commit hash

# Coil 3 相关
coil-core           = { module = "io.coil-kt.coil3:coil" }
coil-gif            = { module = "io.coil-kt.coil3:coil-gif" }
coil-compose        = { module = "io.coil-kt.coil3:coil-compose" }
coil-network-okhttp = { module = "io.coil-kt.coil3:coil-network-okhttp" }

# Native 解码器
image-decoder = { module = "com.github.mihonapp:image-decoder",
                  version.ref = "image-decoder" }
```

```kotlin
// app/build.gradle.kts
implementation(libs.image.decoder)
// JNI lib 调试符号保留
jniLibs.keepDebugSymbols += listOf("**/libimagedecoder.so")
```

Native 库源码仓库：[mihonapp/image-decoder](https://github.com/mihonapp/image-decoder)  
产物：`libimagedecoder.so`（armeabi-v7a / arm64-v8a / x86 / x86_64）

---

## 3. 格式检测

### 3.1 ImageUtil — 格式识别入口

```kotlin
// core/common/src/main/kotlin/.../ImageUtil.kt
object ImageUtil {
    
    enum class ImageType(val mime: String, val extension: String) {
        AVIF("image/avif", "avif"),
        GIF("image/gif", "gif"),
        HEIF("image/heif", "heif"),
        JPEG("image/jpeg", "jpg"),
        JXL("image/jxl", "jxl"),
        PNG("image/png", "png"),
        WEBP("image/webp", "webp"),
    }

    // 从输入流检测图片格式
    fun findImageType(stream: InputStream): ImageType? {
        return when (getImageType(stream)?.format) {
            Format.Webp -> ImageType.WEBP
            Format.Gif  -> ImageType.GIF
            // ... 其他格式
        }
    }

    // 检测是否为支持的动图
    fun isAnimatedAndSupported(source: BufferedSource): Boolean {
        val type = getImageType(source.peek().inputStream()) ?: return false
        when (type.format) {
            Format.Gif -> true
            // 动图 WebP 需要 Android 9+ (API 28+)
            Format.Webp -> type.isAnimated && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
            Format.Heif -> type.isAnimated && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
            else -> false
        }
    }

    // 核心：用 native 库读取前 32 字节文件头
    private fun getImageType(stream: InputStream): tachiyomi.decoder.ImageType? {
        val bytes = ByteArray(32)
        val length = stream.read(bytes, 0, bytes.size)
        return ImageDecoder.findType(bytes)  // JNI → C++
    }
}
```

### 3.2 Native 格式检测

`ImageDecoder.findType()` 是 JNI 调用，C++ 端通过检查文件头魔数识别格式：

| 格式 | 魔数特征 | 检测函数 |
|------|----------|----------|
| **WebP** | `RIFF....WEBP` (前12字节) | `is_webp(data)` |
| JPEG | `FF D8 FF` | `is_jpeg(data)` |
| PNG | `89 50 4E 47` | `is_png(data)` |
| GIF | `47 49 46 38` | `is_gif(data)` |
| JXL | `FF 0A` 或 `00 00 00 0C JXL` | `is_jxl(data)` |

对于 WebP，进一步解析 `VP8X` chunk 的 bits 以判断是否为动图（`isAnimated` 标志）。

---

## 4. Native 解码层

### 4.1 JNI 桥接

```kotlin
// 外部仓库: library/src/main/java/tachiyomi/decoder/ImageDecoder.kt
class ImageDecoder {
    companion object {
        init { System.loadLibrary("imagedecoder") }
        
        /** 检测图片格式（仅读文件头） */
        external fun findType(data: ByteArray): ImageType?
    }
    
    /** 创建解码器实例。cropBorders=自动裁剪白边; displayProfile=色彩管理 */
    external fun newInstance(
        inputStream: InputStream,
        cropBorders: Boolean = false,
        displayProfile: ByteArray? = null
    ): ImageDecoder
    
    /** 解码到 Android Bitmap。sampleSize=采样率 >= 1 */
    external fun decode(sampleSize: Int = 1): Bitmap?
    
    /** 释放 native 资源 */
    external fun recycle()
    
    val width: Int   // native decode 后回填
    val height: Int
}
```

### 4.2 WebP 解码器（C++ `decoder_webp.cpp`）

`decoder_webp.cpp/h` 使用 **libwebp** 解码，核心流程：

```
newInstance()
  ├── WebPAnimDecoderOptionsInit() / WebPDemux()
  ├── 解析 VP8X chunk → 获取 width/height/动画标志
  ├── [动图] → WebPAnimDecoderNew() + WebPAnimDecoderGetInfo()
  └── [静态] → WebPDecoder() 备选

decode(sampleSize)
  ├── [静态] → WebPDecodeRGBA(data, dataSize, &width, &height) 
  │             或 WebPIDecode() 带采样缩放
  ├── [动图] → WebPAnimDecoderGetNext() → frame buffer
  ├── 像素格式转换: RGBA → Android Bitmap (ARGB_8888)
  ├── [可选] cropBorders: 自动检测+裁剪白色/黑色边框
  └── 通过 AndroidBitmap_lockPixels() 写入 Bitmap

recycle()
  ├── WebPAnimDecoderDelete()
  └── 释放所有内部 buffer
```

**libwebp 使用版本**：通过 CMake `FetchContent` 编译的嵌入版 libwebp，支持：
- Lossy WebP (VP8)
- Lossless WebP (VP8L)
- Animated WebP (VP8X + ANIM)
- 多帧解码（`WebPAnimDecoderGetNext`）
- 任意比例采样缩放

### 4.3 采样解码（降采样加速）

```kotlin
// TachiyomiImageDecoder.kt
val sampleSize = DecodeUtils.calculateInSampleSize(
    srcWidth, srcHeight, dstWidth, dstHeight, scale
)
var bitmap = decoder.decode(sampleSize = sampleSize)
```

`sampleSize` 是 2 的幂（1, 2, 4, 8...），C++ 端的 libwebp 按此比例缩小解码：
- `sampleSize=1`：完整分辨率
- `sampleSize=2`：1/2 宽高 → 1/4 像素 → 1/4 内存
- 有效降低 WebP 解码内存峰值和耗时

### 4.4 Hardware Bitmap 优化

解码后尝试将 Bitmap 升级为 `HARDWARE` Config：

```kotlin
if (options.bitmapConfig == Bitmap.Config.HARDWARE && ImageUtil.canUseHardwareBitmap(bitmap)) {
    val hwBitmap = bitmap.copy(Bitmap.Config.HARDWARE, false)
    if (hwBitmap != null) {
        bitmap.recycle()
        bitmap = hwBitmap
    }
}
```

- **HARDWARE Bitmap** 存储在 GPU 内存而非 heap，减少 Java heap 压力
- 硬件阈值 `hardwareBitmapThreshold` = `GLUtil.SAFE_TEXTURE_LIMIT`
- 兼容性黑名单 `HARDWARE_BITMAP_UNSUPPORTED`（从 Coil 摘录，涵盖损坏的 HARDWARE 实现设备）

---

## 5. Coil 集成解码

### 5.1 ImageLoader 初始化

```kotlin
// App.kt
override fun newImageLoader(context: Context): ImageLoader {
    return ImageLoader.Builder(this).apply {
        components {
            add(OkHttpNetworkFetcherFactory(callFactoryLazy::value))  // 网络源
            add(TachiyomiImageDecoder.Factory())                      // 自定义解码器
            add(BufferedSourceFetcher.Factory())                      // BufferedSource 源
            add(MangaCoverFetcher.MangaCoverFactory(...))             // 封面源
            add(MangaCoverFetcher.MangaFactory(...))
            add(MangaCoverKeyer())
            add(MangaKeyer())
        }
        memoryCache(MemoryCache.Builder().maxSizePercent(context).build())
        crossfade((300 * animatorDurationScale).toInt())
        allowRgb565(DeviceUtil.isLowRamDevice(this@App))
        fetcherCoroutineContext(Dispatchers.IO.limitedParallelism(8))
        decoderCoroutineContext(Dispatchers.IO.limitedParallelism(3))
    }.build()
}
```

### 5.2 TachiyomiImageDecoder — 自定义 Coil Decoder

```kotlin
// data/coil/TachiyomiImageDecoder.kt
class TachiyomiImageDecoder(
    private val resources: ImageSource, 
    private val options: Options
) : Decoder {

    override suspend fun decode(): DecodeResult {
        // 1. 创建 native 解码器（传入 cropBorders 和 displayProfile）
        val decoder = resources.sourceOrNull()?.use {
            ImageDecoder.newInstance(it.inputStream(), options.cropBorders, displayProfile)
        }
        
        // 2. 计算降采样率
        val sampleSize = DecodeUtils.calculateInSampleSize(
            srcWidth, srcHeight, dstWidth, dstHeight, options.scale
        )
        
        // 3. Native 解码
        var bitmap = decoder.decode(sampleSize = sampleSize)
        decoder.recycle()
        
        // 4. 尝试 HARDWARE Bitmap
        if (options.bitmapConfig == HARDWARE && canUseHardwareBitmap(bitmap)) {
            bitmap = bitmap.copy(HARDWARE, false) ?: bitmap
        }
        
        return DecodeResult(image = bitmap.asImage(), isSampled = sampleSize > 1)
    }

    class Factory : Decoder.Factory {
        override fun create(result, options, loader): Decoder? {
            // 触发条件：customDecoder 标记 或 格式为 AVIF/JXL/HEIF
            return if (options.customDecoder || isApplicable(result.source.source())) {
                TachiyomiImageDecoder(result.source, options)
            } else null
        }

        private fun isApplicable(source: BufferedSource): Boolean {
            return when (ImageUtil.findImageType(it)) {
                // 系统/Coil 不支持的格式，强制走 native 解码
                ImageType.AVIF, ImageType.JXL, ImageType.HEIF -> true
                else -> false   // WebP/GIF/JPEG/PNG → Coil 原生解码
            }
        }
    }
}
```

### 5.3 解码器选择策略

| 格式 | Coil 原生 | 走自定义解码器 | 原因 |
|------|-----------|---------------|------|
| **WebP 静态** | ✅ 是 | 仅当 `customDecoder=true` | Coil 3 + Android 原生支持 |
| **WebP 动图** | ✅ (API 28+) | 同上 | Coil 3 支持 AnimatedWebPDrawable |
| **GIF** | ✅ 是 | 否 | Coil 3 原生 |
| **JPEG/PNG** | ✅ 是 | 否 | 系统解码器最优 |
| **AVIF** | ❌ 否 | ✅ 是 | 需 libheif |
| **JXL** | ❌ 否 | ✅ 是 | 需 libjxl |
| **HEIF** | ❌ 否 | ✅ 是 | 需 libheif |

**关键决策**：WebP 使用 Coil 原生解码器可以：
- 减少 JNI 调用开销
- 利用 Coil 的动图框架（AnimatedDrawable）自动处理帧调度
- 获得 Coil 的内存缓存支持（静态 WebP）

### 5.4 自定义 Coil 扩展

```kotlin
// data/coil/Utils.kt
// 自定义 extras key，用于在 ImageRequest 中传递指令

fun ImageRequest.Builder.cropBorders(enable: Boolean) = apply {
    extras[cropBordersKey] = enable  
}
val Options.cropBorders: Boolean
    get() = getExtra(cropBordersKey)

fun ImageRequest.Builder.customDecoder(enable: Boolean) = apply {
    extras[customDecoderKey] = enable
}
val Options.customDecoder: Boolean
    get() = getExtra(customDecoderKey)
```

---

## 6. 缓存机制

### 6.1 三层缓存架构

```
┌─────────────────────────────────────────────────────────┐
│  Coil MemoryCache                                        │
│  作用: 已解码的 Bitmap，LRU 淘汰                          │
│  大小: maxSizePercent(context) → 应用堆的百分比           │
│  内容: 静态 WebP 解码后的 Bitmap                          │
│  动图: CachePolicy.DISABLED → 不缓存                     │
├─────────────────────────────────────────────────────────┤
│  Coil DiskCache (可选)                                    │
│  作用: 已解码的图片文件，跨进程共享                        │
│  位置: image_loader_cache/                                │
│  Mihon 中未显式配置                                       │
├─────────────────────────────────────────────────────────┤
│  ChapterCache (DiskLruCache)                              │
│  作用: 原始 HTTP 响应体（未解码字节流）                    │
│  位置: cacheDir/chapter_disk_cache/                       │
│  大小: 50MB，LRU 淘汰                                     │
│  内容: MD5(imageUrl).0 文件                               │
└─────────────────────────────────────────────────────────┘
```

### 6.2 ChapterCache 实现

```kotlin
// data/cache/ChapterCache.kt
class ChapterCache(context: Context, json: Json) {
    
    private val diskCache = DiskLruCache.open(
        File(context.cacheDir, "chapter_disk_cache"),
        APP_VERSION = 1,
        VALUE_COUNT = 1,
        maxSize = 50 * 1024 * 1024  // 50MB
    )

    /** 缓存图片 (原始 HTTP 响应体) */
    fun putImageToCache(imageUrl: String, response: Response) {
        val key = DiskUtil.hashKeyForDisk(imageUrl)
        diskCache.edit(key)?.apply {
            response.body.source().saveTo(newOutputStream(0))
            commit()
        }
    }

    /** 检查图片是否在缓存中 */
    fun isImageInCache(imageUrl: String): Boolean {
        val key = DiskUtil.hashKeyForDisk(imageUrl)
        return diskCache.get(key).use { it != null } && getImageFile(imageUrl).exists()
    }

    /** 获取缓存图片文件 */
    fun getImageFile(imageUrl: String): File {
        return File(diskCache.directory, DiskUtil.hashKeyForDisk(imageUrl) + ".0")
    }

    /** 缓存章节页面列表 (JSON) */
    fun putPageListToCache(chapter: Chapter, pages: List<Page>) { ... }
    fun getPageListFromCache(chapter: Chapter): List<Page> { ... }

    /** 清除整个缓存 */
    fun clear(): Int { ... }
}
```

**设计特点**：
- 缓存的是**未解码的原始字节流**（HTTP 响应 body），而非解码后的 Bitmap
- 解码延迟到渲染阶段，避免 JPEG/PNG/WebP 解码格式与缓存的耦合
- DiskLruCache 自带 LRU 淘汰和 journal 恢复
- MD5 作为 key 避免 URL 中的特殊字符问题

### 6.3 封面缓存（CoverCache）

漫画封面走单独的 `MangaCoverFetcher` + 专用磁盘目录：

```kotlin
class MangaCoverFetcher(...) : Fetcher {
    override suspend fun fetch(): FetchResult {
        // 1. 本地缓存命中 → 直接返回文件
        if (libraryCoverCacheFile?.exists() == true && diskCache.readEnabled) {
            return fileLoader(libraryCoverCacheFile)
        }
        // 2. 下载并写入封面缓存
        val response = source.getMangaCover(manga)
        writeResponseToCoverCache(response, libraryCoverCacheFile)
        return fileLoader(responseCoverCache)
    }
}
```

### 6.4 动图缓存策略

动图 WebP **明确禁用 Coil 缓存**：

```kotlin
// ReaderPageImageView.kt — setAnimatedImage()
val request = ImageRequest.Builder(context)
    .data(data)
    .memoryCachePolicy(CachePolicy.DISABLED)   // 动图不缓存 Bitmap
    .diskCachePolicy(CachePolicy.DISABLED)      // 动图不缓存文件
    // ...
```

原因：
- 动图 Bitmap 帧数量多，内存占用极高
- 动图通常不会短时间内重复访问
- 重新解码（~50ms）比维护大缓存更经济

---

## 7. 画廊渲染层

### 7.1 ReaderPageImageView — 双模式渲染容器

```kotlin
// ui/reader/viewer/ReaderPageImageView.kt
open class ReaderPageImageView(...) : FrameLayout {

    private var pageView: View? = null

    fun setImage(source: BufferedSource, isAnimated: Boolean, config: Config) {
        this.config = config
        if (isAnimated) {
            prepareAnimatedImageView()
            setAnimatedImage(source, config)
        } else {
            prepareNonAnimatedImageView()
            setNonAnimatedImage(source, config)
        }
    }
}
```

| 图片类型 | 渲染控件 | 特性 |
|----------|----------|------|
| **静态**（含静态 WebP） | `SubsamplingScaleImageView` (SSIV) | 超大图分块加载、Region 解码、缩放、平移、最小 DPI 控制 |
| **动图**（含动图 WebP） | `PhotoView` (标准) / `AppCompatImageView` (Webtoon) | 缩放、平移、Coil 动图播放 |

### 7.2 静态图片渲染（SSIV）

```kotlin
private fun setNonAnimatedImage(data: Any, config: Config) {
    (pageView as? SubsamplingScaleImageView)?.apply {
        setDoubleTapZoomDuration(config.zoomDuration)
        setMinimumScaleType(config.minimumScaleType)  // CENTER_INSIDE / FIT_WIDTH
        setCropBorders(config.cropBorders)
        
        when (data) {
            is BitmapDrawable -> setImage(ImageSource.bitmap(data.bitmap))
            is BufferedSource -> {
                // 普通模式：直接传给 SSIV 的 BitmapRegionDecoder
                setHardwareConfig(ImageUtil.canUseHardwareBitmap(data))
                setImage(ImageSource.inputStream(data.inputStream()))
                
                // Webtoon + 长条图：走 Coil 加载（带 customDecoder=true）
                // 因为长条图用 SSIV 的 Region 解码更高效
            }
        }
    }
}
```

`SubsamplingScaleImageView`（开源库）提供了：
- 基于 `BitmapRegionDecoder` 的分块懒加载
- 只解码屏幕可见区域的 tile
- 对超大 WebP 静态图内存友好
- 支持 hardware Bitmap 配置

### 7.3 动图渲染（PhotoView + Coil）

```kotlin
private fun setAnimatedImage(data: Any, config: Config) {
    (pageView as? AppCompatImageView)?.apply {
        val request = ImageRequest.Builder(context)
            .data(data)
            .memoryCachePolicy(CachePolicy.DISABLED)
            .diskCachePolicy(CachePolicy.DISABLED)
            .target(onSuccess = { result ->
                val drawable = result.asDrawable(context.resources)
                setImageDrawable(drawable)
                (drawable as? Animatable)?.start()    // Coil 自带动图控制
                onImageLoaded()
            })
            .listener(onError = { _, result -> onImageLoadError(result.throwable) })
            .crossfade(false)   // 动图不要 crossfade
            .build()
        context.imageLoader.enqueue(request)
    }
}
```

**动图播放特点**：
- 完全委托给 Coil 3 的动图框架（AnimatedDrawable）
- Coil 内部处理帧调度、帧间延迟、循环计数
- ViewPager 滚动时调用 `recycle()` → `dispose()` 停止播放
- 不缓存动图帧到内存/磁盘

### 7.4 页面回收

```kotlin
fun recycle() = pageView?.let {
    when (it) {
        is SubsamplingScaleImageView -> it.recycle()     // 释放 SSIV 资源
        is AppCompatImageView -> it.dispose()             // 取消 Coil 请求
    }
    it.isVisible = false
}
```

当 ViewPager 页面滑出时：
1. `PagerPageHolder.onDetachedFromWindow()` → 取消 `loadJob`
2. `recycle()` → 释放 SSIV tile 缓存 / 取消 Coil ImageRequest
3. ViewHolder 被回收，等待复用或 GC

### 7.5 自动背景色选择

对于非动图，Mihon 会分析图片边缘像素来选择合适的背景色：

```kotlin
// PagerPageHolder.kt
val background = if (!isAnimated && viewer.config.automaticBackground) {
    ImageUtil.chooseBackground(context, source.peek().inputStream())
} else null
// ...
pageBackground = background  // 在 onImageLoaded 时设置
```

算法：
- 采样 8 个边角/边缘像素
- 根据明暗分布和连续色块判断是黑底还是白底
- 支持渐变色过渡（如黑→黑→白→白）
- 对漫画/黑白页效果最佳

---

## 8. 页面加载管线

### 8.1 PageLoader 抽象

```kotlin
// ui/reader/loader/PageLoader.kt
abstract class PageLoader {
    abstract var isLocal: Boolean
    abstract suspend fun getPages(): List<ReaderPage>
    open suspend fun loadPage(page: ReaderPage) {}
    open fun retryPage(page: ReaderPage) {}
    open fun recycle() { isRecycled = true }
}
```

### 8.2 四种 PageLoader 实现

| Loader | 来源 | isLocal | 特征 |
|--------|------|---------|------|
| **HttpPageLoader** | 网络在线章节 | false | 优先读 HTTP → ChapterCache |
| **DownloadPageLoader** | 已下载章节 | true | 本地文件/存档 |
| **ArchivePageLoader** | CBZ/CBR/EPUB 存档 | true | 读压缩包内文件流 |
| **DirectoryPageLoader** | 本地目录 | true | 直接读取文件 |

### 8.3 HttpPageLoader — 网络页面加载

```kotlin
// ui/reader/loader/HttpPageLoader.kt
internal class HttpPageLoader(
    private val chapter: ReaderChapter,
    private val source: HttpSource,
    private val chapterCache: ChapterCache,
) : PageLoader() {

    private val preloadSize = 4  // 当前页后预加载 4 页
    private val queue = PriorityBlockingQueue<PriorityPage>()

    // 预加载下一页逻辑
    private fun preloadNextPages(currentPage: ReaderPage, amount: Int): List<PriorityPage> {
        val pageIndex = currentPage.index
        val pages = currentPage.chapter.pages ?: return emptyList()
        return pages.subList(pageIndex + 1, min(pageIndex + 1 + amount, pages.size))
            .mapNotNull { if (it.status == Queue) PriorityPage(it, ADJACENT).also { queue.offer(it) } else null }
    }

    // 页面下载核心
    private suspend fun internalLoadPage(page: ReaderPage, force: Boolean) {
        if (page.imageUrl.isNullOrEmpty()) {
            page.status = LoadPage
            page.imageUrl = source.getImageUrl(page)
        }
        if (force || !chapterCache.isImageInCache(imageUrl)) {
            page.status = DownloadImage
            val imageResponse = source.getImage(page)
            chapterCache.putImageToCache(imageUrl, imageResponse)  // 缓存原始字节
        }
        page.stream = { chapterCache.getImageFile(imageUrl).inputStream() }
        page.status = Ready
    }
}
```

**优先级队列**：
```
RETRY   = 2   // 用户手动重试 → 最高优先级
DEFAULT = 1   // 当前需要显示的页
ADJACENT = 0  // 预加载的相邻页 → 最低优先级
```

### 8.4 PagerPageHolder — 页面加载与渲染桥接

```kotlin
// 生命周期: init → loadPageAndProcessStatus → setImage → recycle

private suspend fun loadPageAndProcessStatus() {
    val loader = page.chapter.pageLoader ?: return
    supervisorScope {
        launchIO { loader.loadPage(page) }           // 后台加载
        page.statusFlow.collectLatest { state ->     // 监听状态变化
            when (state) {
                Queue   → showProgressBar()
                LoadPage → showProgressBar()
                DownloadImage → showProgressBar(progress)
                Ready  → setImage()                  // 渲染
                is Error → showError()
            }
        }
    }
}

private suspend fun setImage() {
    val streamFn = page.stream ?: return
    
    val (source, isAnimated, background) = withIOContext {
        val source = streamFn().use { Buffer().readFrom(it) }
        val isAnimated = ImageUtil.isAnimatedAndSupported(source)  // 格式+动图检测
        val background = if (!isAnimated && automaticBackground) 
            ImageUtil.chooseBackground(context, source.peek().inputStream()) 
        else null
        Triple(source, isAnimated, background)
    }
    
    withUIContext {
        setImage(source, isAnimated, Config(...))  // 渲染
        if (!isAnimated) pageBackground = background  // 设背景色
    }
}
```

### 8.5 完整数据流

```
用户滑动到第 N 页
  │
  ├── PagerPageHolder.init()
  │     └── launch { loadPageAndProcessStatus() }
  │
  ├── launchIO { loader.loadPage(page) }
  │     │
  │     ├── imageUrl 为空? → source.getImageUrl(page)
  │     ├── 缓存未命中? → source.getImage(page) → chapterCache.putImageToCache()
  │     ├── page.stream = chapterCache.getImageFile(url).inputStream()
  │     └── page.status = Ready
  │
  ├── collectLatest { state ->
  │     └── Ready → setImage()
  │           │
  │           └── withIOContext {
  │                 ├── Buffer().readFrom(stream)  → 读取原始字节
  │                 ├── ImageUtil.isAnimatedAndSupported()  → 动图检测
  │                 └── ImageUtil.chooseBackground()  → 背景色分析
  │               }
  │               withUIContext {
  │                 ├── setImage(source, isAnimated, config)
  │                 │     ├── [静态] prepareNonAnimatedImageView()
  │                 │     │        └── SSIV.setImage(inputStream)
  │                 │     └── [动图] prepareAnimatedImageView()
  │                 │              └── Coil ImageRequest → PhotoView
  │                 └── pageBackground = background
  │               }
  │
  └── 预加载 N+1 ~ N+4 页 (低优先级)
        └── preloadNextPages(currentPage, 4)
```

---

## 9. 动图 WebP 处理要点

### 9.1 关键差异：静态 vs 动图

| 方面 | 静态 WebP | 动图 WebP |
|------|-----------|-----------|
| 渲染控件 | `SubsamplingScaleImageView` | `PhotoView` / `AppCompatImageView` |
| 解码器 | Coil 原生 / SSIV RegionDecoder | Coil 原生 AnimatedDrawable |
| 内存缓存 | Coil MemoryCache 缓存 | `CachePolicy.DISABLED` |
| 磁盘缓存 | ChapterCache 缓存原始字节 | 同左（原始字节缓存不受影响） |
| 背景色 | `chooseBackground()` 自动计算 | 无背景色（白色兜底） |
| 缩放 | SSIV 支持最大 5x 缩放 | PhotoView 支持 2x/5x 双级缩放 |
| 预加载 | 4 页预先下载字节流 | 同左 |
| 动画控制 | — | Coil 内部帧调度 + Animatable.start() |

### 9.2 与 Venera 当前方案的对比

| 对比维度 | Mihon (参考) | Venera (当前) | 说明 |
|----------|-------------|---------------|------|
| **解码库** | libwebp (native) | libwebp (native) | 相同底层库 |
| **解码调用** | Coil 原生解码 / JNI | Dart FFI + Isolate | Mihon 无 Isolate 开销 |
| **动图帧缓存** | 不缓存（Coil 内部管理） | 用户态输出环缓冲 (8帧) | Mihon 更简洁 |
| **全局播放数限制** | 无 | _maxPlaying=6 | Mihon 无此设计 |
| **pause/resume** | 无（页面离开即销毁） | 有（轮询 hasListeners） | Mihon 模型更简单 |
| **页面预加载** | loadPage (4页原始字节) | precacheImage (GPU 帧) | Mihon 粗粒度，Venera 细粒度 |
| **渲染控件** | SSIV / PhotoView | RawImage / CustomPainter | 平台差异 |
| **缓存架构** | 3层 (ChapterCache+Coil) | ImageCache + 手动管理 | Mihon 更成熟 |
| **Hardware Bitmap** | 支持（GPU 内存） | 不适用 (Flutter) | Flutter 自有纹理系统 |
| **色彩管理** | displayProfile 支持 | 无 | Mihon 支持 ICC profile |
| **白边裁剪** | cropBorders 选项 | 无 | Mihon native 层支持 |

### 9.3 从 Mihon 可借鉴的原则

1. **不做全局播放数限制** — 页面生命周期天然控制并发数
2. **不用 pause/resume** — 页面离开直接销毁，回来重建（~50ms 可接受）
3. **动图不缓存** — 解码开销低于缓存维护开销，且减少内存峰值
4. **缓存原始字节流** — 与解码格式解耦，灵活切换解码策略
5. **延迟解码** — 字节流加载与 UI 状态解耦，状态驱动渲染
6. **单页生命周期** — 每个页面的加载/解码/渲染有明确的作用域和清理点
7. **无用户态帧队列** — 委托给平台/Coil 管理帧调度，减少复杂度和 bug

---

## 10. Venera 对比与迁移建议

### 10.1 架构差异映射

```
Android (Mihon)                      Flutter (Venera)
─────────────────                    ────────────────
ChapterCache (原始字节)                Disk cache (原始字节)
Coil ImageLoader                      cachedNetworkImage / 自定义
TachiyomiImageDecoder                 WebPAnimDecoder (FFI)
SubsamplingScaleImageView             InteractiveViewer (静态)
PhotoView + AnimatedDrawable          RawImage + 帧调度 (动图)
ViewPager + PagerPageHolder           PageView + 页面 Widget
RecyclerView + WebtoonPageHolder      ListView + Webtoon 项
PagerViewer.setChapters()             _setViewerPageViaPager()
page.statusFlow (StateFlow)           page.completer (Completer)
ImageUtil.isAnimatedAndSupported()    文件头检测 (FFI / Dart)
```

### 10.2 建议优先采纳的点

| 优先级 | 改动 | 来源参考 | 预期收益 |
|--------|------|----------|----------|
| **P0** | 移除全局 _maxPlaying 上限 | Mihon 无此设计 | 消除"翻页后动画暂停"问题 |
| **P0** | 移除 pause/resume + hasListeners 轮询 | 页面离开 → dispose | 减少 1s 轮询开销和卡顿 |
| **P1** | 动图不缓存 GPU 帧 | CachePolicy.DISABLED | 减少 160MB+ 峰值内存 |
| **P1** | 页面离开直接销毁 decoder | recycle() 模式 | 简化生命周期，消除 use-after-free |
| **P2** | 预加载改为原始字节预下载 | HttpPageLoader.preloadSize | 降低 GPU 帧预上传复杂度 |
| **P2** | 合并 Completer 与 Widget 生命周期 | PagerPageHolder scoped job | 消除 completer 泄漏 |

### 10.3 保持 Venera 的优势

| 优势 | 说明 |
|------|------|
| **Flutter Isolate** | 主线程不被 native 解码阻塞，Mihon 用 IO Dispatcher 但无真正并行 |
| **帧精确控制** | Venera 的输出环缓冲（8帧）可有效防止撕裂，Mihon 靠 Coil 内部管理 |
| **DPR 处理** | Venera 已有物理分辨率正确映射，Mihon 用 Density 计算但无 DPR 归一化 |
| **GPU 预上传** | Virtua 预上传 GPU 纹理可实现在 Mihon 中做不到的瞬间显示 |

---

> 本文档基于 Mihon 代码库分析生成，用于指导 Venera 项目 WebP 动画架构优化。
> 分析关键文件：
> - `core/common/.../ImageUtil.kt` — 格式检测/动图识别/背景色算法
> - `data/coil/TachiyomiImageDecoder.kt` — Coil 3 自定义解码器
> - `data/coil/Utils.kt` — Coil 扩展属性
> - `data/cache/ChapterCache.kt` — 原始字节磁盘缓存
> - `ui/reader/viewer/ReaderPageImageView.kt` — 双模式渲染容器
> - `ui/reader/viewer/pager/PagerPageHolder.kt` — 页面加载桥接
> - `ui/reader/viewer/pager/PagerViewer.kt` — ViewPager 画廊
> - `ui/reader/loader/HttpPageLoader.kt` — 网络页面加载管线
> - `App.kt` — Coil ImageLoader 配置
> - Native 库: [mihonapp/image-decoder](https://github.com/mihonapp/image-decoder)
