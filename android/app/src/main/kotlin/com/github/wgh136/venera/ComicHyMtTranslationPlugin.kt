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

private object LocalHyMtNative {
    val loadFailure = try {
        System.loadLibrary("venera_hymt")
        null
    } catch (error: UnsatisfiedLinkError) {
        error
    }

    external fun create(
        modelPath: String,
        contextSize: Int,
        maxOutputTokens: Int,
        threads: Int,
    ): Long
    external fun translate(handle: Long, texts: Array<String>): Array<String>
    external fun destroy(handle: Long)
}

class ComicHyMtTranslationPlugin(
    flutterEngine: FlutterEngine,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        "venera/comic_translation_hymt",
    )
    private val mainHandler = Handler(Looper.getMainLooper())
    private val dispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val handles = LinkedHashMap<String, Long>()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(LocalHyMtNative.loadFailure == null)
            "load" -> execute(result) { load(call); null }
            "translate" -> execute(result) { translate(call).toList() }
            "unload" -> execute(result) { unload(); null }
            else -> result.notImplemented()
        }
    }

    private fun load(call: MethodCall) {
        val failure = LocalHyMtNative.loadFailure
        if (failure != null) {
            throw IllegalStateException("llama.cpp native runtime is unavailable", failure)
        }
        val modelKey = call.argument<String>("modelKey")!!
        if (handles.containsKey(modelKey)) return
        handles[modelKey] = LocalHyMtNative.create(
            call.argument<String>("modelPath")!!,
            call.argument<Number>("contextSize")!!.toInt(),
            call.argument<Number>("maxOutputTokens")!!.toInt(),
            call.argument<Number>("threads")!!.toInt(),
        )
    }

    private fun translate(call: MethodCall): Array<String> {
        val handle = handles[call.argument<String>("modelKey")!!]
            ?: throw IllegalStateException("Hy-MT model is not loaded")
        return LocalHyMtNative.translate(
            handle,
            call.argument<List<String>>("texts")!!.toTypedArray(),
        )
    }

    private fun unload() {
        handles.values.forEach(LocalHyMtNative::destroy)
        handles.clear()
    }

    private fun execute(result: MethodChannel.Result, action: () -> Any?) {
        scope.launch {
            try {
                val value = action()
                mainHandler.post { result.success(value) }
            } catch (error: Throwable) {
                mainHandler.post {
                    result.error(
                        "comic_translation_hymt",
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
