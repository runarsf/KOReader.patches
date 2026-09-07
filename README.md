# KOReader patches

A few user patches for [KOReader](https://github.com/koreader/koreader). To install any of them, grab them from [storefront](https://github.com/ultimatejimmy/storefront.koplugin) or drop the file into `koreader/patches/` and restart KOReader.

## [2-realtime-frontlight.lua](2-realtime-frontlight.lua)

Hold and drag on the left screen edge to change brightness in real time, and on the right edge to change warmth. Requires a frontlight; the warmth control only appears on devices with natural light.
No configuration needed.

## [2-toggle-font.lua](2-toggle-font.lua)

Toggle between two configurable fonts in reflowable documents from a gesture.\
(In a document) navigate to `Tools > Toggle font` to set the fonts. Optimally, `Font A` should be the same as the default reader font.
Find the gesture under `Reflowable documents (epub, fb2, txt...) > Toggle font`.

## [2-portable-settings.lua](2-portable-settings.lua)

Export and import a device-agnostic subset of your settings through a `portable_settings.lua` file with no hardware-specific keys, letting you sync the file between devices (e.g. using Syncthing).\
(In a document) navigate to `Tools > Portable settings` for options.

Example Syncthing configuration:
- **Folder Path**: path to KOReader, `/mnt/onboard/.adds/koreader` on Kobo devices
- **Ignore Patterns**:
  ```gitignore
  // Files to sync
  !/portable_settings.lua

  // Whole directories to sync
  !/patches/
  !/plugins/
  !/styletweaks/
  !/screensavers/
  !/scripts/
  !/phrasedeck/
  !/fonts/

  // Only gestures.lua out of settings/
  !/settings/gestures.lua
  /settings/*
  !/settings/

  // Catch-all
  *
  ```
