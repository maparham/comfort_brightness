import AutoBrightnessCore
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public enum SamplerStatus: Equatable {
    case idle
    case running
    case permissionDenied
    case noDisplay
    case failed(String)
}

/// Captures the built-in display at 2 fps, downscaled to a thumbnail, and hands
/// each frame to the analyzer.
///
/// The capture size is tiny on purpose: the compositor does the downscale on the
/// GPU, so a 64x40 frame costs almost nothing and still carries all the
/// information the luminance statistic needs.
@MainActor
public final class ScreenSampler: NSObject {
    /// Capture width in pixels. Height is derived from the display's aspect
    /// ratio — a fixed 16:9 size on a 16:10 panel would make ScreenCaptureKit pad
    /// the frame, and that padding is indistinguishable from real letterboxing.
    static let captureWidth = 64

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "com.mahmoudparham.autobrightness.capture")
    private let onFrame: @MainActor (Frame) -> Void
    private let onStatus: @MainActor (SamplerStatus) -> Void

    public init(
        onFrame: @escaping @MainActor (Frame) -> Void,
        onStatus: @escaping @MainActor (SamplerStatus) -> Void
    ) {
        self.onFrame = onFrame
        self.onStatus = onStatus
        super.init()
    }

    public func start() async {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            onStatus(.permissionDenied)
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let mainID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainID })
                ?? content.displays.first else {
                onStatus(.noDisplay)
                return
            }

            let configuration = SCStreamConfiguration()
            configuration.width = Self.captureWidth
            let aspect = Double(display.height) / Double(display.width)
            configuration.height = max(Int((Double(Self.captureWidth) * aspect).rounded()), 1)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
            configuration.queueDepth = 1
            configuration.showsCursor = false
            configuration.capturesAudio = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()
            self.stream = stream
            onStatus(.running)
        } catch {
            onStatus(.failed(error.localizedDescription))
        }
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        onStatus(.idle)
    }
}

extension ScreenSampler: SCStreamOutput {
    public nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = Self.makeFrame(from: imageBuffer) else { return }
        Task { @MainActor in
            self.onFrame(frame)
        }
    }

    /// Copies a `CVPixelBuffer` into a tightly packed `Frame`.
    ///
    /// The buffer's `bytesPerRow` is usually larger than `width * 4` because of
    /// alignment padding, so rows must be copied individually — reading it as one
    /// contiguous block would skew every row and corrupt the luminance reading.
    nonisolated static func makeFrame(from buffer: CVPixelBuffer) -> Frame? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        var bgra = [UInt8]()
        bgra.reserveCapacity(width * height * 4)
        for row in 0..<height {
            let start = row * bytesPerRow
            for column in 0..<(width * 4) {
                bgra.append(pointer[start + column])
            }
        }
        return Frame(width: width, height: height, bgra: bgra)
    }
}
