package com.buildbydennis.mymy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.os.Process
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Phase 3 — opt-in Android VPN live mode.
 *
 * How it works (the standard NetGuard-class design, on-device only):
 * a TUN interface captures the device's IPv4 traffic, this service
 * parses IP/TCP/UDP headers, attributes each connection to an app UID
 * with [ConnectivityManager.getConnectionOwnerUid] (the documented
 * VPN-app attribution API: it returns the UID for connections on the
 * calling VPN's tunnel, throws SecurityException if the caller is not
 * the active VPN, and returns INVALID_UID when a connection is not
 * found), then relays the traffic through *protected* sockets
 * ([VpnService.protect]) so relayed traffic does not loop back into
 * the tunnel. Payloads are relayed opaquely: only headers are read,
 * to route and count. Nothing is logged, inspected, or sent anywhere.
 *
 * Counting rule: tx = IP total length of packets received from TUN
 * (app -> internet), rx = IP total length of packets written back to
 * TUN. Headers included, closest to NetworkStatsManager's IP-layer
 * accounting — see Reconciliation in lib/src/vpn.dart for why the
 * two sources still differ and how that is surfaced, not hidden.
 *
 * Documented gaps (also in docs/BUILD_PLAN.md, do not soften them):
 * - IPv6: no IPv6 route is added, so IPv6 traffic bypasses the VPN.
 *   It still works; it is simply not VPN-counted.
 * - ICMP: dropped, not forwarded (ping does not work while VPN live
 *   is on).
 * - TCP out-of-order segments: dropped, no reordering buffer; TCP
 *   retransmission recovers. Retransmitted (already-acked) data is
 *   re-acked, never re-written to the remote socket.
 * - UDP attribution: [getConnectionOwnerUid] may return INVALID_UID
 *   for short-lived UDP flows; those bytes go to the 'unattributed'
 *   bucket, never to a guessed app.
 * - Connections established before VPN start are not VPN-counted.
 * - INTERNET permission is deliberately absent (see the manifest
 *   comment). If relay sockets are denied on a real device, that is
 *   the first thing to revisit — it is the top Phase 3 device-test
 *   item, not a proven fact.
 *
 * Lifecycle: start only after the Dart disclosure + system VPN
 * consent flow (MainActivity). Stop via the notification action, the
 * Dart toggle, or service destruction — all paths close the TUN
 * interface and every relay socket.
 */
class VpnLiveService : VpnService() {
    companion object {
        const val ACTION_STOP = "com.buildbydennis.mymy.STOP_VPN_LIVE"
        private const val NOTIFICATION_ID = 2
        private const val CHANNEL_ID = "mymy_vpn_live"
        private const val TUN_ADDRESS = "10.0.0.2"
        private const val MTU = 1500
        private const val TCP_IDLE_TIMEOUT_MS = 600_000L
        private const val UDP_IDLE_TIMEOUT_MS = 120_000L

        @Volatile
        var running: Boolean = false
            private set

        @Volatile
        var startedAtMs: Long? = null
            private set

        @Volatile
        var lastError: String = ""
            private set

        private val counters = ConcurrentHashMap<Int, LongArray>()
        private val countersLock = Any()

        @Volatile
        private var unattributedRx: Long = 0L

        @Volatile
        private var unattributedTx: Long = 0L

        @Volatile
        private var droppedPackets: Long = 0L

        fun count(uid: Int, rxDelta: Long, txDelta: Long) {
            if (rxDelta <= 0 && txDelta <= 0) return
            if (uid < 0) {
                // Unattributed bytes are counted, never guessed.
                synchronized(countersLock) {
                    unattributedRx += rxDelta
                    unattributedTx += txDelta
                }
                return
            }
            synchronized(countersLock) {
                val entry = counters.getOrPut(uid) { longArrayOf(0L, 0L) }
                entry[0] += rxDelta
                entry[1] += txDelta
            }
        }

        /** Snapshot for MainActivity to map UIDs to packages. */
        fun snapshotCounters(): VpnCounters {
            synchronized(countersLock) {
                val perUid = counters.entries.associate { (uid, v) ->
                    uid to (v[0] to v[1])
                }
                var totalRx = unattributedRx
                var totalTx = unattributedTx
                for ((rx, tx) in perUid.values) {
                    totalRx += rx
                    totalTx += tx
                }
                return VpnCounters(
                    perUid = perUid,
                    unattributedRx = unattributedRx,
                    unattributedTx = unattributedTx,
                    totalRx = totalRx,
                    totalTx = totalTx,
                    droppedPackets = droppedPackets,
                )
            }
        }

        fun noteDropped() {
            synchronized(countersLock) { droppedPackets++ }
        }

        internal fun setRunning(value: Boolean, error: String = "") {
            running = value
            lastError = error
            if (value) startedAtMs = System.currentTimeMillis()
        }

        internal fun resetCounters() {
            synchronized(countersLock) {
                counters.clear()
                unattributedRx = 0L
                unattributedTx = 0L
                droppedPackets = 0L
            }
        }
    }

    data class VpnCounters(
        val perUid: Map<Int, Pair<Long, Long>>,
        val unattributedRx: Long,
        val unattributedTx: Long,
        val totalRx: Long,
        val totalTx: Long,
        val droppedPackets: Long,
    )

    private data class TcpSession(
        val key: String,
        val uid: Int,
        val src: InetAddress,
        val dst: InetAddress,
        val srcPort: Int,
        val dstPort: Int,
        var socket: Socket?,
        var clientSeqNext: Long,
        var ourSeq: Long,
        var ourSeqNext: Long,
        var lastActivity: Long,
        var established: Boolean = false,
        var closing: Boolean = false,
    )

    private data class UdpSession(
        val key: String,
        val uid: Int,
        val src: InetAddress,
        val dst: InetAddress,
        val srcPort: Int,
        val dstPort: Int,
        val socket: DatagramSocket,
        var lastActivity: Long,
    )

    private var tun: ParcelFileDescriptor? = null
    private var tunIn: FileInputStream? = null
    private var tunOut: FileOutputStream? = null
    private val outputLock = Any()
    private val tcpSessions = ConcurrentHashMap<String, TcpSession>()
    private val udpSessions = ConcurrentHashMap<String, UdpSession>()
    private val executor = Executors.newCachedThreadPool { r ->
        Thread(r).apply { isDaemon = true }
    }
    private val stopped = AtomicBoolean(false)
    private var cleanupThread: HandlerThread? = null
    private var cleanupHandler: Handler? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        if (intent?.action == ACTION_STOP) {
            teardown()
            stopSelf()
            return Service.START_NOT_STICKY
        }
        if (running) return Service.START_STICKY
        stopped.set(false)
        try {
            startForeground(NOTIFICATION_ID, buildNotification())
        } catch (e: Exception) {
            // If foreground start fails on a given OS version, the
            // system VPN notification still shows while the VPN is
            // active; failing to start at all would be worse.
        }
        if (!establishTun()) {
            teardown()
            stopSelf()
            return Service.START_NOT_STICKY
        }
        startCleanup()
        executor.execute { packetLoop() }
        return Service.START_STICKY
    }

    override fun onDestroy() {
        teardown()
        super.onDestroy()
    }

    override fun onRevoke() {
        // The system revoked VPN permission (user turned it off in
        // Settings, or another VPN took over). Tear down cleanly so
        // the Dart side can report inactive instead of hanging.
        teardown()
        super.onRevoke()
    }

    private fun establishTun(): Boolean {
        return try {
            val builder = Builder()
                .setSession("MyMy Live")
                .addAddress(TUN_ADDRESS, 32)
                .addRoute("0.0.0.0", 0)
                .setMtu(MTU)
            // DNS: use the active network's DNS server, never a
            // hardcoded third-party resolver. If none is available,
            // no DNS server is added and DNS bypasses the VPN (it
            // still works, it is simply not VPN-counted).
            dnsServerFromActiveNetwork()?.let { builder.addDnsServer(it) }
            try {
                builder.addDisallowedApplication(packageName)
            } catch (ignored: Exception) {
            }
            val fd = builder.establish()
            if (fd == null) {
                setRunning(false, "Could not establish the VPN tunnel. " +
                    "Another VPN may be active.")
                return false
            }
            tun = fd
            tunIn = FileInputStream(fd.fileDescriptor)
            tunOut = FileOutputStream(fd.fileDescriptor)
            resetCounters()
            setRunning(true)
            true
        } catch (e: Exception) {
            setRunning(false, e.message ?: "Could not establish the VPN tunnel.")
            false
        }
    }

    private fun dnsServerFromActiveNetwork(): InetAddress? {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE)
                as ConnectivityManager
            val network = cm.activeNetwork ?: return null
            val props = cm.getLinkProperties(network) ?: return null
            props.dnsServers.firstOrNull()
        } catch (e: Exception) {
            null
        }
    }

    private fun teardown() {
        if (!stopped.compareAndSet(false, true)) return
        try {
            tunIn?.close()
        } catch (ignored: Exception) {
        }
        try {
            tunOut?.close()
        } catch (ignored: Exception) {
        }
        try {
            tun?.close()
        } catch (ignored: Exception) {
        }
        for (session in tcpSessions.values) {
            try {
                session.socket?.close()
            } catch (ignored: Exception) {
            }
        }
        tcpSessions.clear()
        for (session in udpSessions.values) {
            try {
                session.socket.close()
            } catch (ignored: Exception) {
            }
        }
        udpSessions.clear()
        cleanupHandler?.removeCallbacksAndMessages(null)
        cleanupThread?.quitSafely()
        try {
            @Suppress("DEPRECATION")
            stopForeground(true)
        } catch (ignored: Exception) {
        }
        setRunning(false)
    }

    private fun startCleanup() {
        HandlerThread("mymy-vpn-cleanup").also {
            it.start()
            cleanupThread = it
            cleanupHandler = Handler(it.looper)
        }
        val sweep = object : Runnable {
            override fun run() {
                if (stopped.get()) return
                val now = System.currentTimeMillis()
                for ((key, s) in tcpSessions) {
                    if (now - s.lastActivity > TCP_IDLE_TIMEOUT_MS) {
                        closeTcpSession(key, s)
                    }
                }
                for ((key, s) in udpSessions) {
                    if (now - s.lastActivity > UDP_IDLE_TIMEOUT_MS) {
                        try {
                            s.socket.close()
                        } catch (ignored: Exception) {
                        }
                        udpSessions.remove(key)
                    }
                }
                cleanupHandler?.postDelayed(this, 60_000L)
            }
        }
        cleanupHandler?.postDelayed(sweep, 60_000L)
    }

    private fun writeToTun(packet: ByteArray) {
        val out = tunOut ?: return
        synchronized(outputLock) {
            try {
                out.write(packet)
                out.flush()
            } catch (ignored: IOException) {
            }
        }
    }

    private fun attribute(
        protocol: Int,
        src: InetAddress,
        srcPort: Int,
        dst: InetAddress,
        dstPort: Int,
    ): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return -1
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE)
                as ConnectivityManager
            val uid = cm.getConnectionOwnerUid(
                protocol,
                InetSocketAddress(src, srcPort),
                InetSocketAddress(dst, dstPort),
            )
            if (uid == Process.INVALID_UID) -1 else uid
        } catch (e: SecurityException) {
            // Caller is not the active VPN (should not happen while
            // this service is the active VPN, but never guess).
            -1
        } catch (e: IllegalArgumentException) {
            -1
        } catch (e: Exception) {
            -1
        }
    }

    private fun packetLoop() {
        val input = tunIn ?: return
        val buffer = ByteArray(32767)
        while (!stopped.get()) {
            val length = try {
                input.read(buffer)
            } catch (e: IOException) {
                break
            }
            if (length <= 0) break
            try {
                handlePacket(buffer.copyOf(length))
            } catch (ignored: Exception) {
                noteDropped()
            }
        }
        if (!stopped.get()) {
            // TUN closed unexpectedly: tear down so Dart sees inactive.
            teardown()
        }
    }

    private fun handlePacket(packet: ByteArray) {
        val ip = VpnPacket.parseIpv4(packet, packet.size) ?: run {
            noteDropped()
            return
        }
        when (ip.protocol) {
            VpnPacket.PROTO_TCP -> handleTcp(packet, ip)
            VpnPacket.PROTO_UDP -> handleUdp(packet, ip)
            else -> noteDropped() // ICMP and others: not forwarded.
        }
    }

    // ---- TCP ----

    private fun handleTcp(packet: ByteArray, ip: Ipv4Header) {
        val tcp = VpnPacket.parseTcp(packet, ip) ?: run {
            noteDropped()
            return
        }
        val key = "${ip.src.hostAddress}:${tcp.srcPort}-" +
            "${ip.dst.hostAddress}:${tcp.dstPort}"
        val flags = tcp.flags
        if (flags and VpnPacket.FLAG_SYN != 0 &&
            flags and VpnPacket.FLAG_ACK == 0
        ) {
            if (tcpSessions.containsKey(key)) return
            val uid = attribute(
                VpnPacket.PROTO_TCP, ip.src, tcp.srcPort, ip.dst, tcp.dstPort,
            )
            val session = TcpSession(
                key = key,
                uid = uid,
                src = ip.src,
                dst = ip.dst,
                srcPort = tcp.srcPort,
                dstPort = tcp.dstPort,
                socket = null,
                clientSeqNext = (tcp.seq + 1) and 0xFFFFFFFFL,
                ourSeq = (System.currentTimeMillis() and 0xFFFFFFFFL),
                ourSeqNext = 0L,
                lastActivity = System.currentTimeMillis(),
            )
            session.ourSeqNext = session.ourSeq
            tcpSessions[key] = session
            count(uid, 0L, ip.totalLength.toLong())
            executor.execute { connectTcp(session) }
            return
        }
        val session = tcpSessions[key] ?: return // Unknown: drop, no RST storm.
        session.lastActivity = System.currentTimeMillis()
        count(session.uid, 0L, ip.totalLength.toLong())
        if (flags and VpnPacket.FLAG_RST != 0) {
            closeTcpSession(key, session)
            return
        }
        if (!session.established) {
            // ACK completing the handshake (or a retransmitted SYN).
            if (flags and VpnPacket.FLAG_ACK != 0) {
                session.established = true
            }
            return
        }
        if (flags and VpnPacket.FLAG_FIN != 0) {
            // ACK the FIN, then send our FIN and close.
            session.clientSeqNext = (tcp.seq + 1) and 0xFFFFFFFFL
            val ack = VpnPacket.buildTcpPacket(
                src = ip.dst, dst = ip.src,
                srcPort = tcp.dstPort, dstPort = tcp.srcPort,
                seq = session.ourSeqNext, ack = session.clientSeqNext,
                flags = VpnPacket.FLAG_ACK, payload = ByteArray(0),
            )
            writeToTun(ack)
            val fin = VpnPacket.buildTcpPacket(
                src = ip.dst, dst = ip.src,
                srcPort = tcp.dstPort, dstPort = tcp.srcPort,
                seq = session.ourSeqNext, ack = session.clientSeqNext,
                flags = VpnPacket.FLAG_FIN or VpnPacket.FLAG_ACK,
                payload = ByteArray(0),
            )
            writeToTun(fin)
            session.closing = true
            closeTcpSession(key, session)
            return
        }
        val payload = VpnPacket.tcpPayload(packet, ip, tcp)
        if (payload.isEmpty()) {
            // Pure ACK: nothing to forward.
            return
        }
        if (tcp.seq < session.clientSeqNext) {
            // Retransmission of already-acked data: re-ACK, do not
            // re-write to the remote socket (no double counting).
            val ack = VpnPacket.buildTcpPacket(
                src = ip.dst, dst = ip.src,
                srcPort = tcp.dstPort, dstPort = tcp.srcPort,
                seq = session.ourSeqNext, ack = session.clientSeqNext,
                flags = VpnPacket.FLAG_ACK, payload = ByteArray(0),
            )
            writeToTun(ack)
            return
        }
        if (tcp.seq != session.clientSeqNext) {
            // Out of order with no reordering buffer: drop; TCP
            // retransmission recovers. Documented gap.
            noteDropped()
            return
        }
        val socket = session.socket ?: return
        try {
            socket.getOutputStream().write(payload)
            socket.getOutputStream().flush()
            session.clientSeqNext =
                (session.clientSeqNext + payload.size) and 0xFFFFFFFFL
            val ack = VpnPacket.buildTcpPacket(
                src = ip.dst, dst = ip.src,
                srcPort = tcp.dstPort, dstPort = tcp.srcPort,
                seq = session.ourSeqNext, ack = session.clientSeqNext,
                flags = VpnPacket.FLAG_ACK, payload = ByteArray(0),
            )
            writeToTun(ack)
        } catch (e: IOException) {
            closeTcpSession(key, session)
        }
    }

    private fun connectTcp(session: TcpSession) {
        try {
            val socket = Socket()
            if (!protect(socket)) {
                closeTcpSession(session.key, session)
                return
            }
            socket.connect(
                InetSocketAddress(session.dst, session.dstPort), 15_000,
            )
            socket.tcpNoDelay = true
            session.socket = socket
            // SYN-ACK to the app.
            val synAck = VpnPacket.buildTcpPacket(
                src = session.dst, dst = session.src,
                srcPort = session.dstPort, dstPort = session.srcPort,
                seq = session.ourSeq, ack = session.clientSeqNext,
                flags = VpnPacket.FLAG_SYN or VpnPacket.FLAG_ACK,
                payload = ByteArray(0),
            )
            session.ourSeqNext = (session.ourSeq + 1) and 0xFFFFFFFFL
            writeToTun(synAck)
            executor.execute { readTcpRemote(session) }
        } catch (e: Exception) {
            // Remote unreachable: RST to the app, then close.
            val rst = VpnPacket.buildTcpPacket(
                src = session.dst, dst = session.src,
                srcPort = session.dstPort, dstPort = session.srcPort,
                seq = session.ourSeq, ack = session.clientSeqNext,
                flags = VpnPacket.FLAG_RST or VpnPacket.FLAG_ACK,
                payload = ByteArray(0),
            )
            writeToTun(rst)
            closeTcpSession(session.key, session)
        }
    }

    private fun readTcpRemote(session: TcpSession) {
        val socket = session.socket ?: return
        val buffer = ByteArray(16384)
        try {
            val input = socket.getInputStream()
            while (!stopped.get()) {
                val read = input.read(buffer)
                if (read < 0) break
                if (read == 0) continue
                val payload = buffer.copyOf(read)
                val packet = VpnPacket.buildTcpPacket(
                    src = session.dst, dst = session.src,
                    srcPort = session.dstPort, dstPort = session.srcPort,
                    seq = session.ourSeqNext, ack = session.clientSeqNext,
                    flags = VpnPacket.FLAG_PSH or VpnPacket.FLAG_ACK,
                    payload = payload,
                )
                session.ourSeqNext =
                    (session.ourSeqNext + read) and 0xFFFFFFFFL
                session.lastActivity = System.currentTimeMillis()
                count(session.uid, packet.size.toLong(), 0L)
                writeToTun(packet)
            }
        } catch (ignored: IOException) {
        }
        // Remote closed: FIN to the app, then close the session.
        if (!session.closing) {
            val fin = VpnPacket.buildTcpPacket(
                src = session.dst, dst = session.src,
                srcPort = session.dstPort, dstPort = session.srcPort,
                seq = session.ourSeqNext, ack = session.clientSeqNext,
                flags = VpnPacket.FLAG_FIN or VpnPacket.FLAG_ACK,
                payload = ByteArray(0),
            )
            writeToTun(fin)
        }
        closeTcpSession(session.key, session)
    }

    private fun closeTcpSession(key: String, session: TcpSession) {
        // Only remove this exact session: a newer session may have
        // reused the same 5-tuple after this one closed.
        tcpSessions.remove(key, session)
        try {
            session.socket?.close()
        } catch (ignored: Exception) {
        }
    }

    // ---- UDP (including DNS, which is UDP port 53) ----

    private fun handleUdp(packet: ByteArray, ip: Ipv4Header) {
        val udp = VpnPacket.parseUdp(packet, ip) ?: run {
            noteDropped()
            return
        }
        val key = "${ip.src.hostAddress}:${udp.srcPort}-" +
            "${ip.dst.hostAddress}:${udp.dstPort}"
        val now = System.currentTimeMillis()
        val existing = udpSessions[key]
        val session: UdpSession = if (existing != null) {
            existing
        } else {
            val uid = attribute(
                VpnPacket.PROTO_UDP, ip.src, udp.srcPort, ip.dst, udp.dstPort,
            )
            val created: UdpSession? = try {
                val socket = DatagramSocket()
                if (!protect(socket)) {
                    try {
                        socket.close()
                    } catch (ignored: Exception) {
                    }
                    null
                } else {
                    UdpSession(
                        key = key, uid = uid, src = ip.src, dst = ip.dst,
                        srcPort = udp.srcPort, dstPort = udp.dstPort,
                        socket = socket, lastActivity = now,
                    )
                }
            } catch (e: Exception) {
                null
            }
            if (created == null) return
            udpSessions[key] = created
            executor.execute { readUdpRemote(created) }
            created
        }
        session.lastActivity = now
        count(session.uid, 0L, ip.totalLength.toLong())
        try {
            val payload = VpnPacket.udpPayload(packet, ip)
            val datagram = DatagramPacket(
                payload, payload.size, ip.dst, udp.dstPort,
            )
            session.socket.send(datagram)
        } catch (ignored: IOException) {
        }
    }

    private fun readUdpRemote(session: UdpSession) {
        val buffer = ByteArray(65535)
        while (!stopped.get()) {
            try {
                val datagram = DatagramPacket(buffer, buffer.size)
                session.socket.receive(datagram)
                val payload = datagram.data.copyOf(datagram.length)
                val packet = VpnPacket.buildUdpPacket(
                    src = session.dst, dst = session.src,
                    srcPort = session.dstPort, dstPort = session.srcPort,
                    payload = payload,
                )
                session.lastActivity = System.currentTimeMillis()
                count(session.uid, packet.size.toLong(), 0L)
                writeToTun(packet)
            } catch (ignored: IOException) {
                break
            }
        }
        udpSessions.remove(session.key)
        try {
            session.socket.close()
        } catch (ignored: Exception) {
        }
    }

    // ---- Notification ----

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "MyMy VPN live",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shows while MyMy VPN live mode is counting " +
                "data usage on this device."
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val stopIntent = Intent(this, VpnLiveService::class.java)
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
        builder.setContentTitle("MyMy VPN live")
            .setContentText(
                "Counting data usage on this device only. " +
                    "Tap Stop to return to polling.",
            )
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
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
