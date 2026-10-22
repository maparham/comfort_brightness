# External Displays — Design

Date: 2026-10-22
Status: draft (revised after review)

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
  moves to the new level), not fought, whether or not the app is adjusting
  at that moment. Typically within about a second; at most
  `refreshInterval` plus `settleWindow` plus one tick.
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
whether read-back reflects a write at once) is measured in the first
implementation task, with the pass/fail criteria under Testing, before
anything depends on it.

## Architecture

```
AppModel                      global state: enabled, manual pause, system sleep, tuning
 └─ DisplayManager            reconciles units with the active display set
     ├─ DisplayUnit [built-in]  ScreenSampler(id) → Coordinator → RampingBrightness(20 × 1/60 s) → DisplayServicesBrightness(id)
     └─ DisplayUnit [P24h-30]   ScreenSampler(id) → Coordinator → RampingBrightness(4 × 0.1 s)   → DDCBrightness(transport)
```

`Controller`, `LuminanceAnalyzer`, `Letterbox` and `BrightnessRamp` are
unchanged. `Coordinator` changes in exactly one way: its external-change
threshold comes from the backend (see "Read-back contract"). Everything else
DDC-specific is kept below the `BrightnessControlling` protocol, so the
coordinator keeps the read-back semantics it was tuned for.

### DisplayManager (App)

Owns a dictionary of `DisplayUnit`s keyed by `CGDirectDisplayID`. macOS
derives this ID from the display's vendor, model and serial, so it is usually
stable across a reconnect of the same monitor. This has not been verified
for a monitor whose serial is 0, or after moving it to another port. If the
ID does change, the unit is torn down and recreated and its learned state is
lost. That is accepted.

Reconciles on launch and on every
`NSApplication.didChangeScreenParametersNotification`:

1. List active displays (`CGGetActiveDisplayList`).
2. For each display that has gone away: stop its unit's sampler, call
   `restoreBaseline()` (the write is skipped if the backend can no longer
   control the display), flush its ramp, call the backend's `invalidate()`,
   and drop the unit. `invalidate()` stops the DDC refresh timer, empties the
   DDC queue, and clears `onControlChange`, so nothing calls back into a
   dropped unit.
3. For each new display: resolve a backend (below). The unit is created with
   that backend, or as *not adjustable* with a reason.
4. Displays already present keep their unit and its learned state. The unit's
   sampler restarts itself on reconfiguration, as it does today. For a DDC
   unit, the `IOAVService` is re-matched and handed to the existing backend
   with `replaceTransport(_:)`, because DCP services can be recreated across
   sleep, wake and reconfiguration, and an old handle is dead. A DDC unit
   whose backend is not responding is also re-matched on system wake
   (`PauseMonitor`'s resume).

Each reconcile pass takes a new generation number. A DDC probe started by an
earlier pass, or for a display that has since gone, finishes without creating
or changing a unit.

A display left *not adjustable* because it "didn't respond to DDC" is
re-probed with backoff (5 s, 10 s, 20 s, then every 60 s) and on system wake.
A monitor that is still waking up at login is therefore picked up without
waiting for a reconfiguration. The other not-adjustable reasons are
structural and wait for the next reconfiguration.

Backend resolution, in order:

1. **DisplayServices**, if the symbols resolve and
   `DisplayServicesCanChangeBrightness(id)` is non-zero. Covers the built-in
   panel and Apple externals.
2. **DDC**, if the display is not built-in, an `IOAVService` matches it (see
   matching), and one brightness read succeeds. The read happens on the DDC
   queue; until it returns, the unit shows "Checking…" and is not started.
   The probe's reply seeds the backend's state, so the coordinator's first
   `read()` already returns the real level rather than nil.
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
coordinator: sample only while wanted, controllable and responding, and run
the coordinator only while wanted, responding, and its sampler is `.running`.
For DisplayServices backends, "responding" is always true.

Everything `AppModel` currently sends to its single coordinator goes to every
unit instead, including units created later: `isEnabled`, the three tuning
settings (each `didSet` fans out, and a new unit starts from the current
values), `retrySampling` (every sampler retries), and restore on termination.

### ScreenSampler (App)

Takes a `CGDirectDisplayID` and captures the `SCDisplay` with that ID instead
of searching for the built-in one. If ScreenCaptureKit does not offer that
display, the status is `.noDisplay`. Permission handling, the watchdog and
restart logic are unchanged. Screen Recording permission stays one grant for
all displays.

### DisplayServicesBrightness (App)

Bound to exactly one display ID for its whole life. The current getter falls
back to `builtinDisplayID()` whenever its cached ID is not built-in
(`DisplayServicesBrightness.swift:49-55`). Under this design that fallback
would make a Studio Display's unit drive the built-in panel, with two
coordinators fighting over it, so it is removed. While its display is not
active, `canControl` is false and reads return nil. Symbol resolution, the
`CanChangeBrightness` gate and the CoreDisplay fallback are unchanged, and the
fallback stays restricted to displays where `CanChangeBrightness` did not say
no. A different built-in ID after a lid cycle simply produces a new unit.

### DDCBrightness (Core)

Implements `BrightnessControlling` over a transport protocol:

```swift
public protocol DDCTransport: AnyObject, Sendable {
    /// Blocking. Current and maximum of VCP 0x10, or nil on any failure.
    func readBrightness() -> (current: Int, maximum: Int)?
    /// Blocking. True when the monitor acknowledged the write.
    func writeBrightness(_ value: Int) -> Bool
}
```

The real transport (`IOAVServiceTransport`, App) wraps one `IOAVService`
handle. `replaceTransport(_:)` swaps it when the manager re-matches.

#### Who owns what

`DDCBrightness` is `@unchecked Sendable`. Its state is split by owner, and
nothing is touched from the other side:

- **Main thread:** `requested` (the last value `write` was given),
  `observation` (the latest *external* reading posted by the queue, tagged
  with the generation of the request it was compared against), `canControl`,
  `isResponding`, and the request generation counter. `read()`, `write()`,
  `canControl`, `isResponding` and the closures run here.
- **DDC queue:** `lastKnownInt` (the monitor's level as last *established*,
  either by an acknowledged send or by a read), `maximum`, `pendingInt` (the
  one coalesced write not yet sent), the time of the last acknowledged send,
  the time of the last read, and the consecutive-failure count.

The queue posts results to main with `DispatchQueue.main.async`. It never
uses `DispatchQueue.main.sync`, so `flush()` (a `sync` from main onto the
queue) cannot deadlock. Time comes from an injected `Clock` and queue work from
an injected executor, so tests run everything inline and can advance time.

#### Writing

`write(v)` sets `requested = v`, increments the request generation, clears
`observation`, and enqueues `target = round(v × maximum)`. On the queue:

- If `target == lastKnownInt` and nothing is pending, nothing is sent. The
  comparison is with the monitor's last *known* level, not the last value
  sent, so a level established by a read is never mistaken for one already
  written.
- Otherwise `pendingInt = target`, replacing any value still waiting. Only
  one write is ever outstanding.
- The sender sends `pendingInt`, then waits `ddcSpacing` (50 ms) before the
  queue issues anything else. On acknowledgement, `lastKnownInt = pendingInt`
  and `pendingInt` is cleared. On failure, `lastKnownInt` is left alone,
  `pendingInt` is kept and retried after the spacing, and the failure counts
  toward the limit below. A write that never lands is therefore never
  reported as having moved the monitor.

#### Reading

A refresh read is due every `refreshInterval` (1 s). It is never skipped
because of writes. That was the flaw in the previous draft: while content was
changing, every read was thrown away and a button press was overwritten by
the next absolute write. Instead:

- **Quiet barrier.** When a read is due and the last acknowledged send was
  less than `settleWindow` ago, the queue holds back further sends until the
  window has passed. Writes requested meanwhile coalesce into `pendingInt`.
  It then reads before it sends anything. During active adjustment this
  pauses the glide for at most `settleWindow` plus one read (about 0.4 s)
  once per second. The coordinator is not affected: it only sees `requested`.
- **Comparing.** A reply equal to `lastKnownInt` means nothing changed. A
  different reply is an external change: `lastKnownInt = reply`,
  `pendingInt` is dropped (it was computed before the user acted and would
  overwrite them), and the reply is posted to main as an observation.
- On main, an observation is applied only if its generation is still the
  current request generation. Otherwise a newer `write` has already
  superseded it, and since the dropped pending write never reached the
  monitor, the next refresh will see the user's level again.

`settleWindow` starts at 300 ms. It becomes a named constant set from the
measurement in the first implementation task.

#### `read()`

- Before the probe has seeded it: nil.
- With no observation: `requested` (or, before any write, the probe's level
  `current / maximum`).
- With an observation `obs` for the current generation:
  `requested + (obs − round(requested × maximum)) / maximum`. An external
  change is therefore reported as a whole number of the monitor's steps away
  from what was asked for. It never carries the rounding of the request
  itself, so a one-step press always reads as exactly one step.

#### Failure, recovery and writability

- **`isResponding`** goes false after 5 consecutive transport failures
  (reads or writes) and true again on the next successful read. Refresh
  reads continue at the same cadence while it is false. Transitions are
  reported through `onControlChange` (a `@MainActor` closure), and the unit
  suspends or resumes its coordinator on them.
- **`canControl`** goes false only for reasons that persist: transport
  invalidated, maximum 0, or the monitor is found not to accept writes (next
  item). A transient dropout leaves `canControl` true. That is what lets
  `Coordinator.restoreBaseline()` queue its restore write while the monitor
  is asleep (`Coordinator.swift:404` skips the write when `canControl` is
  false). The restore stays as `pendingInt`, and on recovery it is sent
  *before* the first read is reported. When the coordinator resumes, it reads
  back the restored baseline rather than a level that still carries the old
  offset.
- **Writability check.** If 3 acknowledged sends in a row are each followed
  by a read showing the level from before that send, the monitor is
  acknowledging writes without applying them. `canControl` becomes false
  with the reason "Doesn't accept brightness changes", and it stays that way
  until the next reconfiguration.
- **`maximum`** comes from every successful read and is never assumed to be
  100. A reply with maximum 0 is a failure.

#### Lifecycle

- **`flush()`** runs `sync` on the queue with a 0.5 s timeout. It sends
  `pendingInt` if there is one, ignoring the quiet barrier. Termination only.
- **`invalidate()`** stops the refresh timer, drops pending work, clears the
  closures, and makes `canControl` false. It is called when a unit is
  dropped.
- The refresh timer runs on the DDC queue (a `DispatchSourceTimer`), not on
  the main run loop, so menu tracking cannot stall it.

`DDCBrightness` lives in Core so it can be tested against a fake transport,
a fake clock and an inline executor.

### Read-back contract

`Coordinator` treats `read() − lastWritten` as external movement. It ignores
movement below an external-change threshold, skips writes below 0.002, and
runs a bias probe that assumes read-back is exact. On DDC:

- **Own writes read back exactly.** `read()` returns `requested` until there
  is an observation, so the rounding of the request never appears as drift
  and the bias probe is never triggered.
- **External changes read back as whole steps** (see `read()` above), never
  as fractions.
- **The threshold comes from the backend.** `BrightnessControlling` gains
  `var externalChangeThreshold: Double { get }`. A protocol extension
  defaults it to 0.01, which keeps DisplayServices and `FakeBrightness`
  exactly as they are today. `DDCBrightness` returns half a step,
  `0.5 / maximum` (0.005 on the P24h-30). `RampingBrightness` forwards it.
  `Coordinator` uses `brightness.externalChangeThreshold` in place of the
  static `externalChangeThreshold`. This is the only `Coordinator` change.

Under the old 0.01 threshold, a one-step press was followed or missed
depending on rounding. A press reading −0.007 sat below the threshold
indefinitely, because with no writes later ticks measure zero movement
(`Coordinator.swift:167-170`). The next content-driven write then undid it.
With whole-step reporting and a half-step threshold, every press of one step
or more is followed on the tick after the refresh that sees it. A monitor
whose maximum is above 100 is covered by the same rule.

`deliberateChangeThreshold` (0.03) and `minimumWriteDelta` (0.002) are left
alone. One or two button steps move the baseline without re-teaching the
neutral, and three or more re-teach it, as a brightness-key press does on the
built-in panel.

### RampingBrightness for DDC

Same decorator, constructed with `stepCount: 4, stepInterval: 0.1`. That is
400 ms, inside the existing `< 0.5 s` precondition. Coalescing in
`DDCBrightness` absorbs any step the monitor can't keep up with: the last step
is always the target, and the newest value always wins.

### Matching an IOAVService to a display (App, pure part in Core)

1. For each active non-built-in display, read `IODisplayLocation` from
   `CoreDisplay_DisplayCreateInfoDictionary`. Split the path on `/` and take
   the component just before the last one (here `dispext0@70000000`). Its
   framebuffer node name is the part before `@` (`dispext0`). The last
   component itself is not inspected: `AppleCLCD2` is what this machine
   shows, and other names are possible.
2. For each `DCPAVServiceProxy` with `Location == "External"`, split its
   service-plane path on `/` and find the components that start with
   `<node>:` and contain `dcpav-service`.
3. A display matches a service when exactly one service carries its node name.
   Zero matches means "No DDC connection". More than one, or a node claimed by
   two displays, means "Can't tell which connection is this display", and that
   display is not driven.

Steps 1–3 work purely on strings, without regular expressions, in a Core
function (`AVServiceMatcher`). It is tested on the real paths recorded above
and on a synthetic two-monitor set (`dispext0` and `dispext1`, as a dock with
two outputs would produce). The IORegistry walk and the CoreDisplay call stay
in App.

If `CoreDisplay_DisplayCreateInfoDictionary` or any `IOAVService` symbol is
missing, DDC is unavailable for every display, and the app keeps running on
DisplayServices alone.

## UI

- The popover's single brightness row becomes one row per display: name, a
  percentage (or "Not adjustable — <reason>" / "Checking…" / "Not
  responding"), and that unit's sampler status where it is not `.running`.
  The "Pause for 1 hour" control stays a single global control below the
  rows.
- "Screen Recording permission is required." is shown once, not per display.
- The "unavailable on this system" warning is replaced by "No adjustable
  displays", shown only when there are zero adjustable units.
- The `.noDisplay` message no longer mentions the built-in panel.
- The menu bar percentage shows the display that holds the menu bar
  (`CGMainDisplayID()`). It falls back to the first adjustable display, and
  then to the glyph alone.
- The "Details" group shows luminance, offset and baseline per display.

## Termination

`restoreBaselineOnce()` runs `coordinator.restoreBaseline()` and then the
ramp's `flush()` for every unit. It then calls `DDCBrightness.flush()` for
all DDC units at once, waiting on them as a group. Total worst case is one
0.5 s timeout, whatever the number of DDC displays.

## Error handling summary

| Situation | Behaviour |
|---|---|
| DDC symbols missing (future macOS) | DDC off for all displays; DisplayServices displays unaffected |
| Monitor doesn't answer the probe read | "Didn't respond to DDC"; re-probed with backoff and on wake |
| Monitor stops answering mid-session (asleep, DDC switched off) | `isResponding` false after 5 failures; coordinator suspends, restore queued as pending; on recovery the restore is sent first, then the coordinator resumes |
| Write acknowledged but not applied, 3 times in a row | `canControl` false, "Doesn't accept brightness changes", until reconfiguration |
| Stale IOAVService handle after sleep/reconfiguration | Re-matched on reconfiguration, and on wake while not responding; `replaceTransport` |
| Ambiguous match | Not driven, with reason |
| Display unplugged mid-ramp | Unit's sampler stopped, restore skipped (no control), backend invalidated, unit dropped |
| Lid opened/closed | Built-in unit added/removed by reconciliation; externals untouched |
| `CGDirectDisplayID` changes for the same monitor | Treated as a new display; learned state lost |

## Testing

Core, via `swift test`, using a fake transport, a fake clock and an inline
executor:

- `DDCBrightness`:
  - Own writes read back exactly, and the rounding of a request never
    appears.
  - A one-step external change reads as exactly one step from `requested`,
    in both directions, from requests that round up and that round down.
  - A maximum other than 100 scales correctly, and maximum 0 is a failure.
  - Coalescing: only the newest pending value is sent. A target equal to
    `lastKnownInt` is not sent, including when `lastKnownInt` was set by a
    read rather than a send.
  - A failed write leaves `lastKnownInt` unchanged, is retried, and is never
    reported as movement.
  - Quiet barrier: with a write requested every 100 ms, a read still runs at
    least once per `refreshInterval`, and only after `settleWindow` without a
    send.
  - An external change drops the pending write. An observation from a
    superseded generation is ignored.
  - 5 failures make `isResponding` false and one good read restores it. A
    restore requested while not responding is sent before the first read on
    recovery.
  - 3 acknowledged-but-unapplied writes make `canControl` false.
  - `invalidate()` stops callbacks. `flush()` sends pending work, ignoring
    the barrier, and respects its timeout.
- `Coordinator` + `RampingBrightness(4 × 0.1)` + `DDCBrightness`, driven tick
  by tick:
  - Steady content sends nothing after settling.
  - During continuous content-driven writes, a 1-step and a 5-step press on
    the fake monitor are each followed and never overwritten. The 5-step press
    re-neutralises; the 1-step press moves the baseline only.
  - In steady state, a one-step press from a request that rounded down
    (0.497 → monitor 50 → user 49) is followed, which was the reviewer's
    failing case.
  - A dropout followed by recovery leaves the baseline where the user had
    it, not where the offset left the monitor.
- `Coordinator` with `FakeBrightness`: every existing test passes unchanged,
  which confirms the 0.01 default.
- `AVServiceMatcher`: the real paths match; the synthetic two-monitor set
  matches each display to its own service; zero, duplicate and cross-claimed
  nodes give the right outcome.

App, first implementation task: before anything is built on it, measure DDC
writes on the P24h-30. Write a level, then read it back at 0, 50, 100, 200,
300 and 500 ms; repeat at 10 different levels; and record the shortest
spacing between writes that the monitor still honours.
- **Pass:** every write is acknowledged, and read-back matches within
  500 ms. `settleWindow` is set to the largest observed delay plus 100 ms,
  and `ddcSpacing` to the measured minimum, but no less than 50 ms.
- **Fail:** if read-back never matches, the monitor ignores DDC writes over
  this connection. Stop and report before building further.

App, manual, on the development machine (recorded in the plan's final
task):

- Lid closed, P24h-30 only: adjusts, no warning.
- Lid open: both adjust independently, and the menu bar shows the main
  display.
- Monitor buttons are followed, including during a playing video.
- Quit returns both displays to their baselines.
- Unplugging and replugging the monitor while running recovers without a
  relaunch.
- Display sleep and wake: the monitor comes back at its baseline.

## Documentation

- README: replace "controls only the built-in display" with the supported
  set and the limitations listed under Non-Goals.
- Original design spec: add a note under its Non-Goals that DDC/CI is now
  covered by this spec.
