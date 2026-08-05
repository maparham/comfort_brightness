# Smooth Brightness Ramp — Design

Date: 2026-08-05
Status: approved

## Problem

The control loop ticks at 2 Hz and performs one hardware write per tick, moving
by up to `slewPerTick` (0.05). Each write lands instantly, so brightness moves
in visible ~5% pops every 500 ms.

## Goal

Make each adjustment perceptually continuous without touching the control law
or the `Coordinator`'s read-back/probe logic.

## Approach

Insert a decorator, `RampingBrightness`, between `Coordinator` and
`DisplayServicesBrightness`. It implements `BrightnessControlling`; `AppModel`
wires it in. The `Coordinator` is unchanged.

### Ramp behavior

- `write(target)`:
  - Cancel any in-flight ramp.
  - Read the panel's current level. If the read fails, write `target` directly
    (never drop a write). If `|target - current| < 0.01` (already
    imperceptible), write directly.
  - Otherwise emit ~24 interpolated writes over ~350 ms on a 60 Hz timer on the
    main run loop, ease-in-out, final step exactly `target`.
- `read()` / `canControl`: forward to the wrapped control.
- `flush()`: cancel the timer and synchronously write the pending final target.

### The invariant that keeps the Coordinator correct

The `Coordinator` attributes `read() - lastWritten` to external causes (user,
ambient sensor). Every ramp must therefore complete before the next tick's
read. 350 ms < the ~500 ms between one tick's write and the next tick's read,
so reads at tick boundaries always see the settled value. Probe ticks write
nothing, so the ramper is idle during probes.

### Termination

`AppModel` calls `flush()` in the quit/termination path after
`restoreBaseline()`, so the process cannot exit mid-ramp and leave the panel
between levels. During normal running, the pause/restore write ramps smoothly
like any other.

## Structure

- `AutoBrightnessCore/BrightnessRamp.swift`: pure step generator — given
  (start, target, step count), returns the eased intermediate values. Fully
  unit-testable.
- `AutoBrightnessApp/RampingBrightness.swift`: the decorator; owns the timer,
  drives the generator, forwards reads.
- `AppModel`: construct `RampingBrightness(wrapping: DisplayServicesBrightness)`,
  pass to `Coordinator`, call `flush()` on termination.

## Testing

- Generator: endpoints exact, values monotonic between endpoints, per-step
  delta below the perceptual threshold, degenerate cases (zero distance, one
  step).
- Decorator: against the existing fake brightness control with a
  manually-pumped stepper — write starts a ramp, a second write supersedes the
  first, flush lands the final target, failed read falls back to direct write.
- Coordinator behavior is already pinned by existing tests and is untouched.

## Out of scope

Tick-rate changes, controller retuning, private smooth-set APIs.
