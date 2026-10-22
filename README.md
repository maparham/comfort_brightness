# Auto Brightness

A macOS menu bar app that nudges your built-in display's brightness based on
what's actually on screen — without taking control away from you.

## The problem

Two everyday situations make a fixed brightness level wrong:

- A near-white page (a blank document, a bright website) at a brightness
  level that was comfortable for normal content is uncomfortably bright.
- A dark, full-screen video is muddy and hard to read at a brightness level
  that was comfortable for normal content.

Auto Brightness watches the screen's content and applies a small, bounded
correction in real time so both situations resolve themselves, without you
having to reach for the brightness keys every time the content changes.

## How it works: an offset, not a takeover

Auto Brightness never decides your brightness for you. Whatever level you
have set — manually, with the brightness keys, or via macOS's own ambient
light sensor — is treated as your baseline. The app measures the luminance
of what's on screen (a low-resolution sample, with real letterbox and
pillarbox bars cropped out so the adjustment is sized to the picture rather
than to the black frame around it) and applies a bounded adjustment on top
of that baseline: brighter
for dark content, dimmer for bright content, by default no more than ±20%,
ramping in over roughly 2 seconds — adjustable up to 8 seconds — so it never jumps.

A dark theme is not a dark video, and the two are not treated alike: the bar
crop only fires on genuinely black bars at opposing edges of the frame, so a
dark editor or terminal filling the screen is measured as it actually is
rather than having its edges shaved off.

If the capture stream stops — you plug in a monitor, change resolution, or
the display sleeps and wakes — the app notices, hands the panel back to your
baseline, and reconnects, rather than freezing with an adjustment still
applied.

If you press a brightness key, that new level becomes the baseline
immediately — the app re-baselines rather than fighting you or undoing your
adjustment. The same holds for a gradual change rather than a keypress: a
brightness that eases up or down over several seconds, as macOS's ambient
controller does, is followed as it moves rather than partly absorbed and
partly written back down. The same happens when you disable the app, pause it, or quit it:
the panel returns to your baseline, not to some app-internal default.

## Screen Recording permission

Auto Brightness asks for Screen Recording permission the first time it
runs. It needs this to sample the screen's content — at just 64 pixels
wide, twice a second — to compute how bright the content is. Nothing is
recorded, stored, or transmitted anywhere; the sampled pixels are used only
to compute a single number (a luminance estimate) and are then discarded.

macOS usually only honours a screen-capture grant for a process that started
after the grant, so if the app does not begin working once you have allowed
it in System Settings, quit and reopen it. The settings popover has a
**Try Again** button and says the same thing.

Sampling stops whenever the app is not acting on what it sees: switch the
toggle off or pause, and the capture stream is torn down — the screen is not
watched and the macOS screen-recording indicator goes out.

## Interaction with macOS's own auto-brightness

macOS's own "Automatically adjust brightness" setting (System Settings >
Displays) also changes the panel level in response to ambient light. Auto
Brightness is designed to coexist with it: because the app treats *any*
change in the underlying brightness level as new user intent, an ambient-
sensor-driven change is expected to simply become the new baseline, the same
way a keypress would.

Following a *smooth* change, not just a stepped one, is what this depends on,
and it is pinned by tests: a ramp applied on top of the app's own writes is
followed in full, in either direction, including one slow enough that no single
half-second reading would register it. Distinguishing that from an actuator
whose read-back simply disagrees with what it was given takes an actual
measurement, so when the same movement repeats the app skips one write and
looks at what the panel does with its hands off: a lying actuator stays put, a
real change keeps moving.

That said, this coexistence has not yet been verified empirically. A
diagnostic, `Sources/ALSProbe/main.swift`, exists specifically to measure it:
run it with `swift run ALSProbe` with "Automatically adjust brightness"
turned on and don't touch the brightness keys for the roughly 4 minutes it
runs. It has two phases. First it watches for a minute *without writing
anything*, to see what the ambient controller does when left alone — without
that, a quiet result in the second phase would be unreadable, since it looks
identical whether the two coexist or our own writes are simply overpowering
the sensor. Then it holds the panel at a fixed brightness with repeated
writes and measures the drift. The printed verdict interprets both phases
together, and says so when the room was too steady for the result to mean
anything. Until that probe has been run and its result recorded, treat the
interaction as unverified rather than assume it either works cleanly or
causes problems. If you do observe the two fighting each other in practice,
turning off "Automatically adjust brightness" removes the variable entirely.

Auto Brightness adjusts every connected display it can drive, each from its
own content: dark content on one screen does not dim another. The built-in
panel and Apple's own displays (Studio Display, Pro Display XDR, LG
UltraFine) are driven through the same system interface as the brightness
keys. Other monitors are driven over DDC/CI, the standard most monitors
accept over USB-C, DisplayPort and HDMI, on Apple Silicon Macs only.

The popover lists each display. One that cannot be driven says why: no DDC
connection (DisplayLink docks, AirPlay, Sidecar, some hubs and KVMs), a
monitor that did not answer (check that DDC/CI is enabled in its own menu),
or one that accepts commands but ignores them. Pressing a monitor's own
brightness buttons is followed rather than fought, usually within a second.
Displays can come and go while the app runs; it picks them up without a
relaunch.

## Building and installing

There are two ways to build, and which you pick determines how often macOS
asks you for Screen Recording permission.

### Xcode (recommended)

```bash
xcodegen generate       # only after editing project.yml
open AutoBrightness.xcodeproj
```

Build and run with ⌘R. The project is generated from `project.yml` by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml` is the
source of truth and the `.xcodeproj` is a git-ignored build artifact, so edit
the former and regenerate rather than changing settings in Xcode's UI.

Debug builds sign with **Apple Development**, Release with **Developer ID
Application**. This matters more than it sounds: macOS ties the Screen
Recording grant to the app's code signature, and a real certificate produces a
stable one. You grant the permission once and rebuilds keep it. Switching
between the two configurations counts as a different identity, so expect one
extra prompt the first time you build Release.

The Swift package remains the source of truth for the engine and its tests —
`swift test` runs the full suite and does not require Xcode.

### Running it

The app runs as a menu bar accessory with no Dock icon. On first launch it
prompts for Screen Recording permission; grant it in System Settings >
Privacy & Security > Screen Recording, then quit and reopen the app — macOS
generally does not hand a running process a capture grant it started without.

The build is not notarized. That is fine for running it on the machine
that built it. If you copy it to another Mac, Gatekeeper will quarantine it
until you notarize the Release build.

## Private APIs and future compatibility

Auto Brightness controls the display through `DisplayServicesSetBrightness`,
a private, undocumented Apple API. This means:

- The app cannot be distributed through the Mac App Store, which forbids
  private API usage.
- A future macOS release could change or remove this API without notice,
  breaking brightness control.

The app is built to fail safely if that happens: if the private symbol
cannot be resolved or the display reports itself as uncontrollable, Auto
Brightness detects this and shows a clear "brightness control unavailable"
state in its menu rather than crashing or behaving unpredictably.

The private brightness API resolves and works on macOS 26.5 (Apple Silicon).

## Settings

Click the menu bar icon to open the settings popover:

- **Enable** — turn content-based adjustment on or off. When off, the
  panel stays at your last baseline.
- **Strength** — how strongly content luminance maps to a brightness
  offset.
- **Maximum change** — the clamp on how far the offset can move the panel
  from baseline (default ±20%).
- **Time to adjust** — how long an adjustment takes to arrive
  (default 2 seconds, up to 8). It sets two things at once: the size of the
  step the offset may take each tick, and how long new content must hold
  before it counts at all — so at a longer setting, alt-tabbing through a
  bright window for a moment changes nothing.
- **Reset to defaults** — puts the three sliders above back to the values the
  app ships with. It leaves the toggles alone: those are choices, not tuning.
- **Pause for 1 hour** — temporarily suspend adjustment, e.g. for a
  presentation, without disabling the app. Screen sampling stops for the
  duration. While a pause is running it is shown with a **Resume** button,
  whether or not the app is enabled.
- **Open at login** — launch Auto Brightness automatically when you log in.
