package com.github.wgh136.venera

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.util.concurrent.Executors

private object LocalTranslationNative {
    val loadFailure = try {
        System.loadLibrary("venera_translation")
        null
    } catch (error: UnsatisfiedLinkError) {
        error
    }

    external fun create(
        modelPath: String,
        sourceSpm: String,
        targetSpm: String,
        threads: Int,
    ): Long
    external fun translate(handle: Long, texts: Array<String>): Array<String>
    external fun destroy(handle: Long)
}

class ComicLocalTranslationPlugin(
    flutterEngine: FlutterEngine,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        "venera/comic_translation_local",
    )
    private val mainHandler = Handler(Looper.getMainLooper())
    private val dispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private var handle = 0L

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(LocalTranslationNative.loadFailure == null)
            "load" -> execute(result) { load(call); null }
            "translate" -> execute(result) { translate(call).toList() }
            "unload" -> execute(result) { unload(); null }
            else -> result.notImplemented()
        }
    }

    private fun load(call: MethodCall) {
        val failure = LocalTranslationNative.loadFailure
        if (failure != null) {
            throw IllegalStateException("CTranslate2 native runtime is unavailable", failure)
        }
        unload()
        handle = LocalTranslationNative.create(
            call.argument<String>("modelPath")!!,
            call.argument<String>("sourceSpm")!!,
            call.argument<String>("targetSpm")!!,
            call.argument<Number>("threads")!!.toInt(),
        )
    }

    private fun translate(call: MethodCall): Array<String> {
        if (handle == 0L) throw IllegalStateException("Local model is not loaded")
        val texts = call.argument<List<String>>("texts")!!.toTypedArray()
        return LocalTranslationNative.translate(handle, texts)
    }

    private fun unload() {
        if (handle == 0L) return
        LocalTranslationNative.destroy(handle)
        handle = 0L
    }

    private fun execute(result: MethodChannel.Result, action: () -> Any?) {
        scope.launch {
            try {
                val value = action()
                mainHandler.post { result.success(value) }
            } catch (error: Throwable) {
                mainHandler.post {
                    result.error(
                        "comic_translation_local",
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
