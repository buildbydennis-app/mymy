package com.buildbydennis.mymy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import java.io.File

/**
 * Android foreground service, Phase 2.
 *
 * Samples once per minute while the UI is closed and appends raw
 * snapshots (one JSON line each) to
 * filesDir/mymy_background_samples.jsonl. The Dart side merges those
 * lines into history on reopen (see lib/src/background.dart) and then
 * clears the file. The service never aggregates, never deletes history,
 * and never talks to a network — it only writes that one local file.
 *
 * The notification is real and ongoing, with a Stop action. If
 * notifications are not granted (Android 13+), startForeground can
 * fail; the channel start method then reports false and the UI switch
 * stays off, instead of the service dying silently.
 */
class BackgroundSamplingService : Service() {
    companion object {
        const val ACTION_STOP = "com.buildbydennis.mymy.STOP_SAMPLING"
        const val SAMPLES_FILE = "mymy_background_samples.jsonl"
        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "mymy_sampling"
        private const val INTERVAL_MS = 60_000L

        @Volatile
        var running: Boolean = false
            private set

        fun samplesFile(context: Context): File =
            File(context.filesDir, SAMPLES_FILE)
    }

    private var thread: HandlerThread? = null
    private var handler: Handler? = null

    private val tick = object : Runnable {
        override fun run() {
            try {
                val line = UsageSnapshotProvider.snapshotJson(
                    applicationContext,
                )
                samplesFile(applicationContext).appendText(line + "\n")
            } catch (ignored: Exception) {
                // A failed sample must not kill the service; the next
                // minute's sample still records, and the gap is at
                // most one minute of granularity, never invented data.
            }
            handler?.postDelayed(this, INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        running = true
        createChannel()
        val thread = HandlerThread("mymy-sampling").also {
            it.start()
            this.thread = it
            handler = Handler(it.looper)
        }
        handler?.post(tick)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            @Suppress("DEPRECATION")
            stopForeground(true)
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            startForeground(NOTIFICATION_ID, buildNotification())
        } catch (e: Exception) {
            // e.g. notifications not granted: do not run invisibly.
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        handler?.removeCallbacks(tick)
        thread?.quitSafely()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "MyMy background sampling",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shows while MyMy records data usage in background."
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val stopIntent = Intent(this, BackgroundSamplingService::class.java)
            .apply { action = ACTION_STOP }
        val stopPending = PendingIntent.getService(
            this,
            0,
            stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val launchPending = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder.setContentTitle("MyMy is sampling")
            .setContentText("Data usage is being recorded once per minute.")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .addAction(
                android.R.drawable.ic_media_pause,
                "Stop",
                stopPending,
            )
        if (launchPending != null) builder.setContentIntent(launchPending)
        return builder.build()
    }
}
