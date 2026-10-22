import Testing
@testable import AutoBrightnessCore

/// The reply a Lenovo P24h-30 actually sent to "get brightness", recorded
/// while designing this: current 100, maximum 100.
private let recordedReply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4, 0x00]

@Test("The brightness request carries its checksum")
func requestBytes() {
    #expect(DDCPacket.brightnessRequest() == [0x82, 0x01, 0x10, 0xAC])
}

@Test("A brightness write encodes the value big-endian with its checksum")
func writeBytes() {
    #expect(DDCPacket.brightnessWrite(70) == [0x84, 0x03, 0x10, 0x00, 0x46, 0xEE])
}

@Test("The recorded reply parses")
func parsesRecordedReply() {
    #expect(DDCPacket.parseBrightnessReply(recordedReply) == DDCReading(current: 100, maximum: 100))
}

@Test("A reply with a bad checksum is rejected")
func rejectsBadChecksum() {
    var reply = recordedReply
    reply[10] ^= 0x01
    #expect(DDCPacket.parseBrightnessReply(reply) == nil)
}

@Test("A reply reporting an unsupported code is rejected")
func rejectsErrorResult() {
    var reply = recordedReply
    reply[3] = 0x01
    reply[10] = reply[0..<10].reduce(UInt8(0x50), ^)
    #expect(DDCPacket.parseBrightnessReply(reply) == nil)
}

@Test("A reply for a different VCP code is rejected")
func rejectsOtherCode() {
    var reply = recordedReply
    reply[4] = 0x12
    reply[10] = reply[0..<10].reduce(UInt8(0x50), ^)
    #expect(DDCPacket.parseBrightnessReply(reply) == nil)
}

@Test("A short reply is rejected")
func rejectsShortReply() {
    #expect(DDCPacket.parseBrightnessReply(Array(recordedReply.prefix(8))) == nil)
}
