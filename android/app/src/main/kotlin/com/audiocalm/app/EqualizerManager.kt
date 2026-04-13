package com.audio.vynce

import android.content.Context
import android.media.audiofx.Equalizer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object EqualizerManager {

    private var equalizer: Equalizer? = null
    private var audioSessionId: Int = 0
    private var isEnabled: Boolean = false

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        when (call.method) {
            "init" -> {
                val sessionId = call.argument<Int>("audioSessionId") ?: 0
                init(sessionId, result)
            }
            "setEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                setEnabled(enabled, result)
            }
            "setBandLevel" -> {
                val band  = call.argument<Int>("band")  ?: 0
                val level = call.argument<Int>("level") ?: 0
                setBandLevel(band, level, result)
            }
            "getBandLevel" -> {
                val band = call.argument<Int>("band") ?: 0
                getBandLevel(band, result)
            }
            "getProperties"   -> getProperties(result)
            "getBandFreqRange" -> {
                val band = call.argument<Int>("band") ?: 0
                getBandFreqRange(band, result)
            }
            "release" -> release(result)
            else      -> result.notImplemented()
        }
    }

    private fun init(sessionId: Int, result: MethodChannel.Result) {
        try {
            release(null)
            audioSessionId = sessionId
            equalizer = Equalizer(0, sessionId)
            equalizer?.enabled = isEnabled
            result.success(true)
        } catch (e: Exception) {
            result.error("EQ_INIT_ERROR", "Failed to init equalizer: ${e.message}", null)
        }
    }

    private fun setEnabled(enabled: Boolean, result: MethodChannel.Result) {
        isEnabled = enabled
        try {
            equalizer?.enabled = enabled
            result.success(true)
        } catch (e: Exception) { result.success(false) }
    }

    private fun setBandLevel(band: Int, levelMillibels: Int, result: MethodChannel.Result) {
        try {
            val eq = equalizer
            if (eq == null) { result.success(false); return }
            val bandCount = eq.numberOfBands.toInt()
            if (band < 0 || band >= bandCount) { result.success(false); return }
            val range   = eq.bandLevelRange
            val min     = range[0].toInt()
            val max     = range[1].toInt()
            val clamped = levelMillibels.coerceIn(min, max).toShort()
            eq.setBandLevel(band.toShort(), clamped)
            result.success(true)
        } catch (e: Exception) { result.success(false) }
    }

    private fun getBandLevel(band: Int, result: MethodChannel.Result) {
        try {
            val level = equalizer?.getBandLevel(band.toShort())?.toInt() ?: 0
            result.success(level)
        } catch (e: Exception) { result.success(0) }
    }

    private fun getProperties(result: MethodChannel.Result) {
        try {
            val eq = equalizer
            if (eq == null) {
                result.success(mapOf("bandCount" to 5, "minDb" to -1500, "maxDb" to 1500))
                return
            }
            val range = eq.bandLevelRange
            result.success(mapOf(
                "bandCount" to eq.numberOfBands.toInt(),
                "minDb"     to range[0].toInt(),
                "maxDb"     to range[1].toInt()
            ))
        } catch (e: Exception) {
            result.success(mapOf("bandCount" to 5, "minDb" to -1500, "maxDb" to 1500))
        }
    }

    private fun getBandFreqRange(band: Int, result: MethodChannel.Result) {
        try {
            val range = equalizer?.getBandFreqRange(band.toShort())
            result.success(range?.map { it.toInt() } ?: listOf(0, 0))
        } catch (e: Exception) { result.success(listOf(0, 0)) }
    }

    private fun release(result: MethodChannel.Result?) {
        try { equalizer?.release(); equalizer = null }
        catch (e: Exception) {}
        result?.success(true)
    }

    fun releaseAll() { release(null) }
}