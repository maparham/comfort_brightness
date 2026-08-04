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
of what's on screen (a low-resolution sample, letterboxing and pillarboxing
cropped out so black bars around a video don't get mistaken for a dark
scene) and applies a bounded adjustment on top of that baseline: brighter
for dark content, dimmer for bright content, by default no more than ±20%,
ramping in over roughly 2 seconds so it never jumps.

If you press a brightness key, that new level becomes the baseline
immediately — the app re-baselines rather than fighting you or undoing your
adjustment. The same happens when you disable the app, pause it, or quit it:
the panel returns to your baseline, not to some app-internal default.

## Screen Recording permission

Auto Brightness asks for Screen Recording permission the first time it
runs. It needs this to sample the screen's content — at just 64 pixels
wide, twice a second — to compute how bright the content is. Nothing is
recorded, stored, or transmitted anywhere; the sampled pixels are used only
to compute a single number (a luminance estimate) and are then discarded.

## Interaction with macOS's own auto-brightness

macOS's own "Automatically adjust brightness" setting (System Settings >
Displays) also changes the panel level in response to ambient light. Auto
Brightness is designed to coexist with it: because the app treats *any*
change in the underlying brightness level as new user intent, an ambient-
sensor-driven change is expected to simply become the new baseline, the same
way a keypress would.

That said, this coexistence has not yet been verified empirically. A
diagnostic, `Sources/ALSProbe/main.swift`, exists specifically to measure it:
run it with `swift run ALSProbe` with "Automatically adjust brightness"
turned on, keep the room lighting steady, and don't touch the brightness
keys for the roughly 3 minutes it runs. The probe holds the panel at a
fixed brightness via repeated writes and measures how much it drifts;
drift below its threshold means the ambient sensor and this app are not
fighting each other, drift above it means they are. Until that probe has
been run and its result recorded, treat the interaction as unverified
rather than assume it either works cleanly or causes problems. If you do
observe the two fighting each other in practice, turning off "Automatically
adjust brightness" removes the variable entirely.

Auto Brightness controls only the built-in display; external monitors are
left untouched. Brightness read-back on Apple Silicon hardware is exact,
so the app always knows the true current level before applying an offset.

## Building and installing

Build the app bundle with:

```bash
Scripts/make-bundle.sh
```

This builds a release binary, assembles `AutoBrightness.app` in the
repository root, and ad-hoc code-signs it. Install it by copying it to your
Applications folder:

```bash
cp -R AutoBrightness.app /Applications/
open /Applications/AutoBrightness.app
```

The app runs as a menu bar accessory with no Dock icon. On first launch it
will prompt for Screen Recording permission; grant it in System Settings >
Privacy & Security > Screen Recording.

Because `Scripts/make-bundle.sh` signs the bundle ad-hoc (no paid developer
certificate), macOS ties the Screen Recording grant to that specific
signature. Rebuilding the app produces a new signature, so **you may be
asked to re-grant Screen Recording permission after every rebuild**. If
that becomes tiresome, sign the bundle with a free personal Apple
development certificate instead, which keeps the identity stable across
rebuilds.

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
- **Pause for 1 hour** — temporarily suspend adjustment, e.g. for a
  presentation, without disabling the app.
- **Open at login** — launch Auto Brightness automatically when you log in.
