import AppKit
import AutoBrightnessCore
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public enum SamplerStatus: Equatable {
    case idle
    case running
    /// The stream is nominally alive but has delivered nothing for a while, or
    /// it stopped and is being brought back. Adjustment is suspended meanwhile:
    /// a frozen measurement must never leave an offset applied.
    case stalled
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
///
/// The stream is treated as something that *will* break — display sleep and wake,
/// a monitor plugged in, a resolution change, a TCC grant arriving after launch.
/// `shouldBeRunning` records the caller's intent, and a maintenance timer keeps
/// reality matched to it. Without that, a stopped stream simply stops calling
/// back: the coordinator never ticks again, the last offset is never unwound, and
/// the panel sits several percent off with the UI still claiming to be running.
@MainActor
public final class ScreenSampler: NSObject {
    /// Capture width in pixels. Height is derived from the display's aspect
    /// ratio — a fixed 16:9 size on a 16:10 panel would make ScreenCaptureKit pad
    /// the frame, and that padding is indistinguishable from real letterboxing.
    static let captureWidth = 64
    /// How often to check that the stream is alive and, if not, do something.
    static let maintenanceInterval: TimeInterval = 2.0
    /// Frames arrive at 2 Hz. Four seconds of silence is eight missed frames:
    /// long enough not to trip on scheduling jitter, short enough that a user
    /// notices nothing.
    static let frameTimeout: TimeInterval = 4.0

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "com.mahmoudparham.autobrightness.capture")
    private let onFrame: @MainActor (Frame) -> Void
    private let onStatus: @MainActor (SamplerStatus) -> Void

    /// The caller's intent. Everything that restarts the stream is gated on this,
    /// so a stream stopped because the user disabled or paused the app is never
    /// quietly brought back by the watchdog.
    private var shouldBeRunning = false
    private var isReconciling = false
    private var lastFrameAt: Date?
    private var maintenanceTimer: Timer?
    private var reconfigurationObserver: (any NSObjectProtocol)?
    private var status: SamplerStatus = .idle {
        didSet {
            guard status != oldValue else { return }
            onStatus(status)
        }
    }

    public init(
        onFrame: @escaping @MainActor (Frame) -> Void,
        onStatus: @escaping @MainActor (SamplerStatus) -> Void
    ) {
        self.onFrame = onFrame
        self.onStatus = onStatus
        super.init()
    }

    /// Begins capturing, and keeps capturing across display reconfiguration,
    /// sleep/wake and stream failures until `stop()` is called.
    public func start() async {
        guard !shouldBeRunning else { return }
        shouldBeRunning = true
        startMaintenance()
        observeDisplayReconfiguration()
        await openStream()
    }

    /// Stops capturing entirely: no stream, no watchdog, no screen-recording
    /// indicator. Called whenever the app is disabled or paused — a user who
    /// turns this off expects to stop being watched.
    public func stop() async {
        guard shouldBeRunning else { return }
        shouldBeRunning = false
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        if let observer = reconfigurationObserver {
            NotificationCenter.default.removeObserver(observer)
            reconfigurationObserver = nil
        }
        await closeStream()
        status = .idle
    }

    /// Forces an immediate fresh attempt. Used by the "Try again" button after
    /// the user grants Screen Recording permission.
    public func retry() async {
        guard shouldBeRunning else { return }
        await restart()
    }

    // MARK: - Stream lifecycle

    private func openStream() async {
        guard shouldBeRunning, stream == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            // Asking again is harmless and is what re-surfaces the prompt if the
            // user dismissed it. The maintenance timer keeps checking, so a grant
            // made later is picked up without a relaunch when macOS allows it.
            CGRequestScreenCaptureAccess()
            status = .permissionDenied
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            // Built-in only, as specified. Measuring an external monitor's content
            // and aiming the offset at the built-in panel — or worse, at the
            // external's backlight — is not what this app promises to do.
            guard let display = content.displays.first(where: {
                CGDisplayIsBuiltin($0.displayID) != 0
            }) else {
                status = .noDisplay
                return
            }

            let configuration = SCStreamConfiguration()
            configuration.width = Self.captureWidth
            let aspect = Double(display.height) / Double(display.width)
            configuration.height = max(Int((Double(Self.captureWidth) * aspect).rounded()), 1)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
            // Documented valid range is 3-8; below 3 the stream may deliver no
            // frames at all. The design said 1, which was a spec bug: the queue
            // costs three 64x40 buffers, which is nothing.
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.capturesAudio = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()
            self.stream = stream
            lastFrameAt = Date()
            status = .running
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func closeStream() async {
        guard let stream else { return }
        self.stream = nil
        lastFrameAt = nil
        try? await stream.stopCapture()
    }

    private func restart() async {
        guard shouldBeRunning, !isReconciling else { return }
        isReconciling = true
        await closeStream()
        await openStream()
        isReconciling = false
    }

    // MARK: - Keeping the stream alive

    /// The timer holds only a weak reference, so it degrades to a no-op if the
    /// sampler is ever released without `stop()` being called first.
    private func startMaintenance() {
        maintenanceTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.maintenanceInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.reconcile() }
            }
        }
        timer.tolerance = Self.maintenanceInterval / 2
        maintenanceTimer = timer
    }

    /// Brings reality back in line with `shouldBeRunning`: reopens a stream that
    /// never opened (permission denied at launch, no display yet, a transient
    /// failure) and replaces one that has gone quiet.
    private func reconcile() async {
        guard shouldBeRunning, !isReconciling else { return }
        guard stream != nil else {
            isReconciling = true
            await openStream()
            isReconciling = false
            return
        }
        if let lastFrameAt, Date().timeIntervalSince(lastFrameAt) > Self.frameTimeout {
            // Report the stall first: the app must stop adjusting and unwind its
            // offset before we spend any time rebuilding the stream.
            status = .stalled
            await restart()
        }
    }

    private func observeDisplayReconfiguration() {
        guard reconfigurationObserver == nil else { return }
        reconfigurationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shouldBeRunning else { return }
                // Resolution change, monitor plugged in, clamshell opened: the
                // filter is bound to a display that may no longer exist.
                Task { await self.restart() }
            }
        }
    }

    fileprivate func handleFrame(_ frame: Frame) {
        lastFrameAt = Date()
        if status != .running {
            status = .running
        }
        onFrame(frame)
    }

    fileprivate func handleStreamStopped(error: (any Error)?) {
        guard shouldBeRunning else { return }
        status = error.map { .failed($0.localizedDescription) } ?? .stalled
        Task { await self.restart() }
    }
}

extension ScreenSampler: SCStreamDelegate {
    /// ScreenCaptureKit stops the stream on its own for reasons we cannot
    /// prevent — display reconfiguration, the capture engine restarting, a
    /// sandbox hiccup. Without this callback the app would sit there holding a
    /// dead stream and a stale brightness offset.
    public nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            self.handleStreamStopped(error: error)
        }
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
              Self.isComplete(sampleBuffer),
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = Self.makeFrame(from: imageBuffer) else { return }
        Task { @MainActor in
            self.handleFrame(frame)
        }
    }

    /// True for frames that actually contain new screen content.
    ///
    /// ScreenCaptureKit also delivers `.idle` and `.blank` frames, whose surface
    /// contents are undefined and often black. Measuring one of those would read
    /// as a pitch-dark screen and ramp the panel to the full positive offset on
    /// content that never changed.
    ///
    /// This deliberately fails *open*: a frame is rejected only when the status
    /// attachment is present, readable, and says the frame is not complete. If
    /// the attachment is missing or does not bridge as expected, the frame is
    /// measured. Rejecting on an unreadable attachment would drop every frame
    /// forever — a total, silent failure — in exchange for guarding an edge case.
    nonisolated static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status],
            let value = raw as? Int,
            let frameStatus = SCFrameStatus(rawValue: value) else { return true }
        return frameStatus == .complete
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
