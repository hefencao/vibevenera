// Copyright (c) 2026 PaddlePaddle Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package com.paddle.ocr.preprocess

import android.graphics.Bitmap
import com.paddle.ocr.util.BitmapUtils
import com.paddle.ocr.util.ImageUtils
import org.opencv.core.Mat
import org.opencv.imgproc.Imgproc

data class DetPreprocessResult(
    val tensorData: FloatArray,
    val shape: LongArray,
    val originalH: Int,
    val originalW: Int,
)

object DetPreprocessor {
    private val mean = doubleArrayOf(0.485, 0.456, 0.406)
    private val std = doubleArrayOf(0.229, 0.224, 0.225)
    private const val scale = 1.0 / 255.0

    fun preprocess(
        bitmap: Bitmap,
        limitSideLen: Int,
        limitType: String,
        maxSideLimit: Int,
        imgMode: String,
    ): DetPreprocessResult {
        val src = BitmapUtils.bitmapToBGRMat(bitmap)
        return try {
            preprocess(src, limitSideLen, limitType, maxSideLimit, imgMode)
        } finally {
            src.release()
        }
    }

    fun preprocess(
        src: Mat,
        limitSideLen: Int,
        limitType: String,
        maxSideLimit: Int,
        imgMode: String,
    ): DetPreprocessResult {
        val originalH = src.rows()
        val originalW = src.cols()
        val input = if (imgMode.uppercase() == "RGB") {
            Mat().also { Imgproc.cvtColor(src, it, Imgproc.COLOR_BGR2RGB) }
        } else {
            src
        }

        val resized = ImageUtils.resizeToMultipleOf32(input, limitSideLen, limitType, maxSideLimit)
        if (input !== src) input.release()

        val h = resized.rows()
        val w = resized.cols()
        val channelSize = h * w
        val pixels = ByteArray(channelSize * 3)
        resized.get(0, 0, pixels)
        resized.release()

        val tensorData = FloatArray(3 * channelSize)
        for (i in 0 until channelSize) {
            val pixel = i * 3
            for (c in 0..2) {
                val value = pixels[pixel + c].toInt() and 0xff
                tensorData[c * channelSize + i] =
                    ((value * scale - mean[c]) / std[c]).toFloat()
            }
        }

        return DetPreprocessResult(
            tensorData = tensorData,
            shape = longArrayOf(1, 3, h.toLong(), w.toLong()),
            originalH = originalH,
            originalW = originalW,
        )
    }
}
