package com.paddle.ocr.postprocess

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.PointF
import com.paddle.ocr.model.OCRBox
import com.paddle.ocr.util.BitmapUtils
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
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

object BubbleSegmenter {
    private const val BUBBLE_COLOR_TOLERANCE = 44.0
    private const val BUBBLE_REUSE_TOLERANCE = 28
    private const val TEXT_COLOR_TOLERANCE = 32.0

    data class RegionSegmentation(
        val backgroundArgb: Int,
        val bubblePolygon: List<PointF>?,
        val sourceMaskPolygons: List<List<PointF>>,
    )

    private data class BubbleCandidate(
        val polygon: List<PointF>,
        val color: Int,
        val area: Double,
        val bounds: Rect,
    )

    fun segment(bitmap: Bitmap, boxes: List<OCRBox>): List<RegionSegmentation> {
        if (boxes.isEmpty()) return emptyList()
        val image = BitmapUtils.bitmapToBGRMat(bitmap)
        val known = mutableListOf<BubbleCandidate>()
        return try {
            boxes.map { box ->
                val color = estimateBackground(image, box)
                val center = center(box)
                val boxBounds = bounds(box.points, image.cols(), image.rows())
                val bubble = known
                    .asSequence()
                    .filter {
                        contains(it.polygon, center) &&
                            colorDistance(it.color, color) <= BUBBLE_REUSE_TOLERANCE &&
                            plausibleFor(it, boxBounds)
                    }
                    .minByOrNull { it.area }
                    ?: segmentBubble(image, box, color)?.also(known::add)
                RegionSegmentation(
                    backgroundArgb = color,
                    bubblePolygon = bubble?.polygon,
                    sourceMaskPolygons = sourceMasks(image, box, color),
                )
            }
        } finally {
            image.release()
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
                width > boxBounds.width * 5.5 || height > boxBounds.height * 5.5
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
                    if (areaRatio !in 0.75..24.0 ||
                        pixelArea / contourArea < 0.55 ||
                        compactness < 0.18 || extent < 0.42 ||
                        solidity < 0.70 || oversizedRectangle ||
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
                            polygon,
                            color,
                            contourArea,
                            Rect(
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

    private fun sourceMasks(image: Mat, box: OCRBox, color: Int): List<List<PointF>> {
        val boxBounds = bounds(box.points, image.cols(), image.rows())
        val padding = (min(boxBounds.width, boxBounds.height) * 0.08).toInt().coerceIn(2, 8)
        val maskBounds = inflate(boxBounds, padding, image.cols(), image.rows())
        val roi = image.submat(maskBounds)
        val quad = polygonMask(box, maskBounds)
        val background = Mat()
        val foreground = Mat()
        val closed = Mat()
        val expanded = Mat()
        val clipped = Mat()
        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(3.0, 3.0))
        return try {
            Core.inRange(roi, lower(color, TEXT_COLOR_TOLERANCE),
                upper(color, TEXT_COLOR_TOLERANCE), background)
            Core.bitwise_not(background, foreground)
            Core.bitwise_and(foreground, quad, foreground)
            val quadArea = Core.countNonZero(quad).toDouble()
            val rawFraction = Core.countNonZero(foreground) / quadArea
            if (rawFraction !in 0.002..0.50) return emptyList()
            Imgproc.morphologyEx(foreground, closed, Imgproc.MORPH_CLOSE, kernel)
            Imgproc.dilate(closed, expanded, kernel)
            Core.bitwise_and(expanded, quad, clipped)
            if (Core.countNonZero(clipped) / quadArea > 0.65) return emptyList()
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
                val minArea = max(2.0, quadArea * 0.0003)
                contours.mapNotNull { contour ->
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
                            max(0.75, perimeter * 0.01),
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
            } finally {
                contours.forEach(MatOfPoint::release)
                hierarchy.release()
            }
        } finally {
            roi.release()
            quad.release()
            background.release()
            foreground.release()
            closed.release()
            expanded.release()
            clipped.release()
            kernel.release()
        }
    }

    private data class _MaskPolygon(val points: List<PointF>, val bounds: Rect)

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

    private fun plausibleFor(candidate: BubbleCandidate, box: Rect): Boolean =
        candidate.area / box.area() <= 24.0 &&
            candidate.bounds.width <= box.width * 5.5 &&
            candidate.bounds.height <= box.height * 5.5

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
