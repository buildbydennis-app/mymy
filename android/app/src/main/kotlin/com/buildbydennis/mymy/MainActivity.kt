package com.buildbydennis.mymy

import android.app.AppOpsManager
import android.app.usage.NetworkStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.TrafficStats
import android.os.Build
import android.os.Process
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Calendar

/**
 * Native side of the `mymy/usage` channel.
 *
 * Contract (see lib/src/models.dart):
 * - This code reports CUMULATIVE counters only. Live speeds are derived
 *   in Dart from successive snapshots.
 * - Every call is guarded: a missing permission returns
 *   hasPermission=false / empty per-app data instead of crashing.
 * - No network call is ever made here. Nothing leaves the device.
 *
 * Android mechanics, stated plainly:
 * - Per-app totals come from NetworkStatsManager.querySummary() over
 *   today's window. That API needs usage access (PACKAGE_USAGE_STATS,
 *   granted by the user in Settings, not at install time).
 * - TrafficStats.getUidRxBytes/getUidTxBytes are NOT used for other apps:
 *   since Android N they return UNSUPPORTED for any UID other than the
 *   caller's, so live per-app rates are polling deltas of the
 *   NetworkStatsManager totals, not packet-level measurements.
 * - Mobile per-app totals are queried with a null subscriberId. On some
 *   devices that returns no mobile buckets; device-wide mobile totals
 *   from TrafficStats still work, and that gap is a device-test item
 *   (see docs/BUILD_PLAN.md), not something to paper over.
 * - Apps sharing one UID (rare) are attributed to the first package for
 *   that UID; their traffic cannot be split by this API.
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
                        result.success(getSnapshot())
                    } catch (e: Exception) {
                        result.error(
                            "SNAPSHOT_FAILED",
                            e.message ?: "Failed to read usage counters",
                            null,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasUsageAccess(): Boolean {
        return try {
            val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                packageName,
            )
            mode == AppOpsManager.MODE_ALLOWED
        } catch (e: Exception) {
            false
        }
    }

    private fun getStatus(): Map<String, Any> {
        val granted = hasUsageAccess()
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

    private fun getSnapshot(): Map<String, Any> {
        val apps = if (hasUsageAccess()) queryPerAppToday() else emptyList()
        return mapOf(
            "timestampMs" to System.currentTimeMillis(),
            // TrafficStats returns UNSUPPORTED (-1) when a counter is not
            // available on the device; pass it through so the UI shows "—"
            // instead of a fabricated zero.
            "totalRx" to TrafficStats.getTotalRxBytes(),
            "totalTx" to TrafficStats.getTotalTxBytes(),
            "mobileRx" to TrafficStats.getMobileRxBytes(),
            "mobileTx" to TrafficStats.getMobileTxBytes(),
            "apps" to apps,
            // Android has no per-connection list in this channel in Phase 1.
            "connections" to emptyList<Map<String, Any>>(),
        )
    }

    /**
     * Per-app cumulative totals for today, summed across Wi-Fi and mobile.
     * Returns an empty list on any failure (including missing permission),
     * never throws into the channel handler.
     */
    private fun queryPerAppToday(): List<Map<String, Any>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return emptyList()
        val manager =
            getSystemService(Context.NETWORK_STATS_SERVICE) as? NetworkStatsManager
                ?: return emptyList()

        val end = System.currentTimeMillis()
        val start = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis

        // uid -> (rx, tx), summed across network types.
        val totals = mutableMapOf<Int, Pair<Long, Long>>()
        val networkTypes = listOf(
            ConnectivityManager.TYPE_WIFI,
            ConnectivityManager.TYPE_MOBILE,
        )
        for (type in networkTypes) {
            try {
                val stats = manager.querySummary(type, null, start, end)
                try {
                    val bucket = android.app.usage.NetworkStats.Bucket()
                    while (stats.hasNextBucket()) {
                        stats.getNextBucket(bucket)
                        if (bucket.uid < 0) continue
                        val prev = totals[bucket.uid] ?: (0L to 0L)
                        totals[bucket.uid] = (
                            prev.first + bucket.rxBytes
                            ) to (prev.second + bucket.txBytes)
                    }
                } finally {
                    try {
                        stats.close()
                    } catch (ignored: Exception) {
                    }
                }
            } catch (e: Exception) {
                // One network type failing must not kill the other, and
                // must not kill the snapshot. The gap (e.g. mobile buckets
                // empty on a given device) is a device-test finding.
                continue
            }
        }

        val pm: PackageManager = packageManager
        val labelCache = mutableMapOf<String, String>()
        return totals.entries
            .filter { it.value.first > 0 || it.value.second > 0 }
            .mapNotNull { (uid, bytes) ->
                val packages = try {
                    pm.getPackagesForUid(uid)
                } catch (e: Exception) {
                    null
                }
                if (packages.isNullOrEmpty()) {
                    // System / shared UID with no package name: still real
                    // traffic, labelled as such rather than dropped.
                    return@mapNotNull mapOf(
                        "id" to "uid:$uid",
                        "name" to "System (UID $uid)",
                        "rx" to bytes.first,
                        "tx" to bytes.second,
                    )
                }
                val pkg = packages[0]
                val label = labelCache.getOrPut(pkg) {
                    try {
                        val info = pm.getApplicationInfo(pkg, 0)
                        pm.getApplicationLabel(info).toString()
                    } catch (e: Exception) {
                        pkg
                    }
                }
                mapOf(
                    "id" to pkg,
                    "name" to label,
                    "rx" to bytes.first,
                    "tx" to bytes.second,
                )
            }
            .sortedByDescending { (it["rx"] as Long) + (it["tx"] as Long) }
    }
}
