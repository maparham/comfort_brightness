# Menu Bar Icon Visibility — Design

**Date:** 2026-08-05
**Status:** Approved

## Goal

Show the menu bar glyph alongside the brightness percentage by default, and
give the user a setting to hide the glyph.

## Background

Today `updateStatusItem()` in `Sources/AutoBrightnessApp/main.swift` shows the
brightness percentage as the status item's title whenever the panel's
brightness is readable, and falls back to the code-drawn glyph
(`makeStatusGlyph()`) only when it is not. The glyph is therefore invisible in
normal use.

## Behavior

- **Default:** the status item shows the glyph followed by the percentage
  (e.g. glyph + `72%`).
- **Setting:** a "Show icon in menu bar" toggle, on by default, in the settings
  popover, grouped with "Open at login".
- **Off:** the status item shows the percentage only — today's appearance.
- **Fallback rule (overrides the setting):** when the panel's brightness cannot
  be read there is no percentage to display, so the glyph is shown regardless
  of the toggle. Without this the status item would render empty and become
  effectively unclickable, stranding a menu-bar-only app with no way to reach
  its settings.

## Implementation

**`Sources/AutoBrightnessApp/AppModel.swift`**

- New public property `showsMenuBarIcon: Bool`, following the existing
  `isEnabled` / `strength` pattern: a `didSet` that writes through to
  `UserDefaults.standard` under the key `showsMenuBarIcon`.
- Registered in the `defaults.register(defaults:)` call in `init()` with a
  default of `true`, and read back with `defaults.bool(forKey:)`.

**`Sources/AutoBrightnessApp/main.swift`**

`updateStatusItem()` already re-runs on change via `withObservationTracking`.
It reads `showsMenuBarIcon` inside the tracked block alongside
`displayBrightness`, so toggling the setting updates the menu bar immediately.
The branch becomes:

- `button.image` = the glyph when `showsMenuBarIcon` is true **or** brightness
  is nil; otherwise nil.
- `button.title` = the percentage when brightness is readable; otherwise empty.

**`Sources/AutoBrightnessApp/SettingsView.swift`**

- `Toggle("Show icon in menu bar", isOn: $model.showsMenuBarIcon)` placed
  immediately above the existing "Open at login" toggle.

## Out of scope

- Removing the status item entirely. A menu-bar-only app with no status item
  has no way to reach its settings; hiding the glyph while keeping the
  percentage preserves a click target in every state.
- Any change to the glyph's artwork, to the app icon, or to the core engine.

## Success criteria

- On first launch with no stored preference, the menu bar shows glyph +
  percentage.
- Toggling "Show icon in menu bar" off removes the glyph immediately, leaving
  the percentage; toggling it back on restores the glyph immediately.
- The setting survives a quit and relaunch.
- When brightness is unreadable, the glyph is shown whatever the toggle says.
- `swift test` still passes (67 tests); the core engine is untouched.
