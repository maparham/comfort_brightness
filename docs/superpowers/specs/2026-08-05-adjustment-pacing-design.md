# Adjustment pacing slider

## The problem

Switching between windows can change the screen's luminance sharply, and the
brightness follows sharply enough to be distracting. Two separate things make
that happen, and a user who wants it calmed down wants both:

- The offset slews at a fixed 0.05 per tick, so a full ±20% adjustment lands in
  two seconds whether or not the content is going to stay.
- The median is taken over three samples, so content that holds for one second
  is already believed.

## The setting

One control, in seconds: **"Time to adjust"**, range 1–8, default 2. The label
has to fit a 300 pt popover on one line beside "Sensitivity to screen content"
and "Maximum change", which rules out a phrase that reads as an unfinished
sentence when the value is pushed off the end.
The default reproduces the shipped behaviour exactly, so nothing changes for an
existing user until they move it.

`ControllerSettings` stores `responseSeconds` and derives both knobs from it:

| Derived | At 2 s (default) | At 8 s |
|---|---|---|
| `slewPerTick` = `maxOffset / (seconds × 2 Hz)` | 0.05 | 0.0125 |
| `historyLength` = `round(seconds × 1.5)`, clamped 3…12 | 3 | 12 |

Deriving rather than storing keeps the two from drifting apart, and keeps the
mapping in the core where the tests can see it rather than in the view model.

Sizing the slew to `maxOffset` means the setting is *how long an adjustment
takes*, not *how fast the panel moves*: lowering "Maximum change" now takes
smaller steps over the same duration rather than arriving sooner. `seconds` is
floored at 0.5 in the derivations, so a zero or negative value decoded from an
older build or a hand-edited preference cannot divide by zero and freeze the
offset.

The history floor of 3 preserves the existing rejection of a one-tick spike even
at the shortest setting.

## What is deliberately not touched

`RampingBrightness` is the obvious place to look for "slow it down" and is the
wrong one. Its glide carries a `precondition` that a ramp finish inside one 2 Hz
tick, because the `Coordinator` reads the panel back each tick and attributes any
shortfall from its own last write to the user. A longer glide there would make
the app read its own writes as someone reaching for the brightness key.

## Consequences

The deadband (0.02, absolute) ends the approach one step early whenever the step
is small, so at 8 s the offset settles about 0.0125 short of the clamp instead of
exactly on it. That is a hair over 1% of panel brightness, it is the deadband
doing the job it exists for, and it already happened at a low "Maximum change"
before this change. Tests assert settling to within a deadband of the clamp
rather than exactly on it.

The least motion the two sliders can be asked for together — a 0.05 clamp at 8
seconds — is a step of 0.003125, against the `Coordinator`'s 0.002 minimum write.
That is only 1.5× clear, so a test pins the corner: widening the response range
or lowering the clamp range past that point would have every write suppressed and
the feature would silently stop working rather than fail loudly.

Coupling `historyLength` to the slider also lengthens what `reneutralize()`
learns from: at 8 seconds the neutral it adopts is the median of about six
seconds of content rather than one and a half. A brightness key pressed just
after switching windows can therefore learn a neutral partly drawn from the
previous window. That is the cost of driving both behaviours from one number,
and it is bounded by the same slider the user chose to move.

`ControllerSettings` renames a stored property, and it is `Codable`, but nothing
in the app or the tests ever encodes it — the settings are persisted as
individual `UserDefaults` keys. The conformance is vestigial, so the rename
cannot break a stored blob.

## Changes

- `ControllerSettings`: `slewPerTick` stored → `responseSeconds` stored, with
  `slewPerTick` and `historyLength` computed; `tickRate` constant.
- `Controller`: reads `settings.historyLength`; trims history in a loop so
  shortening the setting takes effect on the next tick rather than decaying one
  stale sample at a time.
- `AppModel`: `responseSeconds` in the same shape as `strength`/`maxOffset` —
  `didSet` to coordinator and `UserDefaults`, registered default, a
  `responseSecondsRange`, clamped on read.
- `SettingsView`: slider below "Maximum change".
- `ResponseSecondsTests`: defaults still yield 0.05 and 3 samples; a longer
  setting takes proportionally longer for the same adjustment; duration is
  independent of the clamp; at 8 s a two-second window flick moves nothing while
  content that stays still gets adjusted; shortening trims immediately; a
  nonsense stored value cannot freeze the offset.
- `ControllerTests.loweredClampSlewsBack`: expected value follows the
  clamp-sized slew.
- README: the "roughly 2 seconds" claim and the settings list.
