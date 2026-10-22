# External Displays — Design

Date: 2026-10-22
Status: draft

## Problem

The app adjusts only the built-in panel. With the lid closed and an external
monitor as the only display, it reports "Brightness control is unavailable on
this system" and does nothing. With the lid open, the external is ignored.

The original design listed "External monitor control via DDC/CI" as a
non-goal. This spec reverses that.

## Goal

Every active display whose brightness can be driven is adjusted
independently, each from its own content:

- the built-in panel, as today;
- Apple external displays (Studio Display, Pro Display XDR, LG UltraFine), via
  the same DisplayServices path as the built-in panel;
- third-party monitors via DDC/CI over `IOAVService` (Apple Silicon only).

A display that can be driven by neither path is listed as not adjustable and
does not stop the others from working.

Success, measured on the development machine (M2, Lenovo P24h-30 over its
current connection):

- Lid closed, P24h-30 only: the P24h-30's brightness follows its content, and
  the warning is gone.
- Lid open, both displays: each follows its own content; dark content on one
  does not move the other.
- Pressing the P24h-30's own brightness buttons is followed (the baseline
  moves to the new level) within about a second, not fought.
- Quitting returns each display to its baseline.

## Non-Goals

- Intel Macs. `IOAVService` is Apple Silicon only; the Intel I²C path is a
  different API and is not built.
- DisplayLink, AirPlay and Sidecar displays. None exposes either path; they
  show as not adjustable.
- Mirrored display sets. A display ScreenCaptureKit does not offer for capture
  sits idle.
- Per-display tuning. Strength, maximum change and time to adjust stay global.
- Persisting anything per display.

## Measured facts this design rests on

Probed read-only on the development machine before writing this spec:

- `IOAVServiceCreateWithService`, `IOAVServiceReadI2C` and
  `IOAVServiceWriteI2C` resolve from IOKit.
- A DDC "get VCP 0x10" (brightness) to the P24h-30 succeeded 20 of 20 times,
  averaging ~71 ms per round trip including the 50 ms wait DDC requires
  between request and reply. Reported current 100, maximum 100.
- `DisplayServicesCanChangeBrightness` returns 0 for the P24h-30.
- The P24h-30's EDID serial number is 0, so vendor/product/serial cannot
  distinguish two identical monitors.
- `CoreDisplay_DisplayCreateInfoDictionary(id)["IODisplayLocation"]` for the
  P24h-30 is `…/dispext0@70000000/AppleCLCD2`, and its `DCPAVServiceProxy`
  registry path contains `…/dispext0:dcpav-service-epic:0/DCPAVServiceProxy`.
  The framebuffer node name (`dispext0`) links the two.

No DDC *write* has been made yet. Write behaviour (latency, minimum spacing,
whether read-back reflects a write at once) is verified in the first
implementation task, before anything depends on it.

## Architecture

```
AppModel                      global state: enabled, manual pause, system sleep, tuning
 └─ DisplayManager            reconciles units with the active display set
     ├─ DisplayUnit [built-in]  ScreenSampler(id) → Coordinator → RampingBrightness(20 × 1/60 s) → DisplayServicesBrightness(id)
     └─ DisplayUnit [P24h-30]   ScreenSampler(id) → Coordinator → RampingBrightness(4 × 0.1 s)   → DDCBrightness(transport)
```

`Coordinator`, `Controller`, `LuminanceAnalyzer`, `Letterbox` and
`BrightnessRamp` are unchanged. All DDC-specific behaviour is kept below the
`BrightnessControlling` protocol, so the coordinator keeps the read-back
semantics it was tuned for (see "Read-back contract").

### DisplayManager (App)

Owns a dictionary of `DisplayUnit`s keyed by `CGDirectDisplayID`. macOS
derives this ID from the display's vendor, model and serial, so it is stable
across a reconnect of the same monitor on the same port.

Reconciles on launch and on every
`NSApplication.didChangeScreenParametersNotification`:

1. List active displays (`CGGetActiveDisplayList`).
2. For each display that has gone away: stop its unit's sampler, call
   `restoreBaseline()` (the write is skipped if the backend can no longer
   control the display), flush its ramp, and drop it.
3. For each new display: resolve a backend (below). The unit is created with
   that backend, or as *not adjustable* with a reason.
4. Displays already present keep their unit and its learned state. The unit's
   sampler restarts itself on reconfiguration, as it does today.

Backend resolution, in order:

1. **DisplayServices**, if the symbols resolve and
   `DisplayServicesCanChangeBrightness(id)` is non-zero. Covers the built-in
   panel and Apple externals.
2. **DDC**, if the display is not built-in, an `IOAVService` matches it (see
   matching), and one brightness read succeeds. The read happens on the DDC
   queue; until it returns, the unit shows "Checking…" and is not started.
3. Otherwise **not adjustable**, with one of: "No DDC connection",
   "Can't tell which connection is this display", "Didn't respond to DDC".

Power-source changes (`PowerSourceMonitor`) are forwarded only to the built-in
unit. They exist to recognise the OS's on-battery dim, which never touches an
external.

### DisplayUnit (App)

One display's pipeline: a `ScreenSampler`, a `Coordinator`, a
`RampingBrightness` over the resolved backend, and the readout the UI shows
(name, brightness, sampler status, adjustable or not and why).

`AppModel.applyRunState()` keeps its role as the single decision point. It
computes `userWantsIt` as today and hands it to every unit. Each unit then
applies the same rules `applyRunState` applies now, to its own sampler and
coordinator: sample only while wanted and controllable, and run the
coordinator only while wanted and its sampler is `.running`.

### ScreenSampler (App)

Takes a `CGDirectDisplayID` and captures the `SCDisplay` with that ID instead
of searching for the built-in one. If ScreenCaptureKit does not offer that
display, the status is `.noDisplay`. Permission handling, the watchdog and
restart logic are unchanged. Screen Recording permission stays one grant for
all displays.

### DisplayServicesBrightness (App)

Takes a display ID instead of searching for the built-in panel. The
re-resolution logic, its `CanChangeBrightness` gate and the CoreDisplay
fallback are unchanged. The fallback stays restricted to displays where
`CanChangeBrightness` did not say no.

### DDCBrightness (Core)

Implements `BrightnessControlling` over a transport protocol:

```swift
public protocol DDCTransport: AnyObject {
    /// Blocking. Current and maximum of VCP 0x10, or nil on any failure.
    func readBrightness() -> (current: Int, maximum: Int)?
    /// Blocking. True when the write was accepted.
    func writeBrightness(_ value: Int) -> Bool
}
```

All transport calls run on one serial `DispatchQueue` owned by the backend.
The main thread never waits on DDC, except in `flush()`.

- **`read()`** returns a cached value immediately (see "Read-back contract").
- **`write(v)`** records `v` as the requested level, updates the cache, and
  schedules a transport write of `round(v × maximum)`. Writes coalesce: if one
  is already queued, its value is replaced instead of a second being queued.
  The write is skipped if the integer equals the last integer sent. After each
  transport write the queue waits 50 ms (DDC's required spacing) before
  issuing anything else.
- **Refresh:** a repeating 1 s timer queues a transport read. A read result is
  discarded if any write was requested after the read was queued, or within
  300 ms after the last transport write completed. That covers monitors that
  briefly report the old level. Otherwise it updates the cache on the main
  queue. Consequence, accepted: while the app is actively adjusting this
  display, refreshes keep being discarded, so a button press on the monitor
  is only noticed after the adjustment settles. A press usually comes after
  the scene changes, so this costs about a second at most.
- **`canControl`** is true until 5 consecutive transport failures (reads or
  writes). After that it is false until the next successful refresh read,
  which keeps being attempted at the same 1 s cadence. Asleep or unplugged
  monitors therefore stop being driven and recover by themselves. Every
  change of `canControl` is reported through an `onControlChange` closure.
  The owning `DisplayUnit` re-applies its run state on it, because a unit
  whose sampler was stopped for lack of control has nothing else that would
  restart it.
- **`maximum`** comes from each read reply and is never assumed to be 100. A
  reply with maximum 0 counts as a failure.
- **`flush()`** waits synchronously, with a 0.5 s timeout, for queued writes to
  reach the monitor. It is used only on the termination path.

`DDCBrightness` lives in Core so it can be tested against a fake transport. A
queue abstraction lets tests execute queued work inline and advance the
refresh timer by hand.

### Read-back contract

`Coordinator` treats `read() − lastWritten` as external movement, with a
0.01 threshold, a 0.002 minimum write and a bias probe that assumes read-back
is exact. A DDC monitor only stores whole steps (1/100 here), so a raw
read-back carries up to ±half a step of rounding. Summed over ticks, that
would look like a slow external drift.

`DDCBrightness.read()` therefore reports the **requested** level whenever the
monitor's integer equals `round(requested × maximum)`, and reports
`current / maximum` only when they differ. To the coordinator, its own writes
read back exactly, as on DisplayServices, and any change made with the
monitor's buttons appears as real movement. A one-step button press shows up
as at most 0.01 and accumulates across ticks under the existing logic. Moves of
two steps or more are seen on the next refresh. No coordinator constant
changes.

Before the first read completes, `read()` returns nil, and the coordinator
already handles that.

### RampingBrightness for DDC

Same decorator, constructed with `stepCount: 4, stepInterval: 0.1`. That is
400 ms, inside the existing `< 0.5 s` precondition. Coalescing in
`DDCBrightness` absorbs any step the monitor can't keep up with: the last step
is always the target, and the newest value always wins.

### Matching an IOAVService to a display (App, pure part in Core)

1. For each active non-built-in display, read `IODisplayLocation` from
   `CoreDisplay_DisplayCreateInfoDictionary`. Take its framebuffer node name:
   the path component before `/AppleCLCD2` or `/IOMobileFramebufferShim`, up
   to the `@` (for example `dispext0`).
2. For each `DCPAVServiceProxy` with `Location == "External"`, read its
   service-plane path and find the component that starts with
   `<node>:dcpav-service`.
3. A display matches a service when exactly one service carries its node name.
   Zero matches means "No DDC connection". More than one, or a node claimed by
   two displays, means "Can't tell which connection is this display", and that
   display is not driven.

Step 3's string logic is a pure function in Core (`AVServiceMatcher`), tested
on real and synthetic paths. The IORegistry walk and the CoreDisplay call stay
in App.

If `CoreDisplay_DisplayCreateInfoDictionary` or any `IOAVService` symbol is
missing, DDC is unavailable for every display, and the app keeps running on
DisplayServices alone.

## UI

- The popover's single brightness row becomes one row per display: name, a
  percentage (or "Not adjustable — <reason>" / "Checking…"), and that unit's
  sampler status where it is not `.running`. The "Pause for 1 hour" control
  stays a single global control below the rows.
- "Screen Recording permission is required." is shown once, not per display.
- The "unavailable on this system" warning is replaced by "No adjustable
  displays", shown only when there are zero adjustable units.
- The `.noDisplay` message no longer mentions the built-in panel.
- The menu bar percentage shows the display that holds the menu bar
  (`CGMainDisplayID()`). It falls back to the first adjustable display, and
  then to the glyph alone.
- The "Details" group shows luminance, offset and baseline per display.

## Termination

`restoreBaselineOnce()` restores and flushes every unit:
`coordinator.restoreBaseline()`, then the ramp's `flush()`, then for DDC
`DDCBrightness.flush()`. Total worst case is bounded by one 0.5 s timeout per
DDC display.

## Error handling summary

| Situation | Behaviour |
|---|---|
| DDC symbols missing (future macOS) | DDC off for all displays; DisplayServices displays unaffected |
| Monitor doesn't answer the probe read | "Didn't respond to DDC"; re-probed on the next display reconfiguration |
| Monitor stops answering mid-session (asleep, DDC switched off) | `canControl` false after 5 failures; unit's coordinator suspends; recovers on a successful read |
| Ambiguous match | Not driven, with reason |
| Display unplugged mid-ramp | Unit's sampler stopped, restore skipped (no control), unit dropped |
| Lid opened/closed | Built-in unit added/removed by reconciliation; externals untouched |

## Testing

Core, via `swift test`:

- `DDCBrightness` against a fake transport: own writes read back exactly;
  integer rounding is invisible; a different integer reads as movement;
  coalescing keeps only the newest value; equal integers are not re-sent; a
  read queued before a write is discarded; a read inside the 300 ms settle
  window is discarded; 5 failures drop `canControl` and one good read
  restores it; a maximum other than 100 scales correctly; maximum 0 is a
  failure.
- `Coordinator` + `RampingBrightness(4 × 0.1)` + `DDCBrightness` with a fake
  transport: steady content writes nothing to the transport after settling;
  a 5-step change on the fake monitor's "buttons" is followed and
  re-neutralises; a 1-step change is eventually followed and is never fought.
- `AVServiceMatcher`: the real paths recorded above match; zero, duplicate
  and cross-claimed nodes yield the right outcome.
- Existing tests unchanged and passing.

App, manual, on the development machine (recorded in the plan's final
task):

- Lid closed, P24h-30 only: adjusts, no warning.
- Lid open: both adjust independently, and the menu bar shows the main
  display.
- Monitor buttons are followed.
- Quit returns both displays to their baselines.
- Unplugging and replugging the monitor while running recovers without a
  relaunch.

## Documentation

- README: replace "controls only the built-in display" with the supported
  set and the limitations listed under Non-Goals.
- Original design spec: add a note under its Non-Goals that DDC/CI is now
  covered by this spec.
