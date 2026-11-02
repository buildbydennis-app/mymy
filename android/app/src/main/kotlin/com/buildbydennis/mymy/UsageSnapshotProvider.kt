package com.buildbydennis.mymy

import android.app.AppOpsManager
import android.app.usage.NetworkStatsManager
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.TrafficStats
import android.os.Build
import android.os.Process
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

/**
 * Shared snapshot logic, used by both MainActivity (live channel) and
 * BackgroundSamplingService (once-per-minute samples while the UI is
 * closed). Keeping one implementation here is what keeps the live tab
 * and the background samples from ever disagreeing about a counter.
 *
 * Contract (see lib/src/models.dart): cumulative counters only. No
 * network call is ever made here. Nothing leaves the device.
 */
object UsageSnapshotProvider {
    fun hasUsageAccess(context: Context): Boolean {
        return try {
            val appOps =
                context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                context.packageName,
            )
            mode == AppOpsManager.MODE_ALLOWED
        } catch (e: Exception) {
            false
        }
    }

    fun getSnapshot(context: Context): Map<String, Any> {
        val apps = if (hasUsageAccess(context)) {
            queryPerAppToday(context)
        } else {
            emptyList()
        }
        return mapOf(
            "timestampMs" to System.currentTimeMillis(),
            "totalRx" to TrafficStats.getTotalRxBytes(),
            "totalTx" to TrafficStats.getTotalTxBytes(),
            "mobileRx" to TrafficStats.getMobileRxBytes(),
            "mobileTx" to TrafficStats.getMobileTxBytes(),
            "apps" to apps,
            "connections" to emptyList<Map<String, Any>>(),
        )
    }

    /** Same snapshot as [getSnapshot], serialised for the service file. */
    fun snapshotJson(context: Context): String {
        val snapshot = getSnapshot(context)
        val json = JSONObject()
        json.put("timestampMs", snapshot["timestampMs"] as Long)
        json.put("totalRx", snapshot["totalRx"] as Long)
        json.put("totalTx", snapshot["totalTx"] as Long)
        json.put("mobileRx", snapshot["mobileRx"] as Long)
        json.put("mobileTx", snapshot["mobileTx"] as Long)
        val appsJson = JSONArray()
        @Suppress("UNCHECKED_CAST")
        val apps = snapshot["apps"] as List<Map<String, Any>>
        for (app in apps) {
            val item = JSONObject()
            item.put("id", app["id"] as String)
            item.put("name", app["name"] as String)
            item.put("rx", app["rx"] as Long)
            item.put("tx", app["tx"] as Long)
            appsJson.put(item)
        }
        json.put("apps", appsJson)
        json.put("connections", JSONArray())
        return json.toString()
    }

    private fun queryPerAppToday(context: Context): List<Map<String, Any>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return emptyList()
        val manager =
            context.getSystemService(Context.NETWORK_STATS_SERVICE)
                as? NetworkStatsManager
                ?: return emptyList()

        val end = System.currentTimeMillis()
        val start = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis

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
                continue
            }
        }

        val pm: PackageManager = context.packageManager
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
