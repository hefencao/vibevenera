package com.github.wgh136.venera

import android.view.Surface
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * WebP 动图 native texture 通路（仅 Android）。
 *
 * Dart 侧把已解码的 native RGBA 帧（Premultiplied, R,G,B,A 字节序）的**地址**
 * （int64）+ 宽高经 MethodChannel `venera/webp_texture` 传入，这里用
 * [nativeBlit]（JNI + ANativeWindow）直接从该地址 memcpy 进 SurfaceProducer 的
 * Surface。关键收益：像素字节不进 Dart、不经 MethodChannel 序列化，10MB 拷贝只在
 * native 侧发生一次；纹理 id 不变、每帧不分配 ui.Image、不触发 setState。
 *
 * 方法：
 *   create()  -> textureId(Long)
 *   update(textureId, width, height, address)  绘制一帧（address 为 native 像素地址）
 *   dispose(textureId)
 */
class WebPTexturePlugin(flutterEngine: FlutterEngine) {
    private val textures = flutterEngine.renderer
    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        "venera/webp_texture"
    )

    private val entries = HashMap<Long, TextureRegistry.SurfaceProducer>()

    /** JNI：从 native 像素地址 memcpy 进 surface。见 webp_texture_blit.c。 */
    private external fun nativeBlit(
        surface: Surface,
        address: Long,
        width: Int,
        height: Int,
    ): Boolean

    companion object {
        init {
            // 与 Dart FFI 加载的是同一个 .so；此处再 loadLibrary 只是确保 JNI
            // 符号在 Kotlin 侧可解析（幂等）。
            System.loadLibrary("venera_webp")
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "create" -> result.success(create())
                    "update" -> {
                        val id = (call.argument<Number>("textureId") ?: 0L).toLong()
                        val w = call.argument<Int>("width") ?: 0
                        val h = call.argument<Int>("height") ?: 0
                        val address = (call.argument<Number>("address") ?: 0L).toLong()
                        update(id, w, h, address)
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

    private fun update(textureId: Long, width: Int, height: Int, address: Long) {
        val producer = entries[textureId] ?: return
        if (width <= 0 || height <= 0 || address == 0L) return

        producer.setSize(width, height)
        val surface = producer.surface
        if (surface == null || !surface.isValid) return
        nativeBlit(surface, address, width, height)
    }

    private fun dispose(textureId: Long) {
        entries.remove(textureId)?.release()
    }

    fun disposeAll() {
        for (p in entries.values) p.release()
        entries.clear()
        channel.setMethodCallHandler(null)
    }
}
