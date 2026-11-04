package com.buildbydennis.mymy

import android.app.ActivityManager
import android.app.AppOpsManager
import android.app.usage.NetworkStatsManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.net.ConnectivityManager
import android.net.TrafficStats
import android.os.BatteryManager
import android.os.Build
import android.os.Process
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
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
            item.put("mobileRx", (app["mobileRx"] as? Long) ?: -1L)
            item.put("mobileTx", (app["mobileTx"] as? Long) ?: -1L)
            appsJson.put(item)
        }
        json.put("apps", appsJson)
        json.put("connections", JSONArray())
        return json.toString()
    }

    /**
     * Phase 5 — every installed application PackageManager returns,
     * including system apps, with a system flag and enabled state.
     * The list is the merge base for the all-apps list: an installed
     * app with no data today still appears (as 0), never hidden.
     *
     * Honest limit: on Android 11+ this is subject to package
     * visibility filtering unless the app holds QUERY_ALL_PACKAGES,
     * which Phase 5 deliberately does NOT add (Play policy risk —
     * see BUILD_PLAN). The UI must never claim this list is proven
     * complete until a device test compares it against Settings.
     */
    @Suppress("DEPRECATION")
    fun getInstalledApps(context: Context): List<Map<String, Any>> {
        val pm: PackageManager = context.packageManager
        val installed = try {
            pm.getInstalledApplications(0)
        } catch (e: Exception) {
            return emptyList()
        }
        return installed.mapNotNull { info ->
            val pkg = info.packageName ?: return@mapNotNull null
            val label = try {
                pm.getApplicationLabel(info).toString()
            } catch (e: Exception) {
                pkg
            }
            val isSystem = (info.flags and ApplicationInfo.FLAG_SYSTEM) != 0 ||
                (info.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
            mapOf<String, Any>(
                "package" to pkg,
                "label" to label,
                "isSystem" to isSystem,
                "enabled" to info.enabled,
                "uid" to info.uid,
            )
        }.sortedBy { (it["label"] as String).lowercase() }
    }

    /**
     * Phase 5 — observable activity per package. UsageStatsManager
     * (needs the usage-access grant) gives foreground time + last
     * used; ActivityManager gives the running-process list, which
     * modern Android limits — a package absent from it is reported
     * as NOT reported-running, never as proven-not-running. Feature
     * badges come from AppOpsManager checks for this package; an op
     * that is not MODE_ALLOWED is simply absent. Any failure in one
     * source degrades that source to empty, never to guessed values.
     */
    fun getAppActivity(context: Context): List<Map<String, Any>> {
        val out = mutableMapOf<String, MutableMap<String, Any>>()
        fun entry(pkg: String): MutableMap<String, Any> =
            out.getOrPut(pkg) {
                mutableMapOf(
                    "package" to pkg,
                    "foregroundSeconds" to 0L,
                    "osReportedRunning" to false,
                    "features" to mutableListOf<String>(),
                )
            }
        val start = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        val now = System.currentTimeMillis()
        try {
            val usage = context.getSystemService(Context.USAGE_STATS_SERVICE)
                as? UsageStatsManager
            val stats = usage?.queryUsageStats(
                UsageStatsManager.INTERVAL_DAILY, start, now,
            ) ?: emptyList()
            for (s in stats) {
                val pkg = s.packageName ?: continue
                val e = entry(pkg)
                e["foregroundSeconds"] = s.totalTimeInForeground / 1000
                if (s.lastTimeUsed > 0) e["lastUsedMs"] = s.lastTimeUsed
            }
        } catch (e: Exception) {
            // UsageStats unavailable: activity simply stays empty.
        }
        try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE)
                as? ActivityManager
            val running = am?.runningAppProcesses ?: emptyList()
            for (proc in running) {
                for (pkg in proc.pkgList ?: emptyArray()) {
                    entry(pkg)["osReportedRunning"] = true
                }
            }
        } catch (e: Exception) {
            // Running-process list unavailable: no package is marked.
        }
        try {
            val appOps = context.getSystemService(Context.APP_OPS_SERVICE)
                as? AppOpsManager
            val pm = context.packageManager
            if (appOps != null) {
                val ops = listOf(
                    AppOpsManager.OPSTR_CAMERA to "Camera",
                    AppOpsManager.OPSTR_RECORD_AUDIO to "Microphone",
                    AppOpsManager.OPSTR_FINE_LOCATION to "Fine location",
                )
                @Suppress("DEPRECATION")
                val installed = try {
                    pm.getInstalledApplications(0)
                } catch (e: Exception) {
                    emptyList()
                }
                for (info in installed) {
                    val pkg = info.packageName ?: continue
                    for ((op, label) in ops) {
                        val allowed = try {
                            appOps.checkOpNoThrow(op, info.uid, pkg) ==
                                AppOpsManager.MODE_ALLOWED
                        } catch (e: Exception) {
                            false
                        }
                        if (allowed) {
                            @Suppress("UNCHECKED_CAST")
                            (entry(pkg)["features"] as MutableList<String>)
                                .add(label)
                        }
                    }
                }
            }
        } catch (e: Exception) {
            // AppOps unavailable: no feature badges, never guesses.
        }
        return out.values.toList()
    }

    /** Phase 5 — one app icon, scaled to at most 96px, as PNG bytes. */
    fun getAppIcon(context: Context, packageName: String): ByteArray? {
        return try {
            val pm = context.packageManager
            val info = pm.getApplicationInfo(packageName, 0)
            val drawable = pm.getApplicationIcon(info)
            val bitmap = when (drawable) {
                is BitmapDrawable -> drawable.bitmap
                else -> {
                    val w = drawable.intrinsicWidth.takeIf { it > 0 } ?: 96
                    val h = drawable.intrinsicHeight.takeIf { it > 0 } ?: 96
                    val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                    drawable.setBounds(0, 0, w, h)
                    drawable.draw(Canvas(bmp))
                    bmp
                }
            }
            val scaled = if (bitmap.width > 96 || bitmap.height > 96) {
                val scale = 96f / maxOf(bitmap.width, bitmap.height)
                Bitmap.createScaledBitmap(
                    bitmap,
                    (bitmap.width * scale).toInt().coerceAtLeast(1),
                    (bitmap.height * scale).toInt().coerceAtLeast(1),
                    true,
                )
            } else {
                bitmap
            }
            val stream = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.PNG, 100, stream)
            stream.toByteArray()
        } catch (e: Exception) {
            null
        }
    }

    /** Phase 5 — device-level battery only. No per-app battery exists. */
    fun getBattery(context: Context): Map<String, Any> {
        return try {
            val intent = context.registerReceiver(
                null, IntentFilter(Intent.ACTION_BATTERY_CHANGED),
            )
            if (intent == null) {
                return mapOf("levelPercent" to -1, "charging" to false)
            }
            val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            val percent = if (level >= 0 && scale > 0) {
                (level * 100 / scale)
            } else {
                -1
            }
            val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
            val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                status == BatteryManager.BATTERY_STATUS_FULL
            mapOf("levelPercent" to percent, "charging" to charging)
        } catch (e: Exception) {
            mapOf("levelPercent" to -1, "charging" to false)
        }
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

        // Phase 5: keep Wi-Fi and mobile totals separate per UID, so
        // Dart can draw app -> Mobile / Wi-Fi edges only where a real
        // per-transport signal exists. A failed mobile query leaves
        // that UID's mobile split at -1 (unknown), never 0-as-no-use.
        // totals[uid] = (rx, tx, mobileRx, mobileTx); mobile = -1
        // means the mobile query produced nothing for that UID.
        val totals = mutableMapOf<Int, LongArray>()
        val networkTypes = listOf(
            ConnectivityManager.TYPE_WIFI to false,
            ConnectivityManager.TYPE_MOBILE to true,
        )
        for ((type, isMobile) in networkTypes) {
            try {
                val stats = manager.querySummary(type, null, start, end)
                try {
                    val bucket = android.app.usage.NetworkStats.Bucket()
                    while (stats.hasNextBucket()) {
                        stats.getNextBucket(bucket)
                        if (bucket.uid < 0) continue
                        val prev = totals.getOrPut(bucket.uid) {
                            longArrayOf(0L, 0L, -1L, -1L)
                        }
                        prev[0] += bucket.rxBytes
                        prev[1] += bucket.txBytes
                        if (isMobile) {
                            if (prev[2] < 0) prev[2] = 0L
                            if (prev[3] < 0) prev[3] = 0L
                            prev[2] += bucket.rxBytes
                            prev[3] += bucket.txBytes
                        }
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
            .filter { it.value[0] > 0 || it.value[1] > 0 }
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
                        "rx" to bytes[0],
                        "tx" to bytes[1],
                        "mobileRx" to bytes[2],
                        "mobileTx" to bytes[3],
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
                    "rx" to bytes[0],
                    "tx" to bytes[1],
                    "mobileRx" to bytes[2],
                    "mobileTx" to bytes[3],
                )
            }
            .sortedByDescending { (it["rx"] as Long) + (it["tx"] as Long) }
    }
}
