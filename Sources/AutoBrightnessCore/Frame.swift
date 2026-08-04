/// A downscaled screen capture. Pixels are BGRA, 8 bits per channel,
/// row-major, tightly packed: `bgra.count == width * height * 4`.
public struct Frame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let bgra: [UInt8]

    public init(width: Int, height: Int, bgra: [UInt8]) {
        self.width = width
        self.height = height
        self.bgra = bgra
    }
}
