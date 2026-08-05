# Menu Bar Icon Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the menu bar glyph alongside the brightness percentage by default, with a "Show icon in menu bar" setting to hide the glyph, per `docs/superpowers/specs/2026-08-05-menu-bar-icon-visibility-design.md`.

**Architecture:** A persisted `showsMenuBarIcon` flag on `AppModel` (same `didSet`-writes-to-`UserDefaults` pattern as the existing `isEnabled`/`strength` properties), read inside `updateStatusItem()`'s `withObservationTracking` block so the menu bar updates the instant the toggle flips, plus a `Toggle` in `SettingsView`. The core engine is untouched.

**Tech Stack:** Swift 6, AppKit (`NSStatusItem`), SwiftUI, `@Observable`, `UserDefaults`.

## Global Constraints

- Swift 6.0, strict concurrency `complete`; macOS deployment target 15.0. `AppModel` is `@MainActor @Observable`.
- UserDefaults key: exactly `showsMenuBarIcon`; registered default `true`.
- Toggle label copy: exactly `Show icon in menu bar`.
- Fallback rule overrides the setting: when `displayBrightness` is nil the glyph is shown regardless of `showsMenuBarIcon`, so the status item never renders empty.
- `AutoBrightness.xcodeproj` is a git-ignored artifact generated from `project.yml` by `xcodegen generate`; never hand-edit the `.pbxproj`. `Sources/AutoBrightnessApp` is a directory reference, so no project change is needed for edits to existing files.
- Do not change the glyph artwork (`StatusGlyph.swift`), the app icon, or anything under `Sources/AutoBrightnessCore`.

**Why no new unit tests:** the change lives entirely in the `AutoBrightnessApp` executable target (UI + status item), which the `AutoBrightnessCoreTests` bundle cannot import — the existing 67 tests cover the core engine, which this plan does not touch. Verification is a build plus a scripted check of the persistence behavior and a manual run-through of the toggle. `swift test` must still pass.

---

### Task 1: Persisted setting, status item wiring, and the toggle

**Files:**
- Modify: `Sources/AutoBrightnessApp/AppModel.swift` (add the property; register + read the default in `init()`)
- Modify: `Sources/AutoBrightnessApp/main.swift:48-67` (`updateStatusItem()`)
- Modify: `Sources/AutoBrightnessApp/SettingsView.swift:62` (add the toggle above "Open at login")

**Interfaces:**
- Consumes: `makeStatusGlyph() -> NSImage` from `Sources/AutoBrightnessApp/StatusGlyph.swift` (already present; `@MainActor`, returns a 17×17 template image).
- Produces: `AppModel.showsMenuBarIcon: Bool` — a public, observable, `UserDefaults`-backed property.

- [ ] **Step 1: Add the property to AppModel**

In `Sources/AutoBrightnessApp/AppModel.swift`, add this property immediately after the `maxOffset` property's closing brace (i.e. before `public var launchAtLogin`):

```swift
    /// Whether the menu bar shows the app's glyph next to the brightness
    /// percentage. Hiding it leaves the percentage alone as the click target;
    /// `updateStatusItem` shows the glyph anyway when there is no percentage to
    /// show, so the status item can never end up empty and unclickable.
    public var showsMenuBarIcon: Bool {
        didSet {
            UserDefaults.standard.set(showsMenuBarIcon, forKey: "showsMenuBarIcon")
        }
    }
```

- [ ] **Step 2: Register the default and read it in `init()`**

In the same file, in `init()`, extend the `defaults.register(defaults:)` dictionary so it reads:

```swift
        defaults.register(defaults: [
            "isEnabled": true,
            "showsMenuBarIcon": true,
            "strength": ControllerSettings.defaults.strength,
            "maxOffset": ControllerSettings.defaults.maxOffset,
        ])
```

Then, in the block of assignments further down `init()`, add the read immediately after the `isEnabled` assignment so the lines read:

```swift
        isEnabled = defaults.bool(forKey: "isEnabled")
        showsMenuBarIcon = defaults.bool(forKey: "showsMenuBarIcon")
        strength = settings.strength
```

- [ ] **Step 3: Use the flag in `updateStatusItem()`**

In `Sources/AutoBrightnessApp/main.swift`, replace the whole body of `updateStatusItem()` (currently lines 48-67, from `guard let button` through the closing brace) with:

```swift
        guard let button = statusItem?.button else { return }
        let (brightness, showsIcon) = withObservationTracking {
            (model.displayBrightness, model.showsMenuBarIcon)
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateStatusItem()
            }
        }
        // The glyph is unconditional when there is no percentage: a status item
        // with neither image nor title collapses to nothing the user can click.
        button.image = (showsIcon || brightness == nil) ? makeStatusGlyph() : nil
        button.title = brightness.map { "\(Int(($0 * 100).rounded()))%" } ?? ""
```

Also update the doc comment directly above `updateStatusItem()` — replace the existing comment lines with:

```swift
    /// Shows the app glyph and the panel's brightness as a percentage. The
    /// glyph is hidden when the user turns it off, and the percentage is
    /// dropped when brightness cannot be read (no built-in panel, clamshell,
    /// symbols gone). `withObservationTracking` fires once per change, so each
    /// update re-arms it.
```

- [ ] **Step 4: Add the toggle to SettingsView**

In `Sources/AutoBrightnessApp/SettingsView.swift`, replace the line

```swift
            Toggle("Open at login", isOn: $model.launchAtLogin)
```

with

```swift
            Toggle("Show icon in menu bar", isOn: $model.showsMenuBarIcon)

            Toggle("Open at login", isOn: $model.launchAtLogin)
```

- [ ] **Step 5: Build both targets**

Run: `swift build 2>&1 | tail -2`
Expected: `Build complete!` with no warnings.

Run: `xcodebuild -project AutoBrightness.xcodeproj -scheme AutoBrightness -configuration Debug build 2>&1 | tail -2`
Expected: `** BUILD SUCCEEDED **`

(If `AutoBrightness.xcodeproj` does not exist in the checkout, run `xcodegen generate` first — it is a git-ignored generated artifact.)

- [ ] **Step 6: Verify the tests still pass**

Run: `swift test 2>&1 | tail -2`
Expected: `Test run with 67 tests in 0 suites passed`.

- [ ] **Step 7: Verify the default and the persistence round-trip**

The registered default and the write-through are the two things a build cannot prove. Check them against the same `UserDefaults` API the app uses, in the scratchpad (not the repo) — write this to `<scratchpad>/defaults-check.swift` and run `swift <scratchpad>/defaults-check.swift`:

```swift
import Foundation

let suiteName = "com.mahmoudparham.AutoBrightness.plancheck"
let defaults = UserDefaults(suiteName: suiteName)!
defaults.removePersistentDomain(forName: suiteName)

// Mirrors AppModel.init's registration.
defaults.register(defaults: ["showsMenuBarIcon": true])
precondition(defaults.bool(forKey: "showsMenuBarIcon") == true,
             "registered default must be true")

// Mirrors the didSet write-through, then a fresh read as on relaunch.
defaults.set(false, forKey: "showsMenuBarIcon")
precondition(defaults.bool(forKey: "showsMenuBarIcon") == false,
             "an explicit false must win over the registered default")

defaults.removePersistentDomain(forName: suiteName)
print("defaults behavior OK")
```

Expected output: `defaults behavior OK`.

- [ ] **Step 8: Run the app and exercise the toggle**

Run: `Scripts/make-bundle.sh && open AutoBrightness.app`

Then confirm, in the real menu bar:
1. The status item shows the glyph followed by the percentage.
2. Clicking it opens the popover, which lists "Show icon in menu bar" (on) directly above "Open at login".
3. Turning it off removes the glyph immediately, leaving the percentage; turning it on restores it immediately.
4. Quit from the popover's Quit button, relaunch with `open AutoBrightness.app`, and confirm the setting survived.

Then quit the app, and remove the build output so it does not linger: `rm -rf AutoBrightness.app`.

If the machine has no readable built-in panel (the percentage never appears), report that instead of the observations for steps 1 and 3 — the glyph should be present in every state there, which is the fallback rule.

- [ ] **Step 9: Commit**

```bash
git add Sources/AutoBrightnessApp/AppModel.swift Sources/AutoBrightnessApp/main.swift Sources/AutoBrightnessApp/SettingsView.swift
git commit -m "feat: show the menu bar glyph by default, with a setting to hide it"
```
