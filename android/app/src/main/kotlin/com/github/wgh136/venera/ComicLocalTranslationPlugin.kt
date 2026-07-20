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
        sourcePrefixTokens: Array<String>,
        sourceEosToken: String,
        targetPrefixTokens: Array<String>,
        beamSize: Int,
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
    private val handles = LinkedHashMap<String, Long>()

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
        val modelKey = call.argument<String>("modelKey")!!
        if (handles.containsKey(modelKey)) return
        handles[modelKey] = LocalTranslationNative.create(
            call.argument<String>("modelPath")!!,
            call.argument<String>("sourceSpm")!!,
            call.argument<String>("targetSpm")!!,
            call.argument<List<String>>("sourcePrefixTokens")!!.toTypedArray(),
            call.argument<String>("sourceEosToken")!!,
            call.argument<List<String>>("targetPrefixTokens")!!.toTypedArray(),
            call.argument<Number>("beamSize")!!.toInt(),
            call.argument<Number>("threads")!!.toInt(),
        )
    }

    private fun translate(call: MethodCall): Array<String> {
        val handle = handles[call.argument<String>("modelKey")!!]
            ?: throw IllegalStateException("Local model is not loaded")
        val texts = call.argument<List<String>>("texts")!!.toTypedArray()
        return LocalTranslationNative.translate(handle, texts)
    }

    private fun unload() {
        handles.values.forEach(LocalTranslationNative::destroy)
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
