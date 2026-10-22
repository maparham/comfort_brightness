/// DDC/CI framing for the one feature this app uses, VCP 0x10 (brightness).
///
/// Pure byte work, kept apart from the IOKit transport so it can be checked
/// against a reply recorded from real hardware.
public enum DDCPacket {
    /// The monitor's DDC/CI I²C address.
    public static let chipAddress: UInt32 = 0x37
    /// The host's sub-address every DDC/CI message is sent to.
    public static let dataAddress: UInt32 = 0x51
    /// Bytes to read for a "get VCP" reply. Eleven carry meaning; reading one
    /// more is what the transport was first proven with.
    public static let replyLength = 12

    private static let brightnessCode: UInt8 = 0x10

    /// "Get VCP feature 0x10".
    public static func brightnessRequest() -> [UInt8] {
        sealed([0x82, 0x01, brightnessCode])
    }

    /// "Set VCP feature 0x10 to `value`".
    public static func brightnessWrite(_ value: Int) -> [UInt8] {
        let clamped = UInt16(clamping: value)
        return sealed([0x84, 0x03, brightnessCode, UInt8(clamped >> 8), UInt8(clamped & 0xFF)])
    }

    /// Current and maximum from a "get VCP" reply, or nil for anything that is
    /// not a well-formed, successful brightness reply.
    public static func parseBrightnessReply(_ reply: [UInt8]) -> DDCReading? {
        guard reply.count >= 11,
              reply[2] == 0x02,              // "VCP feature reply"
              reply[3] == 0x00,              // result: no error
              reply[4] == brightnessCode,
              reply[0..<10].reduce(UInt8(0x50), ^) == reply[10] else { return nil }
        let maximum = Int(reply[6]) << 8 | Int(reply[7])
        let current = Int(reply[8]) << 8 | Int(reply[9])
        return DDCReading(current: current, maximum: maximum)
    }

    /// Appends the host-to-display checksum: the XOR of the destination
    /// address (0x6E), the source address (0x51) and every body byte.
    private static func sealed(_ body: [UInt8]) -> [UInt8] {
        body + [body.reduce(UInt8(0x6E ^ 0x51), ^)]
    }
}
