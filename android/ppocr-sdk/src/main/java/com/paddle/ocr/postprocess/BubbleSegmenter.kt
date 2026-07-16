package com.paddle.ocr.postprocess

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.PointF
import com.paddle.ocr.model.OCRBox
import com.paddle.ocr.util.BitmapUtils
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Rect
import org.opencv.core.Scalar
import org.opencv.imgproc.Imgproc
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

object BubbleSegmenter {
    private const val COLOR_TOLERANCE = 44.0

    fun segment(
        bitmap: Bitmap,
        boxes: List<OCRBox>,
        backgroundArgb: List<Int>,
    ): List<List<PointF>?> {
        if (boxes.isEmpty()) return emptyList()
        val image = BitmapUtils.bitmapToBGRMat(bitmap)
        val known = mutableListOf<List<PointF>>()
        return try {
            boxes.mapIndexed { index, box ->
                val center = PointF(
                    box.points.sumOf { it.x.toDouble() }.toFloat() / box.points.size,
                    box.points.sumOf { it.y.toDouble() }.toFloat() / box.points.size,
                )
                known.firstOrNull { contains(it, center) } ?: segmentOne(
                    image,
                    box,
                    backgroundArgb[index],
                )?.also(known::add)
            }
        } finally {
            image.release()
        }
    }

    private fun segmentOne(image: Mat, box: OCRBox, color: Int): List<PointF>? {
        val boxLeft = floor(box.points.minOf { it.x }.toDouble()).toInt()
        val boxTop = floor(box.points.minOf { it.y }.toDouble()).toInt()
        val boxRight = ceil(box.points.maxOf { it.x }.toDouble()).toInt()
        val boxBottom = ceil(box.points.maxOf { it.y }.toDouble()).toInt()
        val boxWidth = max(1, boxRight - boxLeft)
        val boxHeight = max(1, boxBottom - boxTop)
        val margin = max(48, (max(boxWidth, boxHeight) * 1.5).toInt())
        val left = max(0, boxLeft - margin)
        val top = max(0, boxTop - margin)
        val right = min(image.cols(), boxRight + margin)
        val bottom = min(image.rows(), boxBottom + margin)
        val roiRect = Rect(left, top, right - left, bottom - top)
        val roi = image.submat(roiRect)
        val binary = Mat()
        val labels = Mat()
        val stats = Mat()
        val centroids = Mat()
        val component = Mat()
        return try {
            val blue = Color.blue(color).toDouble()
            val green = Color.green(color).toDouble()
            val red = Color.red(color).toDouble()
            Core.inRange(
                roi,
                Scalar(
                    max(0.0, blue - COLOR_TOLERANCE),
                    max(0.0, green - COLOR_TOLERANCE),
                    max(0.0, red - COLOR_TOLERANCE),
                ),
                Scalar(
                    min(255.0, blue + COLOR_TOLERANCE),
                    min(255.0, green + COLOR_TOLERANCE),
                    min(255.0, red + COLOR_TOLERANCE),
                ),
                binary,
            )
            Imgproc.connectedComponentsWithStats(
                binary,
                labels,
                stats,
                centroids,
                8,
                CvType.CV_32S,
            )
            val counts = HashMap<Int, Int>()
            val step = max(1, min(boxWidth, boxHeight) / 24)
            for (y in max(boxTop, top) until min(boxBottom, bottom) step step) {
                for (x in max(boxLeft, left) until min(boxRight, right) step step) {
                    val label = labels.get(y - top, x - left)[0].toInt()
                    if (label != 0) counts[label] = (counts[label] ?: 0) + 1
                }
            }
            if (counts.isEmpty()) return null
            val label = counts.maxBy { it.value }.key
            val area = stats.get(label, Imgproc.CC_STAT_AREA)[0]
            if (area > roiRect.area() * 0.88 || area < boxWidth * boxHeight * 0.35) {
                return null
            }
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
                val contour2f = MatOfPoint2f(*contour.toArray())
                val approximation = MatOfPoint2f()
                try {
                    Imgproc.approxPolyDP(
                        contour2f,
                        approximation,
                        Imgproc.arcLength(contour2f, true) * 0.008,
                        true,
                    )
                    val points = approximation.toArray().map {
                        PointF((it.x + left).toFloat(), (it.y + top).toFloat())
                    }
                    if (points.size < 4) null else points
                } finally {
                    contour2f.release()
                    approximation.release()
                }
            } finally {
                contours.forEach(MatOfPoint::release)
                hierarchy.release()
            }
        } finally {
            roi.release()
            binary.release()
            labels.release()
            stats.release()
            centroids.release()
            component.release()
        }
    }

    private fun contains(polygon: List<PointF>, point: PointF): Boolean {
        var inside = false
        var previous = polygon.last()
        for (current in polygon) {
            if ((current.y > point.y) != (previous.y > point.y) &&
                point.x < (previous.x - current.x) * (point.y - current.y) /
                    (previous.y - current.y) + current.x
            ) {
                inside = !inside
            }
            previous = current
        }
        return inside
    }
}
