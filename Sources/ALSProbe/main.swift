import CoreGraphics
import Foundation

// Self-contained symbol resolution: executable targets cannot import each other,
// so this duplicates the few lines it needs rather than restructuring the app.
private typealias DSGet = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias DSSet = @convention(c) (CGDirectDisplayID, Float) -> Int32

let handle = dlopen(
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
    RTLD_LAZY
)
guard let handle,
      let getSymbol = dlsym(handle, "DisplayServicesGetBrightness"),
      let setSymbol = dlsym(handle, "DisplayServicesSetBrightness") else {
    fatalError("DisplayServices brightness symbols unavailable")
}
private let get = unsafeBitCast(getSymbol, to: DSGet.self)
private let set = unsafeBitCast(setSymbol, to: DSSet.self)
let display = CGMainDisplayID()

func brightness() -> Double {
    var value: Float = 0
    _ = get(display, &value)
    return Double(value)
}

let original = brightness()
print("""
ALS interaction probe
=====================
Before starting: turn ON "Automatically adjust brightness" in
System Settings > Displays, hold the lighting in the room steady, and leave a
static window on screen. Do not touch the brightness keys while this runs.

Original brightness: \(String(format: "%.4f", original))
Holding brightness at \(String(format: "%.4f", original)) with 2 Hz writes for 3 minutes.
If the ambient controller fights us, the observed value will drift away from the
written value between writes.
""")

var maxDrift = 0.0
let ticks = 360  // 3 minutes at 2 Hz
for tick in 0..<ticks {
    let observed = brightness()
    let drift = observed - original
    maxDrift = max(maxDrift, abs(drift))
    if tick % 20 == 0 {
        print(String(
            format: "t=%5.1fs  observed=%.4f  drift=%+.4f",
            Double(tick) / 2.0, observed, drift
        ))
    }
    _ = set(display, Float(original))
    Thread.sleep(forTimeInterval: 0.5)
}

_ = set(display, Float(original))
print(String(format: "\nMax drift observed: %.4f", maxDrift))
print(maxDrift < 0.01
    ? "RESULT: no meaningful interference. Coexistence holds."
    : "RESULT: drift detected. The app must tell the user to disable auto-brightness.")
