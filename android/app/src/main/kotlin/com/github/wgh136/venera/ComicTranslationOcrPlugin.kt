package com.github.wgh136.venera

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PointF
import android.graphics.Rect
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import com.paddle.ocr.EngineConfig
import com.paddle.ocr.PaddleOCR
import com.paddle.ocr.PaddleOCRConfig
import com.paddle.ocr.model.OCRBox
import com.paddle.ocr.model.OCRResult
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
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

private const val MIN_EFFECTIVE_ANALYSIS_WIDTH = 512
private const val MIN_ANALYSIS_WIDTH = 320
private const val TILE_OVERLAP_ANALYSIS = 128
private const val MIN_UNBUBBLED_SINGLE_CONFIDENCE = 0.72f

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

    private suspend fun recognize(call: MethodCall): Map<String, Any?> {
        selectRecognition(call.argument<String>("sourceLanguage")!!)
        val analysisSide = call.argument<Number>("maxAnalysisSide")!!.toInt()
        require(analysisSide >= MIN_ANALYSIS_WIDTH) {
            "OCR analysis side must be at least $MIN_ANALYSIS_WIDTH"
        }
        val file = File(call.argument<String>("filePath")!!)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            error("Unsupported image: ${file.path}")
        }
        val minAnalysisWidth = minOf(
            MIN_EFFECTIVE_ANALYSIS_WIDTH,
            maxOf(MIN_ANALYSIS_WIDTH, analysisSide / 3),
        )
        val maxDimension = maxOf(bounds.outWidth, bounds.outHeight)
        val wholeAnalysisWidth = if (maxDimension <= analysisSide) {
            bounds.outWidth.toLong()
        } else {
            bounds.outWidth.toLong() * analysisSide / maxDimension
        }
        val page = if (bounds.outHeight <= analysisSide ||
            wholeAnalysisWidth >= minAnalysisWidth
        ) {
            recognizeSingle(file, bounds.outWidth, bounds.outHeight, analysisSide)
        } else {
            recognizeTiled(
                file,
                bounds.outWidth,
                bounds.outHeight,
                analysisSide,
                minAnalysisWidth,
            )
        }
        val recognizer = if (activeRecognition == "korean")
            "korean-ppocrv5-mobile" else "ppocrv6-small"
        return page.toMap(recognizer)
    }

    private suspend fun recognizeSingle(
        file: File,
        width: Int,
        height: Int,
        analysisSide: Int,
    ): _PageResult {
        val sample = sampleFor(maxOf(width, height), analysisSide)
        val bitmap = BitmapFactory.decodeFile(file.path, bitmapOptions(sample))
            ?: error("Unsupported image: ${file.path}")
        return try {
            val metrics = _RunMetrics()
            val recognized = recognizeBitmap(
                bitmap,
                Rect(0, 0, width, height),
                analysisSide,
                metrics,
                0,
            )
            val encodeStart = System.currentTimeMillis()
            val cleanOverlayPng = recognized.cleanOverlay?.let {
                try {
                    encodePng(it)
                } finally {
                    it.recycle()
                }
            }
            metrics.cleanOverlayEncodeMs += System.currentTimeMillis() - encodeStart
            _PageResult(
                width,
                height,
                1,
                metrics,
                recognized.regions,
                cleanOverlayPng,
            )
        } finally {
            bitmap.recycle()
        }
    }

    @Suppress("DEPRECATION")
    private suspend fun recognizeTiled(
        file: File,
        width: Int,
        height: Int,
        analysisSide: Int,
        minAnalysisWidth: Int,
    ): _PageResult {
        val tileHeight = minOf(
            height,
            maxOf(
                analysisSide,
                ((width.toLong() * analysisSide + minAnalysisWidth - 1) /
                    minAnalysisWidth).toInt(),
            ),
        )
        val sample = sampleFor(maxOf(width, tileHeight), analysisSide)
        val overlapAnalysis = minOf(TILE_OVERLAP_ANALYSIS, analysisSide / 8)
        val overlap = minOf(
            tileHeight / 2,
            ((tileHeight.toLong() * overlapAnalysis + analysisSide - 1) /
                analysisSide).toInt(),
        )
        val decoder = BitmapRegionDecoder.newInstance(file.path, false)
        val metrics = _RunMetrics()
        val regions = mutableListOf<_RecognizedRegion>()
        val overlayWidth = (width + sample - 1) / sample
        val overlayHeight = (height + sample - 1) / sample
        val cleanOverlay = Bitmap.createBitmap(
            overlayWidth,
            overlayHeight,
            Bitmap.Config.ARGB_8888,
        )
        val overlayCanvas = Canvas(cleanOverlay)
        val overlayPaint = Paint(Paint.FILTER_BITMAP_FLAG)
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
                    val recognized = recognizeBitmap(
                        bitmap,
                        source,
                        analysisSide,
                        metrics,
                        tiles,
                        ownedTop,
                        ownedBottom,
                    )
                    recognized.cleanOverlay?.let { tileOverlay ->
                        overlayCanvas.drawBitmap(
                            tileOverlay,
                            null,
                            RectF(
                                source.left * overlayWidth.toFloat() / width,
                                source.top * overlayHeight.toFloat() / height,
                                source.right * overlayWidth.toFloat() / width,
                                source.bottom * overlayHeight.toFloat() / height,
                            ),
                            overlayPaint,
                        )
                        tileOverlay.recycle()
                    }
                    regions += recognized.regions
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
        val merged = mergeBubbleGroups(regions).sortedWith(compareBy(
            { it.points.minOf { point -> point.y } },
            { it.points.minOf { point -> point.x } }))
        val encodeStart = System.currentTimeMillis()
        val cleanOverlayPng = try {
            encodePng(cleanOverlay)
        } finally {
            cleanOverlay.recycle()
        }
        metrics.cleanOverlayEncodeMs += System.currentTimeMillis() - encodeStart
        return _PageResult(
            width,
            height,
            tiles,
            metrics,
            merged,
            cleanOverlayPng,
        )
    }

    private suspend fun recognizeBitmap(
        bitmap: Bitmap,
        source: Rect,
        analysisSide: Int,
        metrics: _RunMetrics,
        groupNamespace: Int,
        ownedTop: Float? = null,
        ownedBottom: Float? = null,
    ): _BitmapRecognition {
        val value = ocr!!.recognize(bitmap, analysisSide)
        metrics.add(value)
        val combined = value.results.toMutableList()
        val rescueStart = System.currentTimeMillis()
        val rescueBounds = BubbleSegmenter.unmatchedLightBubbleBounds(
            bitmap,
            combined.map { it.box },
        ).filter { bounds ->
            if (ownedTop == null || ownedBottom == null) return@filter true
            val centerY = source.top + bounds.centerY() *
                source.height().toFloat() / bitmap.height
            centerY in ownedTop..<ownedBottom
        }
        metrics.balloonProposalMs += System.currentTimeMillis() - rescueStart
        metrics.balloonCandidates += rescueBounds.size
        for (bounds in rescueBounds) {
            val crop = Bitmap.createBitmap(
                bitmap,
                bounds.left,
                bounds.top,
                bounds.width(),
                bounds.height(),
            )
            try {
                val rescued = ocr!!.recognize(crop, minOf(960, analysisSide))
                metrics.add(rescued)
                for (result in rescued.results) {
                    val mapped = OCRResult(
                        box = OCRBox(result.box.points.map {
                            PointF(it.x + bounds.left, it.y + bounds.top)
                        }),
                        text = result.text,
                        confidence = result.confidence,
                    )
                    if (combined.none { sameTextBox(it.box, mapped.box) }) {
                        combined += mapped
                        metrics.rescuedRegions++
                    }
                }
            } finally {
                crop.recycle()
            }
        }
        combined.sortWith(compareBy(
            { it.box.points.minOf { point -> point.y } },
            { it.box.points.minOf { point -> point.x } },
        ))
        val scaleY = source.height().toFloat() / bitmap.height
        val results = if (ownedTop == null || ownedBottom == null) {
            combined
        } else {
            combined.filter { region ->
                val centerY = region.box.points.sumOf { it.y.toDouble() }.toFloat() /
                    region.box.points.size
                source.top + centerY * scaleY in ownedTop..<ownedBottom
            }
        }
        val segmentationStart = System.currentTimeMillis()
        val segmentation = BubbleSegmenter.segment(
            bitmap,
            results.map { it.box },
            retainedIndices = { regions ->
                results.indices.filter { index ->
                    !isLowConfidenceUnbubbledSingleton(index, results, regions)
                }
            },
        )
        metrics.bubbleSegmentationMs += System.currentTimeMillis() - segmentationStart
        val keptResults = segmentation.sourceIndices.map { results[it] }
        val scaleX = source.width().toFloat() / bitmap.width
        val regions = keptResults.mapIndexed { index, region ->
            val segmented = segmentation.regions[index]
            _RecognizedRegion(
                text = region.text,
                confidence = region.confidence,
                backgroundArgb = segmented.backgroundArgb,
                foregroundArgb = segmented.foregroundArgb,
                bubbleGroupId = segmented.bubbleGroupId?.let {
                    (groupNamespace shl 16) or it
                },
                points = region.box.points.map { point ->
                    PointF(source.left + point.x * scaleX, source.top + point.y * scaleY)
                },
                bubblePoints = segmented.bubblePolygon?.map { point ->
                    PointF(source.left + point.x * scaleX, source.top + point.y * scaleY)
                },
                bubbleCandidatePoints = segmentation.bubbleCandidatePolygons[index]
                    ?.map { point ->
                        PointF(
                            source.left + point.x * scaleX,
                            source.top + point.y * scaleY,
                        )
                    },
                sourceMaskPolygons = segmented.sourceMaskPolygons.map { polygon ->
                    polygon.map { point ->
                        PointF(source.left + point.x * scaleX, source.top + point.y * scaleY)
                    }
                },
            )
        }
        return _BitmapRecognition(
            regions,
            segmentation.cleanOverlay?.let {
                scaleCleanOverlay(it, analysisSide)
            },
        )
    }

    private fun isLowConfidenceUnbubbledSingleton(
        index: Int,
        results: List<OCRResult>,
        segmentation: List<BubbleSegmenter.RegionSegmentation>,
    ): Boolean {
        val region = results[index]
        if (region.confidence >= MIN_UNBUBBLED_SINGLE_CONFIDENCE ||
            segmentation[index].bubbleGroupId != null
        ) return false
        if (region.text.count { it.isLetterOrDigit() } > 1) return false
        return results.indices.none { other ->
            other != index && segmentation[other].bubbleGroupId == null &&
                relatedTextBoxes(region.box, results[other].box)
        }
    }

    private fun relatedTextBoxes(a: OCRBox, b: OCRBox): Boolean {
        val first = ocrBounds(a)
        val second = ocrBounds(b)
        val firstSize = maxOf(first.width(), first.height())
        val secondSize = maxOf(second.width(), second.height())
        val gapX = maxOf(first.left, second.left) - minOf(first.right, second.right)
        val gapY = maxOf(first.top, second.top) - minOf(first.bottom, second.bottom)
        return maxOf(gapX, gapY) <= minOf(firstSize, secondSize) * 1.5f
    }

    private fun scaleCleanOverlay(bitmap: Bitmap, maxSide: Int): Bitmap {
        val length = maxOf(bitmap.width, bitmap.height)
        if (length <= maxSide) return bitmap
        val scale = maxSide.toFloat() / length
        val scaled = Bitmap.createScaledBitmap(
            bitmap,
            maxOf(1, (bitmap.width * scale).toInt()),
            maxOf(1, (bitmap.height * scale).toInt()),
            true,
        )
        bitmap.recycle()
        return scaled
    }

    private fun sameTextBox(a: OCRBox, b: OCRBox): Boolean {
        val first = ocrBounds(a)
        val second = ocrBounds(b)
        val width = minOf(first.right, second.right) - maxOf(first.left, second.left)
        val height = minOf(first.bottom, second.bottom) - maxOf(first.top, second.top)
        if (width <= 0f || height <= 0f) return false
        return width * height / minOf(first.width() * first.height(),
            second.width() * second.height()) >= 0.55f
    }

    private fun ocrBounds(box: OCRBox) = RectF(
        box.points.minOf { it.x },
        box.points.minOf { it.y },
        box.points.maxOf { it.x },
        box.points.maxOf { it.y },
    )

    private fun encodePng(bitmap: Bitmap) = ByteArrayOutputStream().use { output ->
        check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
        output.toByteArray()
    }

    private fun sampleFor(length: Int, analysisSide: Int): Int {
        var sample = 1
        while (length / (sample * 2) >= analysisSide) sample *= 2
        return sample
    }

    private fun mergeBubbleGroups(
        regions: List<_RecognizedRegion>,
    ): List<_RecognizedRegion> {
        val samples = regions.asSequence()
            .filter { it.bubbleGroupId != null && it.bubblePoints != null }
            .groupBy { it.bubbleGroupId!! }
            .map { (id, members) ->
                val member = members.maxBy { polygonBounds(it.bubblePoints!!).area }
                _BubbleGroupSample(
                    id,
                    id ushr 16,
                    member.backgroundArgb,
                    polygonBounds(member.bubblePoints!!),
                )
            }.sortedBy { it.bounds.left }
        if (samples.size < 2) return regions
        val parent = IntArray(samples.size) { it }
        fun root(value: Int): Int {
            var current = value
            while (parent[current] != current) {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }
        for (i in samples.indices) {
            for (j in i + 1 until samples.size) {
                if (samples[j].bounds.left >= samples[i].bounds.right) break
                if (samples[i].tile == samples[j].tile) continue
                if (!sameBubble(samples[i], samples[j])) continue
                parent[root(j)] = root(i)
            }
        }
        val canonical = samples.indices.associate { samples[it].id to samples[root(it)].id }
        return regions.map { region ->
            val group = region.bubbleGroupId
            if (group == null) region else region.copy(bubbleGroupId = canonical.getValue(group))
        }
    }

    private fun sameBubble(a: _BubbleGroupSample, b: _BubbleGroupSample): Boolean {
        if (maxOf(
                kotlin.math.abs(Color.red(a.color) - Color.red(b.color)),
                kotlin.math.abs(Color.green(a.color) - Color.green(b.color)),
                kotlin.math.abs(Color.blue(a.color) - Color.blue(b.color)),
            ) > 48
        ) return false
        val width = minOf(a.bounds.right, b.bounds.right) -
            maxOf(a.bounds.left, b.bounds.left)
        val height = minOf(a.bounds.bottom, b.bounds.bottom) -
            maxOf(a.bounds.top, b.bounds.top)
        if (width <= 0f || height <= 0f) return false
        val minArea = minOf(a.bounds.area, b.bounds.area)
        val maxArea = maxOf(a.bounds.area, b.bounds.area)
        return maxArea / minArea <= 1.8f && width * height / minArea >= 0.72f
    }

    private fun polygonBounds(points: List<PointF>): _FloatBounds = _FloatBounds(
        points.minOf { it.x },
        points.minOf { it.y },
        points.maxOf { it.x },
        points.maxOf { it.y },
    )

    private fun bitmapOptions(sample: Int) = BitmapFactory.Options().apply {
        inSampleSize = sample
        inPreferredConfig = Bitmap.Config.ARGB_8888
    }

    private data class _RecognizedRegion(
        val text: String,
        val confidence: Float,
        val backgroundArgb: Int,
        val foregroundArgb: Int?,
        val bubbleGroupId: Int?,
        val points: List<PointF>,
        val bubblePoints: List<PointF>?,
        val bubbleCandidatePoints: List<PointF>?,
        val sourceMaskPolygons: List<List<PointF>>,
    )

    private data class _BitmapRecognition(
        val regions: List<_RecognizedRegion>,
        val cleanOverlay: Bitmap?,
    )

    private data class _ModelPaths(
        val detection: String,
        val defaultRecognition: String,
        val defaultConfig: String,
        val koreanRecognition: String,
        val koreanConfig: String,
    )

    private data class _BubbleGroupSample(
        val id: Int,
        val tile: Int,
        val color: Int,
        val bounds: _FloatBounds,
    )

    private data class _FloatBounds(
        val left: Float,
        val top: Float,
        val right: Float,
        val bottom: Float,
    ) {
        val area get() = (right - left) * (bottom - top)
    }

    private data class _PageResult(
        val width: Int,
        val height: Int,
        val tiles: Int,
        val metrics: _RunMetrics,
        val regions: List<_RecognizedRegion>,
        val cleanOverlayPng: ByteArray?,
    ) {
        fun toMap(recognizer: String): Map<String, Any?> = mapOf(
            "width" to width,
            "height" to height,
            "tiles" to tiles,
            "recognizer" to recognizer,
            "detInputPixels" to metrics.detInputPixels,
            "detInputShapes" to metrics.detInputShapes,
            "detectedCount" to metrics.detectedCount,
            "rawDecodedCount" to metrics.rawDecodedCount,
            "acceptedCount" to metrics.acceptedCount,
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
            "balloonProposalMs" to metrics.balloonProposalMs,
            "balloonCandidates" to metrics.balloonCandidates,
            "rescuedRegions" to metrics.rescuedRegions,
            "cleanOverlayBytes" to (cleanOverlayPng?.size ?: 0),
            "cleanOverlayEncodeMs" to metrics.cleanOverlayEncodeMs,
            "cleanOverlayPng" to cleanOverlayPng,
            "regions" to regions.mapIndexed { index, region ->
                mapOf(
                    "id" to "r$index",
                    "text" to region.text,
                    "confidence" to region.confidence.toDouble(),
                    "backgroundArgb" to region.backgroundArgb,
                    "foregroundArgb" to region.foregroundArgb,
                    "bubbleGroupId" to region.bubbleGroupId,
                    "points" to region.points.map { listOf(it.x.toDouble(), it.y.toDouble()) },
                    "bubblePoints" to region.bubblePoints?.map {
                        listOf(it.x.toDouble(), it.y.toDouble())
                    },
                    "bubbleCandidatePoints" to region.bubbleCandidatePoints?.map {
                        listOf(it.x.toDouble(), it.y.toDouble())
                    },
                    "sourceMaskPolygons" to region.sourceMaskPolygons.map { polygon ->
                        polygon.map { listOf(it.x.toDouble(), it.y.toDouble()) }
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
        var balloonProposalMs = 0L
        var balloonCandidates = 0
        var rescuedRegions = 0
        var cleanOverlayEncodeMs = 0L
        var detInputPixels = 0L
        val detInputShapes = mutableListOf<List<Int>>()
        var detectedCount = 0
        var rawDecodedCount = 0
        var acceptedCount = 0

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
            detInputShapes += value.detInputShape
            detInputPixels += value.detInputShape[2].toLong() * value.detInputShape[3]
            detectedCount += value.detectedLineCount
            rawDecodedCount += value.decodedLineCount
            acceptedCount += value.acceptedLineCount
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
