package com.github.wgh136.venera

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Color
import android.graphics.PointF
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import com.paddle.ocr.EngineConfig
import com.paddle.ocr.PaddleOCR
import com.paddle.ocr.PaddleOCRConfig
import com.paddle.ocr.model.OCRRunResult
import com.paddle.ocr.postprocess.BubbleSegmenter
import com.paddle.ocr.util.OpenCVUtils
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.sqrt

class ComicTranslationOcrPlugin(
    context: Context,
    flutterEngine: FlutterEngine,
) : MethodChannel.MethodCallHandler {
    private val appContext = context.applicationContext
    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        "venera/comic_translation_ocr",
    )
    private val mainHandler = Handler(Looper.getMainLooper())
    private val dispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private var ocr: PaddleOCR? = null
    private lateinit var modelPaths: _ModelPaths
    private lateinit var engineConfig: EngineConfig
    private var activeRecognition = ""
    private var maxAnalysisSide = 1600

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "load" -> execute(result) { load(call); null }
            "recognize" -> execute(result) { recognize(call) }
            "unload" -> execute(result) { unload(); null }
            else -> result.notImplemented()
        }
    }

    private suspend fun load(call: MethodCall) {
        OpenCVUtils.init()
        ocr?.release()
        val maxSide = call.argument<Number>("maxAnalysisSide")!!.toInt()
        maxAnalysisSide = maxSide
        engineConfig = EngineConfig(call.argument<Number>("threads")!!.toInt())
        modelPaths = _ModelPaths(
            detection = call.argument<String>("detModelPath")!!,
            defaultRecognition = call.argument<String>("recModelPath")!!,
            defaultConfig = call.argument<String>("recConfigPath")!!,
            koreanRecognition = call.argument<String>("koreanRecModelPath")!!,
            koreanConfig = call.argument<String>("koreanRecConfigPath")!!,
        )
        activeRecognition = recognitionFor(call.argument<String>("sourceLanguage")!!)
        ocr = if (activeRecognition == "korean") {
            createOcr(modelPaths.koreanRecognition, modelPaths.koreanConfig)
        } else {
            createOcr(modelPaths.defaultRecognition, modelPaths.defaultConfig)
        }
    }

    private suspend fun createOcr(recognition: String, config: String) = PaddleOCR.create(
        appContext,
        PaddleOCRConfig(
            detLimitSideLen = maxAnalysisSide,
            detLimitType = "max",
            detMaxSideLimit = maxAnalysisSide,
            detBoxThresh = 0.45f,
            detUnclipRatio = 1.4f,
            recScoreThresh = 0.35f,
            recBatchSize = 4,
        ),
        engineConfig,
        modelPaths.detection,
        recognition,
        config,
    )

    private fun recognitionFor(sourceLanguage: String) =
        if (sourceLanguage.substringBefore('-').substringBefore('_') == "ko") {
            "korean"
        } else {
            "default"
        }

    private suspend fun selectRecognition(sourceLanguage: String) {
        val target = recognitionFor(sourceLanguage)
        if (activeRecognition == target) return
        ocr!!.release()
        ocr = null
        activeRecognition = ""
        ocr = if (target == "korean") {
            createOcr(modelPaths.koreanRecognition, modelPaths.koreanConfig)
        } else {
            createOcr(modelPaths.defaultRecognition, modelPaths.defaultConfig)
        }
        activeRecognition = target
    }

    private suspend fun recognize(call: MethodCall): Map<String, Any> {
        selectRecognition(call.argument<String>("sourceLanguage")!!)
        val file = File(call.argument<String>("filePath")!!)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            error("Unsupported image: ${file.path}")
        }
        val scaledWidth = bounds.outWidth.toLong() * maxAnalysisSide / bounds.outHeight
        val page = if (bounds.outHeight > maxAnalysisSide && scaledWidth < 900) {
            recognizeTiled(file, bounds.outWidth, bounds.outHeight)
        } else {
            recognizeSingle(file, bounds.outWidth, bounds.outHeight)
        }
        return page.toMap()
    }

    private suspend fun recognizeSingle(file: File, width: Int, height: Int): _PageResult {
        val sample = sampleFor(maxOf(width, height))
        val bitmap = BitmapFactory.decodeFile(file.path, bitmapOptions(sample))
            ?: error("Unsupported image: ${file.path}")
        return try {
            val metrics = _RunMetrics()
            val regions = recognizeBitmap(bitmap, Rect(0, 0, width, height), metrics)
            _PageResult(width, height, 1, metrics, regions)
        } finally {
            bitmap.recycle()
        }
    }

    @Suppress("DEPRECATION")
    private suspend fun recognizeTiled(file: File, width: Int, height: Int): _PageResult {
        val sample = sampleFor(width)
        val tileHeight = maxAnalysisSide * sample
        val overlap = minOf(256 * sample, tileHeight / 2)
        val decoder = BitmapRegionDecoder.newInstance(file.path, false)
        val metrics = _RunMetrics()
        val regions = mutableListOf<_RecognizedRegion>()
        var tiles = 0
        var top = 0
        try {
            while (top < height) {
                val bottom = minOf(top + tileHeight, height)
                val source = Rect(0, top, width, bottom)
                val bitmap = decoder.decodeRegion(source, bitmapOptions(sample))
                    ?: error("Cannot decode OCR tile: ${file.path} y=$top")
                try {
                    val ownedTop = if (top == 0) 0f else (top + overlap / 2).toFloat()
                    val ownedBottom = if (bottom == height) height.toFloat()
                    else (bottom - overlap / 2).toFloat()
                    regions += recognizeBitmap(bitmap, source, metrics).filter {
                        it.points.sumOf { point -> point.y.toDouble() }.toFloat() / it.points.size in
                            ownedTop..<ownedBottom
                    }
                } finally {
                    bitmap.recycle()
                }
                tiles++
                if (bottom == height) break
                top = bottom - overlap
            }
        } finally {
            decoder.recycle()
        }
        regions.sortWith(compareBy({ it.points.minOf { point -> point.y } },
            { it.points.minOf { point -> point.x } }))
        return _PageResult(width, height, tiles, metrics, regions)
    }

    private suspend fun recognizeBitmap(
        bitmap: Bitmap,
        source: Rect,
        metrics: _RunMetrics,
    ): List<_RecognizedRegion> {
        val value = ocr!!.recognize(bitmap)
        metrics.add(value)
        val backgrounds = value.results.map {
            estimateBackground(bitmap, it.box.points)
        }
        val segmentationStart = System.currentTimeMillis()
        val bubbles = BubbleSegmenter.segment(
            bitmap,
            value.results.map { it.box },
            backgrounds,
        )
        metrics.bubbleSegmentationMs += System.currentTimeMillis() - segmentationStart
        val scaleX = source.width().toFloat() / bitmap.width
        val scaleY = source.height().toFloat() / bitmap.height
        return value.results.mapIndexed { index, region ->
            _RecognizedRegion(
                text = region.text,
                confidence = region.confidence,
                backgroundArgb = backgrounds[index],
                points = region.box.points.map { point ->
                    PointF(source.left + point.x * scaleX, source.top + point.y * scaleY)
                },
                bubblePoints = bubbles[index]?.map { point ->
                    PointF(source.left + point.x * scaleX, source.top + point.y * scaleY)
                },
            )
        }
    }

    private fun sampleFor(length: Int): Int {
        var sample = 1
        while (length / (sample * 2) >= maxAnalysisSide) sample *= 2
        return sample
    }

    private fun bitmapOptions(sample: Int) = BitmapFactory.Options().apply {
        inSampleSize = sample
        inPreferredConfig = Bitmap.Config.ARGB_8888
    }

    private fun estimateBackground(bitmap: android.graphics.Bitmap, points: List<PointF>): Int {
        val left = floor(points.minOf { it.x }.toDouble()).toInt().coerceIn(0, bitmap.width - 1)
        val top = floor(points.minOf { it.y }.toDouble()).toInt().coerceIn(0, bitmap.height - 1)
        val right = ceil(points.maxOf { it.x }.toDouble()).toInt().coerceIn(left + 1, bitmap.width)
        val bottom = ceil(points.maxOf { it.y }.toDouble()).toInt().coerceIn(top + 1, bitmap.height)
        val step = sqrt(((right - left) * (bottom - top) / 1024.0).coerceAtLeast(1.0))
            .toInt().coerceAtLeast(1)
        val count = IntArray(4096)
        val red = LongArray(4096)
        val green = LongArray(4096)
        val blue = LongArray(4096)
        for (y in top until bottom step step) {
            for (x in left until right step step) {
                val color = bitmap.getPixel(x, y)
                val r = Color.red(color)
                val g = Color.green(color)
                val b = Color.blue(color)
                val bucket = (r shr 4 shl 8) or (g shr 4 shl 4) or (b shr 4)
                count[bucket]++
                red[bucket] += r.toLong()
                green[bucket] += g.toLong()
                blue[bucket] += b.toLong()
            }
        }
        val bucket = count.indices.maxBy { count[it] }
        return Color.rgb(
            (red[bucket] / count[bucket]).toInt(),
            (green[bucket] / count[bucket]).toInt(),
            (blue[bucket] / count[bucket]).toInt(),
        )
    }

    private data class _RecognizedRegion(
        val text: String,
        val confidence: Float,
        val backgroundArgb: Int,
        val points: List<PointF>,
        val bubblePoints: List<PointF>?,
    )

    private data class _ModelPaths(
        val detection: String,
        val defaultRecognition: String,
        val defaultConfig: String,
        val koreanRecognition: String,
        val koreanConfig: String,
    )

    private data class _PageResult(
        val width: Int,
        val height: Int,
        val tiles: Int,
        val metrics: _RunMetrics,
        val regions: List<_RecognizedRegion>,
    ) {
        fun toMap(): Map<String, Any> = mapOf(
            "width" to width,
            "height" to height,
            "tiles" to tiles,
            "detectionMs" to metrics.detectionMs,
            "recognitionMs" to metrics.recognitionMs,
            "totalMs" to metrics.totalMs,
            "detPreprocessMs" to metrics.detPreprocessMs,
            "detInferenceMs" to metrics.detInferenceMs,
            "detPostprocessMs" to metrics.detPostprocessMs,
            "recPreprocessMs" to metrics.recPreprocessMs,
            "recInferenceMs" to metrics.recInferenceMs,
            "recPostprocessMs" to metrics.recPostprocessMs,
            "bubbleSegmentationMs" to metrics.bubbleSegmentationMs,
            "regions" to regions.mapIndexed { index, region ->
                mapOf(
                    "id" to "r$index",
                    "text" to region.text,
                    "confidence" to region.confidence.toDouble(),
                    "backgroundArgb" to region.backgroundArgb,
                    "points" to region.points.map { listOf(it.x.toDouble(), it.y.toDouble()) },
                    "bubblePoints" to region.bubblePoints?.map {
                        listOf(it.x.toDouble(), it.y.toDouble())
                    },
                )
            },
        )
    }

    private class _RunMetrics {
        var detectionMs = 0L
        var recognitionMs = 0L
        var totalMs = 0L
        var detPreprocessMs = 0L
        var detInferenceMs = 0L
        var detPostprocessMs = 0L
        var recPreprocessMs = 0L
        var recInferenceMs = 0L
        var recPostprocessMs = 0L
        var bubbleSegmentationMs = 0L

        fun add(value: OCRRunResult) {
            detectionMs += value.detectionTimeMs
            recognitionMs += value.recognitionTimeMs
            totalMs += value.totalTimeMs
            detPreprocessMs += value.detPreprocessMs
            detInferenceMs += value.detInferenceMs
            detPostprocessMs += value.detPostprocessMs
            recPreprocessMs += value.recPreprocessMs
            recInferenceMs += value.recInferenceMs
            recPostprocessMs += value.recPostprocessMs
        }
    }

    private suspend fun unload() {
        ocr?.release()
        ocr = null
        activeRecognition = ""
    }

    private fun execute(result: MethodChannel.Result, action: suspend () -> Any?) {
        scope.launch {
            try {
                val value = action()
                mainHandler.post { result.success(value) }
            } catch (error: Throwable) {
                mainHandler.post {
                    result.error(
                        "comic_translation_ocr",
                        error.message,
                        error.stackTraceToString(),
                    )
                }
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        scope.launch {
            unload()
            scope.cancel()
            dispatcher.close()
        }
    }
}
