# Content-Adaptive Brightness for macOS — Design

Date: 2026-08-04
Target: macOS 26.5, Apple Silicon, built-in Liquid Retina display

## Problem

macOS adjusts display brightness from the ambient light sensor but ignores what is
on the screen. A near-white document in a dim room is uncomfortably bright; a dark
full-screen video at the same backlight level is muddy and hard to see.

This app samples on-screen content and applies a bounded brightness offset on top of
whatever brightness the user (or the ambient sensor) has already chosen.

## Decisions

| Question | Decision |
|---|---|
| Brightness mechanism | Real hardware backlight via private API |
| Relationship to user's brightness | Bounded offset, not replacement |
| Displays | Built-in only; externals untouched |
| Default strength | ±20% offset, ~2s ramp |
| App shape | Menu-bar app with optional debug panel |
| App Store distribution | Not a goal |

macOS "Automatically adjust brightness" may remain enabled. The offset design
coexists with it rather than fighting it (see Baseline Tracking).

### Feasibility, verified

On this machine (macOS 26.5, arm64) the following symbols resolve:

- `DisplayServices.framework`: `DisplayServicesGetBrightness`,
  `DisplayServicesSetBrightness`, `DisplayServicesCanChangeBrightness`
- `CoreDisplay.framework`: `CoreDisplay_Display_GetUserBrightness`,
  `CoreDisplay_Display_SetUserBrightness`
- `ScreenCaptureKit.framework` present

`DisplayServicesBrightnessChanged` is absent, so change detection uses polling
rather than a notification callback.

## Architecture

Five components. The two that determine whether the product feels good — the
analyzer and the controller — are pure functions with no I/O, so they are fully
testable without a display.

```
SCStream ──▶ ScreenSampler ──▶ LuminanceAnalyzer ──▶ Controller ──▶ BrightnessActuator
   (2 fps, 64×36)              (pure)                 (pure)          (private API)
                                                          ▲
                                                    MenuBarApp
                                              (settings, pause, debug)
```

### 1. ScreenSampler

Owns an `SCStream` over the built-in `SCDisplay`.

- `SCStreamConfiguration`: 64×36, BGRA, `minimumFrameInterval` = 0.5s (2 fps),
  `queueDepth` = 1.
- The compositor performs the downscale on the GPU; per-frame CPU work is ~2300
  pixels, which is negligible.
- Emits `Frame(width, height, pixels: [UInt8])` to the analyzer.
- Responsible for permission state: if Screen Recording is denied, it reports that
  upward so the menu bar can surface an actionable message rather than failing
  silently.
- Restarts the stream on display reconfiguration (resolution change, sleep/wake).

**Interface:** `start()`, `stop()`, `onFrame: (Frame) -> Void`,
`onStatus: (SamplerStatus) -> Void`. Depends on ScreenCaptureKit only.

### 2. LuminanceAnalyzer

Pure function: `analyze(Frame) -> ContentLuminance` (a `Double` in 0...1).

Steps:

1. **sRGB → linear.** Each channel is linearized (`c ≤ 0.04045 ? c/12.92 :
   ((c+0.055)/1.055)^2.4`), then combined with Rec. 709 weights
   (`0.2126 R + 0.7152 G + 0.0722 B`). Averaging gamma-encoded values is the
   common error here and materially misjudges dark content.
2. **Letterbox crop.** Scan inward from each edge, dropping whole rows/columns whose
   pixels are uniformly below linear luminance 0.02. Stop at the first
   non-conforming row/column, and never crop more than 25% from any edge.
   Without this step a letterboxed film's black bars pull the average down and the
   controller *raises* brightness — the opposite of the desired behavior.
3. **Statistic.** `L = 0.6 · p75 + 0.4 · mean` over the cropped region. The 75th
   percentile represents the content the user is actually looking at; the mean
   prevents a small bright region from dominating.

**Depends on:** nothing. Input is a pixel buffer, output is a number.

### 3. Controller

Pure function: `next(state, L, baseline, settings) -> (newState, targetBrightness)`,
called at 2 Hz.

1. **Transient rejection.** Use the median of the last 3 samples (1.5s of history).
   Scrolling past a bright image or a brief flash of a white page must not move the
   backlight.
2. **Offset.** `rawOffset = −strength · (L_median − 0.35)`, clamped to
   `±maxOffset`. `L = 0.35` is the neutral point at which no adjustment is applied;
   `strength` and `maxOffset` come from settings (defaults **0.4** and 0.20).
   The default is chosen so the response is graded rather than saturated: a
   moderately light page (`L ≈ 0.6`) yields about −0.10, while a near-white page
   (`L ≈ 0.95`) reaches the −0.20 clamp. A larger `strength` would push almost all
   light content straight to the clamp, making the app behave like a two-state
   switch.
3. **Deadband.** If `|rawOffset − appliedOffset| < 0.02`, hold the current value.
   This is what stops slow oscillation around a steady scene.
4. **Slew limit.** Move `appliedOffset` toward `rawOffset` by at most 0.10 per
   second, i.e. 0.05 per tick. A full ±0.20 swing therefore takes ~2 seconds and
   reads as ambient rather than as flicker.
5. **Clamp.** `target = clamp(baseline + appliedOffset, 0.05, 1.0)`. The 0.05 floor
   prevents driving the panel to black.

**Depends on:** nothing. All inputs are values.

### 4. BrightnessActuator

Wraps the private APIs behind a protocol so the controller is tested against a fake.

```swift
protocol BrightnessControlling {
    func read() -> Double?
    func write(_ value: Double)
    var canControl: Bool { get }
}
```

Implementation resolves symbols via `dlopen`/`dlsym` at startup:

- Primary: `DisplayServicesGetBrightness` / `DisplayServicesSetBrightness`,
  gated on `DisplayServicesCanChangeBrightness`.
- Fallback: `CoreDisplay_Display_GetUserBrightness` /
  `CoreDisplay_Display_SetUserBrightness`.
- If neither resolves, the app reports "unsupported on this macOS version" in the
  menu bar and does not attempt any adjustment. This is the expected failure mode
  on a future OS release and must degrade cleanly rather than crash.

### 5. MenuBarApp

SwiftUI `MenuBarExtra`, `LSUIElement` (no dock icon).

- Enable/disable toggle
- Strength slider (maps to `strength`, range 0.2–0.8, default 0.4)
- Max offset slider (0.05–0.35)
- Pause for 1 hour
- Launch at login (`SMAppService`)
- Debug panel (collapsed by default): live `L`, applied offset, baseline, target,
  sampler status

Settings persist in `UserDefaults`.

## Baseline Tracking

The offset design depends on knowing the user's intended brightness separately from
what the app has added. Because `DisplayServicesBrightnessChanged` is unavailable,
this is done by polling.

State: `baseline` (user's intended level) and `lastWritten` (what we last set).

Each 2 Hz tick:

1. Read actual brightness.
2. If `|actual − lastWritten| > 0.01`, an external agent changed it — the user
   pressed a brightness key, or the ambient sensor moved the panel. Re-baseline:
   `baseline = actual − appliedOffset`.
3. Otherwise leave `baseline` unchanged.
4. Compute `target` and, if it differs from `lastWritten` by more than 0.002,
   write it and set `lastWritten = target`.

Re-baselining preserves the user's intent exactly: after their adjustment, total
brightness equals what they set, and the content offset continues to ride on top.

Deliberately **not** implemented: a fixed-length lockout after manual adjustment.
A lockout would produce a visible jump when it expires. Re-baselining is both
simpler and smoother. The menu bar's explicit pause covers the case where the user
wants the app to stop entirely (e.g. color-critical work).

## Pause Conditions

The app suspends sampling and adjustment when:

- The display sleeps or the screen is locked
  (`NSWorkspace` / `com.apple.screenIsLocked` distributed notifications)
- No built-in display is present
- The user selects Pause, or disables the app
- Brightness control is unavailable (unsupported OS)

On resume, `baseline` is re-read from the hardware and `appliedOffset` starts at 0,
so the app ramps in from the user's current level rather than snapping.

On quit, brightness is restored to `baseline`.

## Testing

**LuminanceAnalyzer** — synthetic frames:

- Solid white → `L` near 1.0; solid black → near 0.0
- Mid-gray sRGB 128 → linear ≈ 0.216, not 0.5 (guards the gamma bug)
- Letterboxed dark scene: identical content with and without black bars must yield
  `L` within 0.02 of each other (guards the regression that inverts behavior on
  full-screen video)
- A frame that is 90% black with a small white region → `L` stays low

**Controller** — sequences of luminance values against a fake actuator:

- White page (L≈0.95) drives offset to the negative clamp, and no further
- Dark video (L≈0.10) drives offset positive, and no further
- One-tick spike between steady samples produces no change (transient rejection)
- Step change takes ≥ 1.8s to complete (slew limit)
- Steady input inside the deadband produces zero writes
- `baseline + offset` never leaves `[0.05, 1.0]`
- External brightness change re-baselines such that total equals the observed value

**BrightnessActuator** — one integration test, skipped in CI: read, write ±0.05,
verify the read-back, restore. Marked as requiring a real display.

## Build and Distribution

Swift Package with an executable target, plus a `make-bundle.sh` that assembles
`AutoBrightness.app` (Info.plist with `LSUIElement`, `NSScreenCaptureUsageDescription`)
and ad-hoc signs it.

**Known consequence:** macOS ties Screen Recording permission to the code signature,
so rebuilding may re-trigger the permission prompt. If that becomes tiresome, an
Xcode project signed with a free personal development certificate gives a stable
identity. Starting with the SPM path keeps the toolchain simple; switching later is
a contained change.

## Non-Goals

- External monitor control via DDC/CI
- Software dimming below the panel's hardware minimum
- Per-app or per-window brightness profiles
- Mac App Store distribution
- Any network activity. Screen samples never leave the machine and are never
  written to disk.

## Risks

| Risk | Mitigation |
|---|---|
| Private API removed in a future macOS | Actuator degrades to a clear "unsupported" state; two independent API paths tried |
| Adjustment feels intrusive | Conservative defaults, deadband, slew limit, user-tunable strength, one-click pause |
| Fights macOS ambient auto-brightness | Re-baselining treats ALS movement as user intent rather than as error |
| Screen Recording permission friction | Surfaced explicitly in the menu bar with a link to System Settings |
