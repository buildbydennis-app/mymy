package com.buildbydennis.mymy

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of the `mymy/usage` channel (Phase 2).
 *
 * Snapshot logic lives in [UsageSnapshotProvider], shared with
 * [BackgroundSamplingService], so live and background samples can
 * never disagree about a counter. This activity only routes channel
 * calls, opens usage settings, and starts/stops the service.
 *
 * Contract (see lib/src/models.dart): cumulative counters only, no
 * network call, nothing leaves the device. No INTERNET permission.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "mymy/usage"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStatus" -> result.success(getStatus())
                "openUsageSettings" -> result.success(openUsageSettings())
                "getSnapshot" -> {
                    try {
                        result.success(UsageSnapshotProvider.getSnapshot(this))
                    } catch (e: Exception) {
                        result.error(
                            "SNAPSHOT_FAILED",
                            e.message ?: "Failed to read usage counters",
                            null,
                        )
                    }
                }
                "startBackgroundSampling" ->
                    result.success(startBackgroundSampling())
                "stopBackgroundSampling" ->
                    result.success(stopBackgroundSampling())
                "isBackgroundSampling" ->
                    result.success(BackgroundSamplingService.running)
                "getBackgroundSamples" ->
                    result.success(getBackgroundSamples())
                "clearBackgroundSamples" -> {
                    clearBackgroundSamples()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun getStatus(): Map<String, Any> {
        val granted = UsageSnapshotProvider.hasUsageAccess(this)
        return mapOf(
            "hasPermission" to granted,
            "engine" to "network-stats",
            "note" to if (granted) {
                "Usage access granted. Per-app totals use " +
                    "NetworkStatsManager; live rates are 1-second polling " +
                    "deltas of those counters."
            } else {
                "Usage access not granted. Device totals still work, but " +
                    "per-app totals need usage access in Settings."
            },
        )
    }

    private fun openUsageSettings(): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun startBackgroundSampling(): Boolean {
        return try {
            val intent = Intent(this, BackgroundSamplingService::class.java)
            if (android.os.Build.VERSION.SDK_INT >=
                android.os.Build.VERSION_CODES.O
            ) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun stopBackgroundSampling(): Boolean {
        return try {
            val intent = Intent(this, BackgroundSamplingService::class.java)
            stopService(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun getBackgroundSamples(): List<String> {
        return try {
            val file = BackgroundSamplingService.samplesFile(this)
            if (!file.exists()) emptyList() else file.readLines()
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun clearBackgroundSamples() {
        try {
            BackgroundSamplingService.samplesFile(this).delete()
        } catch (ignored: Exception) {
        }
    }
}
