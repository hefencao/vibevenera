package com.github.wgh136.venera

import android.graphics.Bitmap
import android.graphics.PorterDuff
import android.os.Build
import android.view.Surface
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer

/**
 * WebP 动图 native texture 通路（仅 Android）。
 *
 * Dart 侧把已解码的 native RGBA 帧（Premultiplied, R,G,B,A 字节序）作为
 * Uint8List 通过 MethodChannel `venera/webp_texture` 传入，这里写入
 * SurfaceProducer 的 Surface。关键收益不是上传更快，而是：纹理 id 不变、
 * 每帧不在 Dart 侧分配 ui.Image、不触发 setState/widget 重建。
 *
 * 方法：
 *   create()  -> textureId(Long)
 *   update(textureId, width, height, pixels)  绘制一帧
 *   dispose(textureId)
 */
class WebPTexturePlugin(flutterEngine: FlutterEngine) {
    private val textures = flutterEngine.renderer
    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        "venera/webp_texture"
    )

    private val entries = HashMap<Long, TextureRegistry.SurfaceProducer>()
    private val bitmaps = HashMap<Long, Bitmap>()

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "create" -> result.success(create())
                    "update" -> {
                        val id = (call.argument<Number>("textureId") ?: 0L).toLong()
                        val w = call.argument<Int>("width") ?: 0
                        val h = call.argument<Int>("height") ?: 0
                        val pixels = call.argument<ByteArray>("pixels")
                        update(id, w, h, pixels)
                        result.success(null)
                    }
                    "dispose" -> {
                        val id = (call.argument<Number>("textureId") ?: 0L).toLong()
                        dispose(id)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                result.error("webp_texture", e.message, null)
            }
        }
    }

    private fun create(): Long {
        val producer = textures.createSurfaceProducer()
        entries[producer.id()] = producer
        return producer.id()
    }

    private fun update(textureId: Long, width: Int, height: Int, pixels: ByteArray?) {
        val producer = entries[textureId] ?: return
        if (width <= 0 || height <= 0 || pixels == null) return
        if (pixels.size < width * height * 4) return

        producer.setSize(width, height)

        // 复用/重建承载帧的 bitmap（尺寸变化时重建）。
        var bitmap = bitmaps[textureId]
        if (bitmap == null || bitmap.width != width || bitmap.height != height) {
            bitmap?.recycle()
            bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            bitmap.setPremultiplied(true)
            bitmaps[textureId] = bitmap
        }
        // native 帧是 Premultiplied RGBA8888；ARGB_8888 Bitmap 的内存布局
        // 即 R,G,B,A 字节序，copyPixelsFromBuffer 直接吃这段字节。
        bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(pixels))

        val surface = producer.surface
        if (surface == null || !surface.isValid) return
        val canvas = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            surface.lockHardwareCanvas()
        } else {
            surface.lockCanvas(null)
        }
        try {
            canvas.drawColor(0, PorterDuff.Mode.CLEAR)
            canvas.drawBitmap(bitmap, 0f, 0f, null)
        } finally {
            surface.unlockCanvasAndPost(canvas)
        }
    }

    private fun dispose(textureId: Long) {
        entries.remove(textureId)?.release()
        bitmaps.remove(textureId)?.recycle()
    }

    fun disposeAll() {
        for (p in entries.values) p.release()
        entries.clear()
        for (b in bitmaps.values) b.recycle()
        bitmaps.clear()
        channel.setMethodCallHandler(null)
    }
}
