package com.buildbydennis.mymy

import android.content.Intent
import android.net.VpnService
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of the `mymy/usage` channel (Phase 2 + Phase 3).
 *
 * Snapshot logic lives in [UsageSnapshotProvider], shared with
 * [BackgroundSamplingService], so live and background samples can
 * never disagree about a counter. This activity only routes channel
 * calls, opens usage settings, starts/stops the background service,
 * and runs the Phase 3 VPN consent + live-mode flow.
 *
 * Contract (see lib/src/models.dart): cumulative counters only, no
 * network call, nothing leaves the device. No INTERNET permission.
 *
 * VPN consent flow: [VpnService.prepare] returns null when consent
 * is already held (reply 'ready' at once) or an Intent otherwise. In
 * the second case the pending channel result is held and answered
 * from [onActivityResult] — 'ready' when the user approved, 'denied'
 * otherwise — so Dart never has to guess whether the system dialog
 * was accepted.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "mymy/usage"
    private val vpnPrepareRequestCode = 1001
    private var pendingVpnPrepareResult: MethodChannel.Result? = null

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
                "prepareVpn" -> prepareVpn(result)
                "startVpnLive" -> result.success(startVpnLive())
                "stopVpnLive" -> result.success(stopVpnLive())
                "isVpnLive" -> result.success(VpnLiveService.running)
                "getVpnStatus" -> result.success(getVpnStatus())
                "getVpnSnapshot" -> {
                    try {
                        result.success(getVpnSnapshot())
                    } catch (e: Exception) {
                        result.error(
                            "VPN_SNAPSHOT_FAILED",
                            e.message ?: "Failed to read VPN counters",
                            null,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Used for the VPN consent dialog result")
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        if (requestCode == vpnPrepareRequestCode) {
            val pending = pendingVpnPrepareResult
            pendingVpnPrepareResult = null
            if (resultCode == RESULT_OK) {
                pending?.success("ready")
            } else {
                pending?.success("denied")
            }
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun prepareVpn(result: MethodChannel.Result) {
        try {
            val intent = VpnService.prepare(this)
            if (intent == null) {
                result.success("ready")
                return
            }
            // A previous pending result must never hang: deny it
            // before replacing it with this one.
            pendingVpnPrepareResult?.success("denied")
            pendingVpnPrepareResult = result
            @Suppress("DEPRECATION")
            startActivityForResult(intent, vpnPrepareRequestCode)
        } catch (e: Exception) {
            result.success("error")
        }
    }

    private fun startVpnLive(): Boolean {
        return try {
            val intent = Intent(this, VpnLiveService::class.java)
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

    private fun stopVpnLive(): Boolean {
        // If the service is not running there is nothing to stop;
        // starting it just to stop it would be pointless churn.
        if (!VpnLiveService.running) return true
        return try {
            val intent = Intent(this, VpnLiveService::class.java).apply {
                action = VpnLiveService.ACTION_STOP
            }
            startService(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun getVpnStatus(): Map<String, Any?> {
        val counters = VpnLiveService.snapshotCounters()
        return mapOf(
            "active" to VpnLiveService.running,
            "startedAtMs" to VpnLiveService.startedAtMs,
            "error" to VpnLiveService.lastError,
            "totalRx" to counters.totalRx,
            "totalTx" to counters.totalTx,
            "unattributedRx" to counters.unattributedRx,
            "unattributedTx" to counters.unattributedTx,
        )
    }

    private fun getVpnSnapshot(): Map<String, Any> {
        val counters = VpnLiveService.snapshotCounters()
        val pm = packageManager
        val apps = mutableListOf<Map<String, Any>>()
        for ((uid, bytes) in counters.perUid) {
            val packages = try {
                pm.getPackagesForUid(uid)
            } catch (e: Exception) {
                null
            }
            val pkg = packages?.firstOrNull()
            val name = if (pkg != null) {
                try {
                    val info = pm.getApplicationInfo(pkg, 0)
                    pm.getApplicationLabel(info).toString()
                } catch (e: Exception) {
                    pkg
                }
            } else {
                "System (UID $uid)"
            }
            apps.add(
                mapOf(
                    "id" to (pkg ?: "uid:$uid"),
                    "name" to name,
                    "rx" to bytes.first,
                    "tx" to bytes.second,
                ),
            )
        }
        if (counters.unattributedRx > 0 || counters.unattributedTx > 0) {
            apps.add(
                mapOf(
                    "id" to "unattributed",
                    "name" to "Unattributed (could not be mapped)",
                    "rx" to counters.unattributedRx,
                    "tx" to counters.unattributedTx,
                ),
            )
        }
        return mapOf(
            "timestampMs" to System.currentTimeMillis(),
            "totalRx" to counters.totalRx,
            "totalTx" to counters.totalTx,
            "mobileRx" to -1L,
            "mobileTx" to -1L,
            "apps" to apps.sortedByDescending {
                (it["rx"] as Long) + (it["tx"] as Long)
            },
            "connections" to emptyList<Map<String, Any>>(),
            "source" to "vpn",
        )
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
