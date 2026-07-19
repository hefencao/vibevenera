package com.paddle.ocr.postprocess

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.PointF
import com.paddle.ocr.model.OCRBox
import com.paddle.ocr.util.BitmapUtils
import org.opencv.android.Utils
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfInt
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Rect
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import org.opencv.photo.Photo
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

object BubbleSegmenter {
    private const val BUBBLE_COLOR_TOLERANCE = 44.0
    private const val BUBBLE_ASSIGN_TOLERANCE = 48
    private const val BUBBLE_DEDUP_TOLERANCE = BUBBLE_ASSIGN_TOLERANCE
    private const val TEXT_COLOR_TOLERANCE = 18.0
    private const val TEXT_CORE_TOLERANCE = 40.0

    data class RegionSegmentation(
        val backgroundArgb: Int,
        val foregroundArgb: Int?,
        val bubbleGroupId: Int?,
        val bubblePolygon: List<PointF>?,
        val sourceMaskPolygons: List<List<PointF>>,
    )

    data class SegmentationResult(
        val regions: List<RegionSegmentation>,
        val sourceIndices: List<Int>,
        val bubbleCandidatePolygons: List<List<PointF>?>,
        val cleanOverlay: Bitmap?,
    )

    private data class BubbleCandidate(
        val id: Int,
        val polygon: List<PointF>,
        val color: Int,
        val area: Double,
        val bounds: Rect,
    )

    fun segment(
        bitmap: Bitmap,
        boxes: List<OCRBox>,
        retainedIndices: ((List<RegionSegmentation>) -> List<Int>)? = null,
    ): SegmentationResult {
        if (boxes.isEmpty()) return SegmentationResult(
            emptyList(), emptyList(), emptyList(), null,
        )
        val image = BitmapUtils.bitmapToBGRMat(bitmap)
        val known = mutableListOf<BubbleCandidate>()
        return try {
            val colors = boxes.map { estimateBackground(image, it) }
            boxes.forEachIndexed { index, box ->
                if (candidateFor(known, box, colors[index]) != null) return@forEachIndexed
                val candidate = segmentBubble(image, box, colors[index])
                    ?: return@forEachIndexed
                val duplicate = known.indexOfFirst { sameCandidate(it, candidate) }
                if (duplicate < 0) {
                    known += candidate.copy(id = known.size)
                } else if (candidate.area > known[duplicate].area) {
                    known[duplicate] = candidate.copy(id = known[duplicate].id)
                }
            }
            val bubbles = splitConnectedBubbles(known, boxes, colors)
            val regions = boxes.mapIndexed { index, box ->
                val bubble = candidateFor(bubbles, box, colors[index])
                val masks = sourceMasks(image, box, colors[index])
                RegionSegmentation(
                    backgroundArgb = colors[index],
                    foregroundArgb = masks.foregroundArgb,
                    bubbleGroupId = bubble?.id,
                    bubblePolygon = bubble?.polygon,
                    sourceMaskPolygons = masks.polygons,
                )
            }
            val unassigned = regions.indices.filter {
                regions[it].bubbleGroupId == null
            }
            val recovered = if (unassigned.isEmpty()) emptyList() else {
                recoverLightBubbles(image, boxes, unassigned)
            }
            val candidatePolygons = boxes.mapIndexed { index, box ->
                if (regions[index].bubbleGroupId != null) null else {
                    val point = center(box)
                    recovered.asSequence().filter { candidate ->
                        contains(candidate.polygon, point)
                    }.minByOrNull { it.area }?.polygon
                }
            }
            val selected = retainedIndices?.invoke(regions) ?: regions.indices.toList()
            val selectedRegions = selected.map { regions[it] }
            SegmentationResult(
                selectedRegions,
                selected,
                selected.map { candidatePolygons[it] },
                if (selected.isEmpty()) null else {
                    cleanOverlay(image, selected.map { boxes[it] }, selectedRegions)
                },
            )
        } finally {
            image.release()
        }
    }

    fun unmatchedLightBubbleBounds(
        bitmap: Bitmap,
        boxes: List<OCRBox>,
    ): List<android.graphics.Rect> {
        val image = BitmapUtils.bitmapToBGRMat(bitmap)
        val gray = Mat()
        val light = Mat()
        val closed = Mat()
        val kernel = Imgproc.getStructuringElement(
            Imgproc.MORPH_ELLIPSE,
            Size(5.0, 5.0),
        )
        val contours = mutableListOf<MatOfPoint>()
        val hierarchy = Mat()
        return try {
            Imgproc.cvtColor(image, gray, Imgproc.COLOR_BGR2GRAY)
            Imgproc.threshold(gray, light, 210.0, 255.0, Imgproc.THRESH_BINARY)
            Imgproc.morphologyEx(light, closed, Imgproc.MORPH_CLOSE, kernel)
            Imgproc.findContours(
                closed,
                contours,
                hierarchy,
                Imgproc.RETR_LIST,
                Imgproc.CHAIN_APPROX_SIMPLE,
            )
            val imageArea = image.cols().toDouble() * image.rows()
            val centers = boxes.map(::center)
            val candidates = contours.mapNotNull { contour ->
                val rect = Imgproc.boundingRect(contour)
                if (rect.x <= 1 || rect.y <= 1 ||
                    rect.x + rect.width >= image.cols() - 1 ||
                    rect.y + rect.height >= image.rows() - 1 ||
                    rect.width < 28 || rect.height < 22
                ) return@mapNotNull null
                val area = Imgproc.contourArea(contour)
                val areaFraction = area / imageArea
                if (areaFraction !in 0.00035..0.18 ||
                    area / rect.area() < 0.48
                ) return@mapNotNull null
                val contour2f = MatOfPoint2f(*contour.toArray())
                val hullIndices = MatOfInt()
                val hull = MatOfPoint()
                val selection = Mat.zeros(rect.height, rect.width, CvType.CV_8UC1)
                val dark = Mat()
                val grayRoi = gray.submat(rect)
                val localContour = MatOfPoint(*contour.toArray().map {
                    Point(it.x - rect.x, it.y - rect.y)
                }.toTypedArray())
                try {
                    val perimeter = Imgproc.arcLength(contour2f, true)
                    if (perimeter <= 0) return@mapNotNull null
                    val compactness = 4 * PI * area / (perimeter * perimeter)
                    Imgproc.convexHull(contour, hullIndices)
                    val points = contour.toArray()
                    hull.fromArray(*hullIndices.toArray().map { points[it] }.toTypedArray())
                    val hullArea = Imgproc.contourArea(hull)
                    if (hullArea <= 0 || compactness < 0.14 || area / hullArea < 0.72) {
                        return@mapNotNull null
                    }
                    if (centers.any { it.x >= rect.x && it.x <= rect.x + rect.width &&
                            it.y >= rect.y && it.y <= rect.y + rect.height
                        }) return@mapNotNull null
                    Imgproc.drawContours(
                        selection,
                        listOf(localContour),
                        0,
                        Scalar(255.0),
                        Imgproc.FILLED,
                    )
                    Imgproc.threshold(
                        grayRoi,
                        dark,
                        170.0,
                        255.0,
                        Imgproc.THRESH_BINARY_INV,
                    )
                    Core.bitwise_and(dark, selection, dark)
                    val inkFraction = Core.countNonZero(dark) / area
                    if (inkFraction !in 0.006..0.28) return@mapNotNull null
                    val padding = (min(rect.width, rect.height) * 0.08)
                        .toInt().coerceIn(4, 20)
                    val expanded = inflate(rect, padding, image.cols(), image.rows())
                    android.graphics.Rect(
                        expanded.x,
                        expanded.y,
                        expanded.x + expanded.width,
                        expanded.y + expanded.height,
                    )
                } finally {
                    contour2f.release()
                    hullIndices.release()
                    hull.release()
                    selection.release()
                    dark.release()
                    grayRoi.release()
                    localContour.release()
                }
            }.sortedWith(compareBy(
                { it.top },
                { it.left },
                { it.width() * it.height() },
            ))
            val accepted = mutableListOf<android.graphics.Rect>()
            for (candidate in candidates) {
                if (accepted.any { overlapOverSmaller(it, candidate) >= 0.72 }) continue
                accepted += candidate
            }
            accepted
        } finally {
            image.release()
            gray.release()
            light.release()
            closed.release()
            kernel.release()
            contours.forEach(MatOfPoint::release)
            hierarchy.release()
        }
    }

    private fun overlapOverSmaller(
        a: android.graphics.Rect,
        b: android.graphics.Rect,
    ): Double {
        val width = min(a.right, b.right) - max(a.left, b.left)
        val height = min(a.bottom, b.bottom) - max(a.top, b.top)
        if (width <= 0 || height <= 0) return 0.0
        return width.toDouble() * height /
            min(a.width().toDouble() * a.height(), b.width().toDouble() * b.height())
    }

    /** A short/incomplete OCR box can make the normal seed component look
     * oversized, especially when two balloons share one white component.
     * Recover a layout-only contour for still-unassigned text; this must not
     * alter native bubble assignment before Dart text grouping has finished. */
    private fun recoverLightBubbles(
        image: Mat,
        boxes: List<OCRBox>,
        unassigned: List<Int>,
    ): List<BubbleCandidate> {
        val gray = Mat()
        val light = Mat()
        val opened = Mat()
        val kernel = Imgproc.getStructuringElement(
            Imgproc.MORPH_RECT,
            Size(3.0, 3.0),
        )
        val contours = mutableListOf<MatOfPoint>()
        val hierarchy = Mat()
        return try {
            Imgproc.cvtColor(image, gray, Imgproc.COLOR_BGR2GRAY)
            Imgproc.threshold(gray, light, 210.0, 255.0, Imgproc.THRESH_BINARY)
            // Candidate-only topology repair: sever narrow white leaks through
            // an otherwise closed balloon outline. Formal native segmentation
            // keeps the original pixels and does not use this relaxation.
            Imgproc.morphologyEx(light, opened, Imgproc.MORPH_OPEN, kernel)
            Imgproc.findContours(
                opened, contours, hierarchy, Imgproc.RETR_CCOMP,
                Imgproc.CHAIN_APPROX_SIMPLE,
            )
            val imageArea = image.cols().toDouble() * image.rows()
            val recovered = mutableListOf<BubbleCandidate>()
            for ((contourIndex, contour) in contours.withIndex()) {
                // RETR_LIST treated dark glyph holes as bubble candidates.
                // CCOMP keeps them as children of the surrounding white
                // component; only foreground components may be bubbles.
                if (hierarchy.get(0, contourIndex)[3] >= 0) continue
                val rect = Imgproc.boundingRect(contour)
                if (rect.width < 20 || rect.height < 16) continue
                val area = Imgproc.contourArea(contour)
                if (area / imageArea !in 0.00005..0.24 ||
                    area / rect.area() < 0.08
                ) continue
                val contour2f = MatOfPoint2f(*contour.toArray())
                val approximation = MatOfPoint2f()
                try {
                    val members = unassigned.filter { index ->
                        val center = center(boxes[index])
                        val text = bounds(
                            boxes[index].points, image.cols(), image.rows(),
                        )
                        Imgproc.pointPolygonTest(
                            contour2f,
                            Point(center.x.toDouble(), center.y.toDouble()),
                            false,
                        ) >= 0 &&
                            rect.width >= text.width * 1.15 &&
                            rect.height >= text.height * 1.15
                    }
                    if (members.isEmpty()) continue
                    val perimeter = Imgproc.arcLength(contour2f, true)
                    if (perimeter <= 0) continue
                    val extent = area / rect.area()
                    if (area / imageArea > 0.08 && extent > 0.88) continue
                    Imgproc.approxPolyDP(
                        contour2f, approximation,
                        max(0.75, perimeter * 0.008), true,
                    )
                    val polygon = canonical(approximation.toArray().map {
                        PointF(it.x.toFloat(), it.y.toFloat())
                    })
                    if (polygon.size < 4) continue
                    val candidate = BubbleCandidate(
                        id = -1,
                        polygon = polygon,
                        color = Color.WHITE,
                        area = area,
                        bounds = rect,
                    )
                    val duplicate = recovered.indexOfFirst {
                        sameCandidate(it, candidate)
                    }
                    if (duplicate < 0) recovered += candidate
                    else if (candidate.area > recovered[duplicate].area) {
                        recovered[duplicate] = candidate
                    }
                } finally {
                    contour2f.release()
                    approximation.release()
                }
            }
            recovered
        } finally {
            gray.release()
            light.release()
            opened.release()
            kernel.release()
            contours.forEach(MatOfPoint::release)
            hierarchy.release()
        }
    }

    private fun cleanOverlay(
        image: Mat,
        boxes: List<OCRBox>,
        regions: List<RegionSegmentation>,
    ): Bitmap {
        val mask = Mat.zeros(image.rows(), image.cols(), CvType.CV_8UC1)
        val kernel = Imgproc.getStructuringElement(
            Imgproc.MORPH_ELLIPSE,
            Size(3.0, 3.0),
        )
        val cleaned = Mat()
        val rgba = Mat()
        try {
            regions.forEachIndexed { index, region ->
                val polygons = if (region.sourceMaskPolygons.isEmpty()) {
                    listOf(boxes[index].points)
                } else {
                    region.sourceMaskPolygons
                }
                polygons.forEach { polygon ->
                    val points = MatOfPoint(*polygon.map {
                        Point(it.x.toDouble(), it.y.toDouble())
                    }.toTypedArray())
                    try {
                        Imgproc.fillPoly(mask, listOf(points), Scalar(255.0))
                    } finally {
                        points.release()
                    }
                }
            }
            Imgproc.dilate(mask, mask, kernel)
            Photo.inpaint(image, mask, cleaned, 3.0, Photo.INPAINT_TELEA)
            Imgproc.cvtColor(cleaned, rgba, Imgproc.COLOR_BGR2RGBA)
            Core.insertChannel(mask, rgba, 3)
            return Bitmap.createBitmap(
                image.cols(),
                image.rows(),
                Bitmap.Config.ARGB_8888,
            ).also { Utils.matToBitmap(rgba, it) }
        } finally {
            mask.release()
            kernel.release()
            cleaned.release()
            rgba.release()
        }
    }

    private fun candidateFor(
        candidates: List<BubbleCandidate>,
        box: OCRBox,
        color: Int,
    ) = candidates.asSequence()
        .filter {
            contains(it.polygon, center(box)) &&
                colorDistance(it.color, color) <= BUBBLE_ASSIGN_TOLERANCE
        }
        .minByOrNull { it.area }

    private fun sameCandidate(a: BubbleCandidate, b: BubbleCandidate): Boolean {
        if (colorDistance(a.color, b.color) > BUBBLE_DEDUP_TOLERANCE) return false
        if (max(a.area, b.area) / min(a.area, b.area) > 1.8) return false
        val intersectionWidth = min(
            a.bounds.x + a.bounds.width,
            b.bounds.x + b.bounds.width,
        ) - max(a.bounds.x, b.bounds.x)
        val intersectionHeight = min(
            a.bounds.y + a.bounds.height,
            b.bounds.y + b.bounds.height,
        ) - max(a.bounds.y, b.bounds.y)
        if (intersectionWidth <= 0 || intersectionHeight <= 0) return false
        val intersection = intersectionWidth.toDouble() * intersectionHeight
        return intersection / min(a.bounds.area(), b.bounds.area()) >= 0.72
    }

    /** Splits dumbbell-shaped connected components at their narrow neck. OCR
     * centers select distance-transform cores, so multiple columns inside one
     * ordinary balloon remain one translation unit. */
    private fun splitConnectedBubbles(
        candidates: List<BubbleCandidate>,
        boxes: List<OCRBox>,
        colors: List<Int>,
    ): List<BubbleCandidate> {
        val result = mutableListOf<BubbleCandidate>()
        for (candidate in candidates) {
            val members = boxes.indices.filter { index ->
                candidateFor(candidates, boxes[index], colors[index]) == candidate
            }
            val split = if (members.size >= 2) {
                splitConnectedBubble(candidate, members.map { boxes[it] })
            } else null
            result += split ?: listOf(candidate)
        }
        return result.mapIndexed { index, candidate -> candidate.copy(id = index) }
    }

    private fun splitConnectedBubble(
        candidate: BubbleCandidate,
        boxes: List<OCRBox>,
    ): List<BubbleCandidate>? {
        val bounds = candidate.bounds
        val mask = Mat.zeros(bounds.height, bounds.width, CvType.CV_8UC1)
        val polygon = MatOfPoint(*candidate.polygon.map {
            Point((it.x - bounds.x).toDouble(), (it.y - bounds.y).toDouble())
        }.toTypedArray())
        val distance = Mat()
        val cores = Mat()
        val labels = Mat()
        val stats = Mat()
        val centroids = Mat()
        try {
            Imgproc.fillPoly(mask, listOf(polygon), Scalar(255.0))
            Imgproc.distanceTransform(mask, distance, Imgproc.DIST_L2, 5)
            val maxDistance = Core.minMaxLoc(distance).maxVal
            var coreCenters = emptyList<Point>()
            var coreLevel = 0
            if (maxDistance >= 4.0) {
                val minCoreArea = max(9.0, candidate.area * 0.0015)
                for (level in 82 downTo 26 step 4) {
                    Imgproc.threshold(
                        distance,
                        cores,
                        maxDistance * level / 100.0,
                        255.0,
                        Imgproc.THRESH_BINARY,
                    )
                    cores.convertTo(cores, CvType.CV_8UC1)
                    val count = Imgproc.connectedComponentsWithStats(
                        cores, labels, stats, centroids, 8, CvType.CV_32S,
                    )
                    val centers = (1 until count).mapNotNull { label ->
                        if (stats.get(label, Imgproc.CC_STAT_AREA)[0] < minCoreArea) {
                            null
                        } else {
                            Point(
                                centroids.get(label, 0)[0],
                                centroids.get(label, 1)[0],
                            )
                        }
                    }
                    val used = boxes.mapNotNull { box ->
                        val point = center(box)
                        centers.indices.minByOrNull { index ->
                            val dx = point.x - bounds.x - centers[index].x
                            val dy = point.y - bounds.y - centers[index].y
                            dx * dx + dy * dy
                        }
                    }.distinct()
                    if (used.size >= 2) {
                        coreCenters = centers
                        coreLevel = level
                        break
                    }
                }
            }
            val solidity = polygonSolidity(polygon)
            val used = boxes.mapNotNull { box ->
                val point = center(box)
                coreCenters.indices.minByOrNull { index ->
                    val dx = point.x - bounds.x - coreCenters[index].x
                    val dy = point.y - bounds.y - coreCenters[index].y
                    dx * dx + dy * dy
                }
            }.distinct()
            if (used.size < 2 || solidity >= 0.98) return null
            val concavity = ((1.0 - solidity - 0.02) / 0.14).coerceIn(0.0, 1.0)
            val concavityWeight = concavity * concavity
            val coreWeight = ((coreLevel - 26) / 56.0).coerceIn(0.0, 1.0)
            if (concavityWeight * 0.72 + coreWeight * 0.28 < 0.30) return null

            val lobeMasks = used.associateWith {
                Mat.zeros(bounds.height, bounds.width, CvType.CV_8UC1)
            }
            val sourceRow = ByteArray(bounds.width)
            val outputRows = used.associateWith { ByteArray(bounds.width) }
            for (y in 0 until bounds.height) {
                mask.get(y, 0, sourceRow)
                outputRows.values.forEach { it.fill(0) }
                for (x in 0 until bounds.width) {
                    if (sourceRow[x].toInt() == 0) continue
                    val nearest = used.minBy { core ->
                        val dx = x - coreCenters[core].x
                        val dy = y - coreCenters[core].y
                        dx * dx + dy * dy
                    }
                    outputRows.getValue(nearest)[x] = 0xff.toByte()
                }
                lobeMasks.forEach { (core, lobeMask) ->
                    lobeMask.put(y, 0, outputRows.getValue(core))
                }
            }
            return try {
                used.mapNotNull { core ->
                    candidateFromMask(lobeMasks.getValue(core), candidate, bounds)
                }.takeIf { it.size == used.size }
            } finally {
                lobeMasks.values.forEach(Mat::release)
            }
        } finally {
            mask.release()
            polygon.release()
            distance.release()
            cores.release()
            labels.release()
            stats.release()
            centroids.release()
        }
    }

    private fun polygonSolidity(contour: MatOfPoint): Double {
        val indices = MatOfInt()
        val hull = MatOfPoint()
        try {
            Imgproc.convexHull(contour, indices)
            val points = contour.toArray()
            hull.fromArray(*indices.toArray().map { points[it] }.toTypedArray())
            val hullArea = Imgproc.contourArea(hull)
            return if (hullArea == 0.0) 1.0 else
                Imgproc.contourArea(contour) / hullArea
        } finally {
            indices.release()
            hull.release()
        }
    }

    private fun candidateFromMask(
        mask: Mat,
        source: BubbleCandidate,
        offset: Rect,
    ): BubbleCandidate? {
        val contours = mutableListOf<MatOfPoint>()
        val hierarchy = Mat()
        try {
            Imgproc.findContours(
                mask, contours, hierarchy, Imgproc.RETR_EXTERNAL,
                Imgproc.CHAIN_APPROX_SIMPLE,
            )
            val contour = contours.maxByOrNull(Imgproc::contourArea) ?: return null
            val area = Imgproc.contourArea(contour)
            if (area <= 0) return null
            val contour2f = MatOfPoint2f(*contour.toArray())
            val approximation = MatOfPoint2f()
            try {
                val perimeter = Imgproc.arcLength(contour2f, true)
                Imgproc.approxPolyDP(
                    contour2f, approximation, max(0.75, perimeter * 0.008), true,
                )
                val points = canonical(approximation.toArray().map {
                    PointF(
                        (it.x + offset.x).toFloat(),
                        (it.y + offset.y).toFloat(),
                    )
                })
                if (points.size < 4) return null
                val localBounds = Imgproc.boundingRect(contour)
                return BubbleCandidate(
                    id = -1,
                    polygon = points,
                    color = source.color,
                    area = area,
                    bounds = Rect(
                        localBounds.x + offset.x,
                        localBounds.y + offset.y,
                        localBounds.width,
                        localBounds.height,
                    ),
                )
            } finally {
                contour2f.release()
                approximation.release()
            }
        } finally {
            contours.forEach(MatOfPoint::release)
            hierarchy.release()
        }
    }

    private fun estimateBackground(image: Mat, box: OCRBox): Int {
        val boxBounds = bounds(box.points, image.cols(), image.rows())
        val shortSide = min(boxBounds.width, boxBounds.height)
        val padding = (shortSide * 0.10).toInt().coerceIn(2, 8)
        val sampleBounds = inflate(boxBounds, padding, image.cols(), image.rows())
        val roi = image.submat(sampleBounds)
        val quad = polygonMask(box, sampleBounds)
        val expanded = Mat()
        val ring = Mat()
        val kernel = Imgproc.getStructuringElement(
            Imgproc.MORPH_ELLIPSE,
            Size((padding * 2 + 1).toDouble(), (padding * 2 + 1).toDouble()),
        )
        return try {
            Imgproc.dilate(quad, expanded, kernel)
            Core.subtract(expanded, quad, ring)
            modalColor(roi, if (Core.countNonZero(ring) > 0) ring else quad)
        } finally {
            roi.release()
            quad.release()
            expanded.release()
            ring.release()
            kernel.release()
        }
    }

    private fun modalColor(image: Mat, selection: Mat): Int {
        val counts = IntArray(4096)
        val red = LongArray(4096)
        val green = LongArray(4096)
        val blue = LongArray(4096)
        val pixels = ByteArray(image.cols() * 3)
        val selected = ByteArray(selection.cols())
        for (y in 0 until image.rows()) {
            image.get(y, 0, pixels)
            selection.get(y, 0, selected)
            for (x in 0 until image.cols()) {
                if (selected[x].toInt() == 0) continue
                val offset = x * 3
                val b = pixels[offset].toInt() and 0xff
                val g = pixels[offset + 1].toInt() and 0xff
                val r = pixels[offset + 2].toInt() and 0xff
                val bucket = (r shr 4 shl 8) or (g shr 4 shl 4) or (b shr 4)
                counts[bucket]++
                red[bucket] += r.toLong()
                green[bucket] += g.toLong()
                blue[bucket] += b.toLong()
            }
        }
        val bucket = counts.indices.maxBy { counts[it] }
        check(counts[bucket] > 0) { "Cannot sample OCR background" }
        return Color.rgb(
            (red[bucket] / counts[bucket]).toInt(),
            (green[bucket] / counts[bucket]).toInt(),
            (blue[bucket] / counts[bucket]).toInt(),
        )
    }

    private fun segmentBubble(image: Mat, box: OCRBox, color: Int): BubbleCandidate? {
        val boxBounds = bounds(box.points, image.cols(), image.rows())
        val margin = max(32, (max(boxBounds.width, boxBounds.height) * 1.25).toInt())
            .coerceAtMost(256)
        val searchBounds = inflate(boxBounds, margin, image.cols(), image.rows())
        val roi = image.submat(searchBounds)
        val background = Mat()
        val labels = Mat()
        val stats = Mat()
        val centroids = Mat()
        val component = Mat()
        val quad = polygonMask(box, searchBounds)
        return try {
            Core.inRange(roi, lower(color, BUBBLE_COLOR_TOLERANCE),
                upper(color, BUBBLE_COLOR_TOLERANCE), background)
            Imgproc.connectedComponentsWithStats(
                background,
                labels,
                stats,
                centroids,
                8,
                CvType.CV_32S,
            )
            val counts = HashMap<Int, Int>()
            val seedLeft = boxBounds.x - searchBounds.x
            val seedTop = boxBounds.y - searchBounds.y
            val seedRight = seedLeft + boxBounds.width
            val seedBottom = seedTop + boxBounds.height
            for (y in seedTop until seedBottom) {
                for (x in seedLeft until seedRight) {
                    if (quad.get(y, x)[0] == 0.0) continue
                    val label = labels.get(y, x)[0].toInt()
                    if (label != 0) counts[label] = (counts[label] ?: 0) + 1
                }
            }
            if (counts.isEmpty()) return null
            val label = counts.maxBy { it.value }.key
            val quadArea = Core.countNonZero(quad).toDouble()
            if (counts.getValue(label) / quadArea < 0.22) return null
            val x = stats.get(label, Imgproc.CC_STAT_LEFT)[0].toInt()
            val y = stats.get(label, Imgproc.CC_STAT_TOP)[0].toInt()
            val width = stats.get(label, Imgproc.CC_STAT_WIDTH)[0].toInt()
            val height = stats.get(label, Imgproc.CC_STAT_HEIGHT)[0].toInt()
            val pixelArea = stats.get(label, Imgproc.CC_STAT_AREA)[0]
            if (x <= 1 || y <= 1 || x + width >= roi.cols() - 1 ||
                y + height >= roi.rows() - 1 ||
                width > boxBounds.width * 12.0 || height > boxBounds.height * 12.0
            ) return null
            Core.compare(labels, Scalar(label.toDouble()), component, Core.CMP_EQ)
            val contours = mutableListOf<MatOfPoint>()
            val hierarchy = Mat()
            try {
                Imgproc.findContours(
                    component,
                    contours,
                    hierarchy,
                    Imgproc.RETR_EXTERNAL,
                    Imgproc.CHAIN_APPROX_SIMPLE,
                )
                val contour = contours.maxByOrNull(Imgproc::contourArea) ?: return null
                val contourArea = Imgproc.contourArea(contour)
                if (contourArea <= 0) return null
                val areaRatio = contourArea / quadArea
                val contourBounds = Imgproc.boundingRect(contour)
                val extent = contourArea / contourBounds.area()
                val hullIndices = MatOfInt()
                val hull = MatOfPoint()
                val contour2f = MatOfPoint2f(*contour.toArray())
                try {
                    val perimeter = Imgproc.arcLength(contour2f, true)
                    if (perimeter <= 0) return null
                    val compactness = 4 * PI * contourArea / (perimeter * perimeter)
                    Imgproc.convexHull(contour, hullIndices)
                    val points = contour.toArray()
                    hull.fromArray(*hullIndices.toArray().map { points[it] }.toTypedArray())
                    val hullArea = Imgproc.contourArea(hull)
                    if (hullArea <= 0) return null
                    val solidity = contourArea / hullArea
                    val oversizedRectangle = areaRatio > 9.0 &&
                        extent > 0.82 && solidity > 0.92
                    val center = center(box)
                    val localCenter = Point(
                        (center.x - searchBounds.x).toDouble(),
                        (center.y - searchBounds.y).toDouble(),
                    )
                    if (areaRatio !in 0.75..36.0 ||
                        pixelArea / contourArea < 0.55 ||
                        compactness < 0.18 || extent < 0.42 ||
                        solidity < 0.62 || oversizedRectangle ||
                        Imgproc.pointPolygonTest(contour2f, localCenter, false) < 0
                    ) return null
                    val approximation = MatOfPoint2f()
                    try {
                        Imgproc.approxPolyDP(
                            contour2f,
                            approximation,
                            max(0.75, perimeter * 0.008),
                            true,
                        )
                        val polygon = canonical(approximation.toArray().map {
                            PointF(
                                (it.x + searchBounds.x).toFloat(),
                                (it.y + searchBounds.y).toFloat(),
                            )
                        })
                        if (polygon.size < 4) return null
                        return BubbleCandidate(
                            id = -1,
                            polygon = polygon,
                            color = color,
                            area = contourArea,
                            bounds = Rect(
                                contourBounds.x + searchBounds.x,
                                contourBounds.y + searchBounds.y,
                                contourBounds.width,
                                contourBounds.height,
                            ),
                        )
                    } finally {
                        approximation.release()
                    }
                } finally {
                    contour2f.release()
                    hullIndices.release()
                    hull.release()
                }
            } finally {
                contours.forEach(MatOfPoint::release)
                hierarchy.release()
            }
        } finally {
            roi.release()
            background.release()
            labels.release()
            stats.release()
            centroids.release()
            component.release()
            quad.release()
        }
    }

    private fun sourceMasks(image: Mat, box: OCRBox, color: Int): _SourceMasks {
        val boxBounds = bounds(box.points, image.cols(), image.rows())
        val padding = (min(boxBounds.width, boxBounds.height) * 0.08).toInt().coerceIn(2, 8)
        val maskBounds = inflate(boxBounds, padding, image.cols(), image.rows())
        val roi = image.submat(maskBounds)
        val quad = polygonMask(box, maskBounds)
        val clipQuad = Mat()
        val background = Mat()
        val foreground = Mat()
        val strongBackground = Mat()
        val strongForeground = Mat()
        val innerQuad = Mat()
        val closed = Mat()
        val expanded = Mat()
        val clipped = Mat()
        val closeKernel = Imgproc.getStructuringElement(
            Imgproc.MORPH_ELLIPSE,
            Size(3.0, 3.0),
        )
        val expandKernel = Imgproc.getStructuringElement(
            Imgproc.MORPH_ELLIPSE,
            Size(5.0, 5.0),
        )
        return try {
            Imgproc.dilate(quad, clipQuad, expandKernel)
            Core.inRange(roi, lower(color, TEXT_COLOR_TOLERANCE),
                upper(color, TEXT_COLOR_TOLERANCE), background)
            Core.bitwise_not(background, foreground)
            Core.bitwise_and(foreground, clipQuad, foreground)
            Core.inRange(roi, lower(color, TEXT_CORE_TOLERANCE),
                upper(color, TEXT_CORE_TOLERANCE), strongBackground)
            Core.bitwise_not(strongBackground, strongForeground)
            Imgproc.erode(quad, innerQuad, closeKernel)
            Core.bitwise_and(strongForeground, innerQuad, strongForeground)
            val foregroundArgb = if (Core.countNonZero(strongForeground) == 0) {
                null
            } else {
                textCoreColor(roi, strongForeground, color)
            }
            val maskArea = Core.countNonZero(clipQuad).toDouble()
            val rawFraction = Core.countNonZero(foreground) / maskArea
            if (rawFraction !in 0.002..0.50) {
                return _SourceMasks(foregroundArgb, emptyList())
            }
            Imgproc.morphologyEx(foreground, closed, Imgproc.MORPH_CLOSE, closeKernel)
            Imgproc.dilate(closed, expanded, expandKernel)
            Core.bitwise_and(expanded, clipQuad, clipped)
            if (Core.countNonZero(clipped) / maskArea > 0.72) {
                return _SourceMasks(foregroundArgb, emptyList())
            }
            val contours = mutableListOf<MatOfPoint>()
            val hierarchy = Mat()
            try {
                Imgproc.findContours(
                    clipped,
                    contours,
                    hierarchy,
                    Imgproc.RETR_EXTERNAL,
                    Imgproc.CHAIN_APPROX_SIMPLE,
                )
                val minDimension = max(
                    2,
                    (min(boxBounds.width, boxBounds.height) * 0.04).toInt(),
                )
                val minArea = max(2.0, maskArea * 0.0003)
                val polygons = contours.mapNotNull { contour ->
                    val contourBounds = Imgproc.boundingRect(contour)
                    if (Imgproc.contourArea(contour) < minArea ||
                        max(contourBounds.width, contourBounds.height) < minDimension
                    ) return@mapNotNull null
                    val contour2f = MatOfPoint2f(*contour.toArray())
                    val approximation = MatOfPoint2f()
                    try {
                        val perimeter = Imgproc.arcLength(contour2f, true)
                        Imgproc.approxPolyDP(
                            contour2f,
                            approximation,
                            max(0.5, perimeter * 0.004),
                            true,
                        )
                        val points = approximation.toArray()
                        if (points.size < 3) return@mapNotNull null
                        val polygon = canonical(points.map {
                            PointF(
                                (it.x + maskBounds.x).toFloat(),
                                (it.y + maskBounds.y).toFloat(),
                            )
                        })
                        _MaskPolygon(polygon, contourBounds)
                    } finally {
                        contour2f.release()
                        approximation.release()
                    }
                }.sortedWith(compareBy({ it.bounds.y }, { it.bounds.x },
                    { it.bounds.width * it.bounds.height }))
                    .map { it.points }
                _SourceMasks(foregroundArgb, polygons)
            } finally {
                contours.forEach(MatOfPoint::release)
                hierarchy.release()
            }
        } finally {
            roi.release()
            quad.release()
            clipQuad.release()
            background.release()
            foreground.release()
            strongBackground.release()
            strongForeground.release()
            innerQuad.release()
            closed.release()
            expanded.release()
            clipped.release()
            closeKernel.release()
            expandKernel.release()
        }
    }

    private data class _SourceMasks(
        val foregroundArgb: Int?,
        val polygons: List<List<PointF>>,
    )

    private data class _MaskPolygon(val points: List<PointF>, val bounds: Rect)

    private fun textCoreColor(image: Mat, selection: Mat, background: Int): Int {
        val contrastHistogram = IntArray(256)
        val pixels = ByteArray(image.cols() * 3)
        val selected = ByteArray(selection.cols())
        var selectedCount = 0
        for (y in 0 until image.rows()) {
            image.get(y, 0, pixels)
            selection.get(y, 0, selected)
            for (x in 0 until image.cols()) {
                if (selected[x].toInt() == 0) continue
                val offset = x * 3
                val contrast = maxOf(
                    kotlin.math.abs((pixels[offset + 2].toInt() and 0xff) -
                        Color.red(background)),
                    kotlin.math.abs((pixels[offset + 1].toInt() and 0xff) -
                        Color.green(background)),
                    kotlin.math.abs((pixels[offset].toInt() and 0xff) -
                        Color.blue(background)),
                )
                contrastHistogram[contrast]++
                selectedCount++
            }
        }
        var retained = 0
        var cutoff = 255
        val target = max(1, (selectedCount * 0.35).toInt())
        while (cutoff > 0 && retained < target) {
            retained += contrastHistogram[cutoff]
            cutoff--
        }
        cutoff = max(40, cutoff)
        val counts = IntArray(4096)
        val red = LongArray(4096)
        val green = LongArray(4096)
        val blue = LongArray(4096)
        for (y in 0 until image.rows()) {
            image.get(y, 0, pixels)
            selection.get(y, 0, selected)
            for (x in 0 until image.cols()) {
                if (selected[x].toInt() == 0) continue
                val offset = x * 3
                val b = pixels[offset].toInt() and 0xff
                val g = pixels[offset + 1].toInt() and 0xff
                val r = pixels[offset + 2].toInt() and 0xff
                val contrast = maxOf(
                    kotlin.math.abs(r - Color.red(background)),
                    kotlin.math.abs(g - Color.green(background)),
                    kotlin.math.abs(b - Color.blue(background)),
                )
                if (contrast < cutoff) continue
                val bucket = (r shr 4 shl 8) or (g shr 4 shl 4) or (b shr 4)
                counts[bucket]++
                red[bucket] += r.toLong()
                green[bucket] += g.toLong()
                blue[bucket] += b.toLong()
            }
        }
        val bucket = counts.indices.maxBy { counts[it] }
        check(counts[bucket] > 0) { "Cannot sample OCR foreground" }
        return Color.rgb(
            (red[bucket] / counts[bucket]).toInt(),
            (green[bucket] / counts[bucket]).toInt(),
            (blue[bucket] / counts[bucket]).toInt(),
        )
    }

    private fun polygonMask(box: OCRBox, roi: Rect): Mat {
        val mask = Mat.zeros(roi.height, roi.width, CvType.CV_8UC1)
        val points = MatOfPoint(*box.points.map {
            Point((it.x - roi.x).toDouble(), (it.y - roi.y).toDouble())
        }.toTypedArray())
        try {
            Imgproc.fillConvexPoly(mask, points, Scalar(255.0))
        } finally {
            points.release()
        }
        return mask
    }

    private fun bounds(points: List<PointF>, width: Int, height: Int): Rect {
        val left = floor(points.minOf { it.x }.toDouble()).toInt().coerceIn(0, width - 1)
        val top = floor(points.minOf { it.y }.toDouble()).toInt().coerceIn(0, height - 1)
        val right = ceil(points.maxOf { it.x }.toDouble()).toInt().coerceIn(left + 1, width)
        val bottom = ceil(points.maxOf { it.y }.toDouble()).toInt().coerceIn(top + 1, height)
        return Rect(left, top, right - left, bottom - top)
    }

    private fun inflate(rect: Rect, amount: Int, width: Int, height: Int): Rect {
        val left = max(0, rect.x - amount)
        val top = max(0, rect.y - amount)
        val right = min(width, rect.x + rect.width + amount)
        val bottom = min(height, rect.y + rect.height + amount)
        return Rect(left, top, right - left, bottom - top)
    }

    private fun lower(color: Int, tolerance: Double) = Scalar(
        max(0.0, Color.blue(color) - tolerance),
        max(0.0, Color.green(color) - tolerance),
        max(0.0, Color.red(color) - tolerance),
    )

    private fun upper(color: Int, tolerance: Double) = Scalar(
        min(255.0, Color.blue(color) + tolerance),
        min(255.0, Color.green(color) + tolerance),
        min(255.0, Color.red(color) + tolerance),
    )

    private fun colorDistance(a: Int, b: Int) = maxOf(
        kotlin.math.abs(Color.red(a) - Color.red(b)),
        kotlin.math.abs(Color.green(a) - Color.green(b)),
        kotlin.math.abs(Color.blue(a) - Color.blue(b)),
    )

    private fun center(box: OCRBox) = PointF(
        box.points.sumOf { it.x.toDouble() }.toFloat() / box.points.size,
        box.points.sumOf { it.y.toDouble() }.toFloat() / box.points.size,
    )

    private fun canonical(points: List<PointF>): List<PointF> {
        if (points.isEmpty()) return points
        val ordered = if (signedArea(points) < 0) points.reversed() else points
        val start = ordered.indices.minWith(compareBy({ ordered[it].y }, { ordered[it].x }))
        return List(ordered.size) { ordered[(start + it) % ordered.size] }
    }

    private fun signedArea(points: List<PointF>): Double = points.indices.sumOf { index ->
        val next = points[(index + 1) % points.size]
        points[index].x.toDouble() * next.y - next.x.toDouble() * points[index].y
    } / 2

    private fun contains(polygon: List<PointF>, point: PointF): Boolean {
        var inside = false
        var previous = polygon.last()
        for (current in polygon) {
            if ((current.y > point.y) != (previous.y > point.y) &&
                point.x < (previous.x - current.x) * (point.y - current.y) /
                    (previous.y - current.y) + current.x
            ) inside = !inside
            previous = current
        }
        return inside
    }
}
