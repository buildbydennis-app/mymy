package com.buildbydennis.mymy

import java.net.InetAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * IPv4 / TCP / UDP packet parsing and construction for VpnLiveService.
 *
 * Scope, stated plainly:
 * - IPv4 only. No IPv6 route is added by the service, so IPv6 traffic
 *   bypasses the VPN entirely (it still works, it is simply not
 *   VPN-counted — see the reconciliation note in the plan).
 * - No content inspection: only IP/TCP/UDP headers are read, to route
 *   and count. Payload bytes are relayed opaquely and never logged.
 * - Counting rule (shared with the service): tx = IP total length of
 *   packets received from the TUN interface (app -> internet), rx =
 *   IP total length of packets written back to TUN. Headers are
 *   therefore included, which is the closest match to
 *   NetworkStatsManager's IP-layer accounting.
 */

data class Ipv4Header(
    val version: Int,
    val ihlBytes: Int,
    val totalLength: Int,
    val protocol: Int,
    val src: InetAddress,
    val dst: InetAddress,
)

data class TcpHeader(
    val srcPort: Int,
    val dstPort: Int,
    val seq: Long,
    val ack: Long,
    val flags: Int,
    val dataOffsetBytes: Int,
)

data class UdpHeader(
    val srcPort: Int,
    val dstPort: Int,
    val length: Int,
)

object VpnPacket {
    const val PROTO_TCP = 6
    const val PROTO_UDP = 17
    const val PROTO_ICMP = 1

    const val FLAG_FIN = 0x01
    const val FLAG_SYN = 0x02
    const val FLAG_RST = 0x04
    const val FLAG_PSH = 0x08
    const val FLAG_ACK = 0x10

    fun parseIpv4(packet: ByteArray, length: Int): Ipv4Header? {
        if (length < 20) return null
        val version = (packet[0].toInt() ushr 4) and 0x0F
        if (version != 4) return null
        val ihl = (packet[0].toInt() and 0x0F) * 4
        if (ihl < 20 || length < ihl) return null
        val totalLength = ((packet[2].toInt() and 0xFF) shl 8) or
            (packet[3].toInt() and 0xFF)
        if (totalLength < ihl || totalLength > length) return null
        val protocol = packet[9].toInt() and 0xFF
        val src = InetAddress.getByAddress(packet.copyOfRange(12, 16))
        val dst = InetAddress.getByAddress(packet.copyOfRange(16, 20))
        return Ipv4Header(version, ihl, totalLength, protocol, src, dst)
    }

    fun parseTcp(packet: ByteArray, ip: Ipv4Header): TcpHeader? {
        val off = ip.ihlBytes
        if (ip.totalLength < off + 20) return null
        val buf = ByteBuffer.wrap(packet, off, 20)
            .order(ByteOrder.BIG_ENDIAN)
        val srcPort = buf.short.toInt() and 0xFFFF
        val dstPort = buf.short.toInt() and 0xFFFF
        val seq = buf.int.toLong() and 0xFFFFFFFFL
        val ack = buf.int.toLong() and 0xFFFFFFFFL
        val dataOffset = ((buf.get().toInt() ushr 4) and 0x0F) * 4
        val flags = buf.get().toInt() and 0xFF
        if (dataOffset < 20) return null
        return TcpHeader(srcPort, dstPort, seq, ack, flags, dataOffset)
    }

    fun parseUdp(packet: ByteArray, ip: Ipv4Header): UdpHeader? {
        val off = ip.ihlBytes
        if (ip.totalLength < off + 8) return null
        val buf = ByteBuffer.wrap(packet, off, 8)
            .order(ByteOrder.BIG_ENDIAN)
        return UdpHeader(
            buf.short.toInt() and 0xFFFF,
            buf.short.toInt() and 0xFFFF,
            buf.short.toInt() and 0xFFFF,
        )
    }

    fun tcpPayload(packet: ByteArray, ip: Ipv4Header, tcp: TcpHeader): ByteArray {
        val start = ip.ihlBytes + tcp.dataOffsetBytes
        val end = ip.totalLength
        if (start >= end) return ByteArray(0)
        return packet.copyOfRange(start, end)
    }

    fun udpPayload(packet: ByteArray, ip: Ipv4Header): ByteArray {
        val start = ip.ihlBytes + 8
        val end = ip.totalLength
        if (start >= end) return ByteArray(0)
        return packet.copyOfRange(start, end)
    }

    /** 16-bit one's-complement checksum over [data] (pad odd length). */
    fun checksum(data: ByteArray, offset: Int = 0, length: Int = data.size): Int {
        var sum = 0L
        var i = offset
        val end = offset + length
        while (i + 1 < end) {
            sum += ((data[i].toInt() and 0xFF) shl 8) or
                (data[i + 1].toInt() and 0xFF)
            i += 2
        }
        if (i < end) sum += (data[i].toInt() and 0xFF) shl 8
        while ((sum ushr 16) != 0L) sum = (sum and 0xFFFF) + (sum ushr 16)
        return (sum.inv() and 0xFFFF).toInt()
    }

    private fun putIpHeader(
        buf: ByteBuffer,
        src: InetAddress,
        dst: InetAddress,
        protocol: Int,
        totalLength: Int,
    ) {
        buf.put(0x45.toByte()) // IPv4, IHL 5 (no options)
        buf.put(0.toByte()) // TOS
        buf.putShort(totalLength.toShort())
        buf.putShort(0) // identification
        buf.putShort(0x4000.toShort()) // DF flag, no fragment offset
        buf.put(64.toByte()) // TTL
        buf.put(protocol.toByte())
        buf.putShort(0) // checksum placeholder
        buf.put(src.address)
        buf.put(dst.address)
        val header = ByteArray(20)
        buf.rewind()
        buf.get(header)
        val sum = checksum(header)
        buf.putShort(10, sum.toShort())
    }

    fun buildTcpPacket(
        src: InetAddress,
        dst: InetAddress,
        srcPort: Int,
        dstPort: Int,
        seq: Long,
        ack: Long,
        flags: Int,
        payload: ByteArray,
    ): ByteArray {
        val totalLength = 20 + 20 + payload.size
        val buf = ByteBuffer.allocate(totalLength)
            .order(ByteOrder.BIG_ENDIAN)
        putIpHeader(buf, src, dst, PROTO_TCP, totalLength)
        buf.position(20)
        buf.putShort(srcPort.toShort())
        buf.putShort(dstPort.toShort())
        buf.putInt(seq.toInt())
        buf.putInt(ack.toInt())
        buf.put((0x50).toByte()) // data offset 5, no options
        buf.put(flags.toByte())
        buf.putShort(65535.toShort()) // window
        buf.putShort(0) // checksum placeholder
        buf.putShort(0) // urgent pointer
        buf.put(payload)
        // TCP checksum over pseudo-header + TCP header + payload.
        val pseudo = ByteBuffer.allocate(12 + 20 + payload.size)
            .order(ByteOrder.BIG_ENDIAN)
        pseudo.put(src.address)
        pseudo.put(dst.address)
        pseudo.put(0.toByte())
        pseudo.put(PROTO_TCP.toByte())
        pseudo.putShort((20 + payload.size).toShort())
        val tcpBytes = ByteArray(20 + payload.size)
        buf.position(20)
        buf.get(tcpBytes)
        pseudo.put(tcpBytes)
        val sum = checksum(pseudo.array())
        buf.putShort(20 + 16, sum.toShort())
        return buf.array()
    }

    fun buildUdpPacket(
        src: InetAddress,
        dst: InetAddress,
        srcPort: Int,
        dstPort: Int,
        payload: ByteArray,
    ): ByteArray {
        val totalLength = 20 + 8 + payload.size
        val buf = ByteBuffer.allocate(totalLength)
            .order(ByteOrder.BIG_ENDIAN)
        putIpHeader(buf, src, dst, PROTO_UDP, totalLength)
        buf.position(20)
        buf.putShort(srcPort.toShort())
        buf.putShort(dstPort.toShort())
        buf.putShort((8 + payload.size).toShort())
        // IPv4 UDP checksum of 0 means "no checksum" and is legal;
        // computing it is unnecessary for local relay and a wrong
        // checksum would be worse than none.
        buf.putShort(0)
        buf.put(payload)
        return buf.array()
    }
}
