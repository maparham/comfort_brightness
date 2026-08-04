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

Two phases, because one alone cannot answer the question. Holding the panel with
our own writes and observing no drift proves nothing on its own: it is exactly
what we would see if our writes were simply overpowering the ambient loop. So the
probe first watches without writing anything, to learn what the ambient
controller does when left alone, and only then holds the panel.
""")

/// Watches the panel for `seconds`, writing nothing.
func observe(seconds: Int, label: String) -> Double {
    print("\n--- \(label): \(seconds)s, read-only ---")
    var maximum = 0.0
    for tick in 0..<(seconds * 2) {
        let drift = brightness() - original
        maximum = max(maximum, abs(drift))
        if tick % 20 == 0 {
            print(String(
                format: "t=%5.1fs  observed=%.4f  drift=%+.4f",
                Double(tick) / 2.0, original + drift, drift
            ))
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return maximum
}

let passiveDrift = observe(seconds: 60, label: "Phase 1, passive")

print("\n--- Phase 2, active hold: 180s, writing \(String(format: "%.4f", original)) at 2 Hz ---")
var activeDrift = 0.0
for tick in 0..<360 {
    let observed = brightness()
    let drift = observed - original
    activeDrift = max(activeDrift, abs(drift))
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

let threshold = 0.01
print(String(
    format: "\nMax drift — passive: %.4f, active hold: %.4f (threshold %.2f)",
    passiveDrift, activeDrift, threshold
))
switch (passiveDrift < threshold, activeDrift < threshold) {
case (true, true):
    print("""
    RESULT: inconclusive-but-benign. The ambient controller did not move the panel
    even when left alone, so the room was too steady for it to act and the active
    phase proves nothing beyond it. Coexistence is not contradicted. To make this
    conclusive, rerun and change the room lighting during phase 1 so the ambient
    loop is visibly active before phase 2 begins.
    """)
case (false, true):
    print("""
    RESULT: coexistence holds. The ambient controller was demonstrably moving the
    panel on its own, and the app's writes held it steady without a fight — which
    is what the offset design needs: our writes win, and any movement the sensor
    does make is folded into the baseline.
    """)
case (_, false):
    print("""
    RESULT: interference. The panel drifted away from what we wrote, twice a
    second, so the two controllers are fighting. The app must tell the user to
    turn "Automatically adjust brightness" off.
    """)
}
