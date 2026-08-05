# Brightness Readout — Design

Date: 2026-08-05

## Goal

Show the built-in panel's actual current brightness both in the menu bar and
inside the popover.

## Requirements

- The menu bar status item shows the brightness as a percentage only
  (e.g. `72%`), replacing the static `sun.max` icon while a value is readable.
- If brightness cannot be read (no built-in panel, symbols unavailable), the
  status item falls back to the existing sun icon.
- The popover shows a prominent `Brightness: 72%` readout near the top, just
  under the enable toggle. The Details section is unchanged.
- The readout reflects reality even while the app is paused or disabled —
  pressing the hardware brightness keys must be reflected.

## Design

### Reading and refreshing

`AppModel` gains a published property:

```swift
public private(set) var displayBrightness: Double?  // nil when unreadable
```

It is refreshed from `DisplayServicesBrightness.read()`:

1. on every coordinator tick (inside `refreshReadouts()`), so ramps are
   tracked in near-real-time while adjusting; and
2. from a 2-second repeating timer started in `start()`, so the value stays
   correct while paused, disabled, or when the sampler is down, and picks up
   manual brightness-key changes.

`read()` is a cheap in-process function-pointer call; a 2 s poll is
negligible.

### Menu bar

`AppDelegate` switches the status item to variable length and sets its
button `title` to the formatted percentage whenever `displayBrightness`
changes, using `withObservationTracking` re-armed on each change. When the
value is nil, it clears the title and restores the sun icon.

### Popover

`SettingsView` adds a readout row under the enable toggle showing
`Brightness: NN%` when `displayBrightness` is non-nil; hidden otherwise.

## Files touched

- `Sources/AutoBrightnessApp/AppModel.swift`
- `Sources/AutoBrightnessApp/main.swift`
- `Sources/AutoBrightnessApp/SettingsView.swift`

## Testing

Manual: run the app; verify the menu bar percentage, the popover readout,
that hardware brightness keys update both within ~2 s, that ramps animate
the readout, and that the icon fallback appears when no built-in display is
present (clamshell). This is UI/private-API glue with no core logic, so no
unit tests are added.
