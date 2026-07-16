package com.github.wgh136.venera

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.PointF
import android.os.Handler
import android.os.Looper
import com.paddle.ocr.EngineConfig
import com.paddle.ocr.PaddleOCR
import com.paddle.ocr.PaddleOCRConfig
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
        ocr = PaddleOCR.create(
            appContext,
            PaddleOCRConfig(
                detLimitSideLen = maxSide,
                detLimitType = "max",
                detMaxSideLimit = maxSide,
                detBoxThresh = 0.45f,
                detUnclipRatio = 1.4f,
                recScoreThresh = 0.35f,
                recBatchSize = 4,
            ),
            EngineConfig(call.argument<Number>("threads")!!.toInt()),
            call.argument<String>("detModelPath")!!,
            call.argument<String>("recModelPath")!!,
            call.argument<String>("recConfigPath")!!,
        )
    }

    private suspend fun recognize(call: MethodCall): Map<String, Any> {
        val file = File(call.argument<String>("filePath")!!)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            error("Unsupported image: ${file.path}")
        }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxAnalysisSide) {
            sample *= 2
        }
        val bitmap = BitmapFactory.decodeFile(
            file.path,
            BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = android.graphics.Bitmap.Config.ARGB_8888
            },
        ) ?: error("Unsupported image: ${file.path}")
        return try {
            val value = ocr!!.recognize(bitmap)
            mapOf(
                "width" to bitmap.width,
                "height" to bitmap.height,
                "detectionMs" to value.detectionTimeMs,
                "recognitionMs" to value.recognitionTimeMs,
                "totalMs" to value.totalTimeMs,
                "detPreprocessMs" to value.detPreprocessMs,
                "detInferenceMs" to value.detInferenceMs,
                "detPostprocessMs" to value.detPostprocessMs,
                "recPreprocessMs" to value.recPreprocessMs,
                "recInferenceMs" to value.recInferenceMs,
                "recPostprocessMs" to value.recPostprocessMs,
                "regions" to value.results.mapIndexed { index, region ->
                    mapOf(
                        "id" to "r$index",
                        "text" to region.text,
                        "confidence" to region.confidence.toDouble(),
                        "backgroundArgb" to estimateBackground(bitmap, region.box.points),
                        "points" to region.box.points.map { listOf(it.x.toDouble(), it.y.toDouble()) },
                    )
                },
            )
        } finally {
            bitmap.recycle()
        }
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

    private suspend fun unload() {
        ocr?.release()
        ocr = null
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
