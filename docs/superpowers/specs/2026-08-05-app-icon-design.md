# App Icon Design — Auto Brightness

**Date:** 2026-08-05
**Status:** Approved (brainstormed via visual companion; user selected concept B1, flat warm-cream screen)

## Goal

Give the app a proper macOS app icon (Dock / Finder / Spotlight) and a matching
menu bar status icon, wired into the existing Xcode app target.

## Design

### App icon (squircle)

A Mac display with a centered sun on its screen, on a navy body:

- **Body:** macOS squircle filled with a vertical gradient, `#2b3a5c` (top) → `#141d33` (bottom).
- **Display:** rounded-rect screen with a white bezel and matching stand (trapezoid + base bar), all in `#e8edf5`. The display is horizontally centered, occupying roughly the middle 70% of the icon's width.
- **Screen fill:** flat warm cream `#fdf6e3` — no gradient.
- **Sun:** centered on the screen. Amber `#f7b733` disc with eight detached, round-capped rays (N, NE, E, SE, S, SW, W, NW).

Geometry reference (the approved mockup, on a 160-unit canvas; scale ×6.4 for 1024):

- Squircle: rect at (8,8) size 144×144, corner radius 34 (at 1024: standard Apple icon grid — content inset ~5% per side, corner radius ≈ 234).
- Display screen: rect at (30,38) size 100×68, corner radius 8, stroke width 4.
- Stand: trapezoid from (70,110) to (90,110) widening to 12 units tall; base bar at (56,122) size 48×6, radius 3.
- Sun: disc center (80,72) radius 15; rays stroke-width 4, round caps, extending from radius ~19 to ~26.

### Menu bar status icon

Same silhouette at glyph scale so the pair reads as one app:

- Display outline (rounded rect + base line) with a small sun inside: filled disc plus four short cardinal rays (diagonal rays dropped at this size for clarity).
- Monochrome **template image** (black shapes, transparent background) so macOS tints it for light/dark menu bars and the highlighted state.
- Target size 17×17 pt artwork (rendered @1x and @2x, or a single PDF with "Preserve Vector Data").

## Production approach

- **Source of truth:** an SVG of the app icon and an SVG of the menu bar glyph, stored under `Resources/` (e.g. `Resources/Icon/`).
- **Generation script** in `Scripts/` renders PNGs from the SVGs using tools available on macOS (prefer `rsvg-convert` if installed; otherwise render via a small Swift/CoreGraphics or `qlmanage` + `sips` fallback). Regenerating assets is one command.
- **App icon asset:** `AppIcon.appiconset` in an asset catalog attached to the Xcode target, with the standard macOS sizes (16, 32, 128, 256, 512 pt @1x/@2x, from a 1024 master).
- **Menu bar icon:** template image asset (asset catalog entry with "Template Image" rendering intent, or `NSImage.isTemplate = true` in code) used by the existing `NSStatusItem` in `main.swift`.

## Out of scope

- No Dock-icon-only mode changes (the app remains a menu bar app; `LSUIElement` behavior is untouched).
- No dynamic/animated menu bar icon states (e.g. reflecting pause state) — could be a later enhancement.

## Success criteria

- The built app shows the new icon in Finder, the Dock (if shown), and the app switcher.
- The menu bar shows the display+sun glyph, correctly tinted in light and dark menu bars.
- Deleting the generated PNGs and re-running the script reproduces them exactly.
