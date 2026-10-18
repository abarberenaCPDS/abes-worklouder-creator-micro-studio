# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

macOS menu-bar app (Studio) that lights each running [Herdr](https://herdr.dev) agent on its own key of a Work Louder Creator Micro 2 over raw HID, and focuses that agent when the key is pressed. See `AGENTS.md` for the full list of project rules (read it first), `README.md` for behavior/config, `docs/hacking.md` before touching the HID protocol, and `docs/signing.md` for code signing, permissions and local deployment.

## Commands

```bash
swift test --package-path Packages/CreatorMicroStudioKit                       # package tests
swift test --package-path Packages/CreatorMicroStudioKit --filter '<name>'     # single test
xcodebuild -project AbesWorkLouderCreatorMicroStudio.xcodeproj -scheme CreatorMicroStudio -destination 'platform=macOS' build
xcodebuild -project AbesWorkLouderCreatorMicroStudio.xcodeproj -scheme Inspector -destination 'platform=macOS' build   # when changing the standalone Inspector
./scripts/update-icons.sh   # regenerate stable + DEV-badged app icons, Welcome splash icons, favicons (after intentional artwork change)
./scripts/archive.sh        # signed Release archive into ignored .build/
```

No linter is configured. Live tests (device, Herdr) are skipped unless `CREATOR_MICRO_STUDIO_LIVE_TESTS=1`; only set it deliberately.

To run without hardware, set `WL_EMULATE=1` in the CreatorMicroStudio scheme's Run environment (emulator lives in the Studio process; standalone Inspector still needs a real pad).

## Architecture

- **`Packages/CreatorMicroStudioKit`** (Swift tools 5.9, macOS 13): all non-UI logic and tests.
  - `Device/` — raw-HID JSON-RPC to the pad (`WLDevice`, `OAIProtocol`), keymap binding (`KeymapManager`), and `PadEmulator`, which deliberately mimics firmware quirks (answers `{"ok":1}` to anything, boots on the stock F-key keymap).
  - `Integrations/` — `HerdrClient` (reads Herdr's socket directly), `HerdrCommand` (parses/resolves Herdr command lines and their placeholders) and `HerdrCLI` (runs the `herdr` binary with an argument array).
  - `Bridge/` — `BridgeController` ties Herdr state to pad lights/key events; `StatusMapper` maps agent state to colors.
  - `Configuration/` — `PadInput` (the 20 inputs), `InputAction` (every action, config encoding), `KeyBindings` (per-input overrides + prompt text), `LightingPreferences` (Studio-owned lighting), all saved through `StudioConfigStore` to `~/.config/creator-micro-studio/config.json`.
  - `Integrations/SystemActions.swift` — scroll, shortcut, media key, type text, open and shell actions (CGEvent/AppKit); `HerdrStatus` is what the Herdr page shows.
  - `Formatting/HTMLText.swift` — escapes text for the floating panels' HTML.
- **`Apps/CreatorMicroStudio`** — menu-bar app: Panel, Studio window (sidebar: Studio dashboard, Controls, Lighting, Herdr, and the shared Inspector view), and features (Tune, Voice, Emulator, Welcome, Permissions helper, Herdr ask panel). It embeds the standalone **`Apps/Inspector`** as a separately signed helper with its own bundle ID.

## Gotchas

- The pad is single-owner: Studio bridge, Inspector helper, Work Louder Input, and Codex desktop all fight over lighting. Pause the Studio bridge before opening the standalone Inspector.
- Input Monitoring is tied to the bundle's signature/ID; changing bundle IDs (`dev.abeisonai.worklouder.*`) resets permissions. Debug = **Dev** app (`.dev` bundle IDs, DEV-badged icon), Release/Archive = **Stable**; names and IDs come from `WL_*` build settings via `AppIdentity`, so never hard-code them.
- Firmware returns `{"ok":1}` even for malformed writes — verify by LEDs or reading back keymaps. Keymap writes consume flash; key actions and prompt text are host-side config and must never rewrite the device keymap.
- `Pad.rows` is the firmware `[2, 4, 4, 3]` matrix; UI drawings use `Pad.physicalDisplayRows`.
- Inputs are ids 0–19: keys 0–12, dial 13 right / 14 left / 19 push (bound to `KV_OAI_AG19`), joystick 15 up / 16 left / 17 down / 18 right. No diagonals or centre press (no ids left). Only keys 0–12 have LEDs.
- Every input can use every `InputAction`; defaults are `InputAction.defaultAction(for:)` (keys Focus Agent — 0–5 their Herdr slot, others the current agent; dial effort ± and push Play/Pause; joystick model picker). Dispatch goes only through `handleKeyPress` → `action(for:)`. System actions need Accessibility.
- Lighting persistence is Studio's, in `config.json` `"lighting"`. The Inspector is temporary (lasts until Studio repaints); only its Save to Studio buttons persist, and Studio runs `reloadConfiguration()` when it takes the pad back.
- The Debug embedded helper is `…InspectorDev.app`; the embed phase uses a `$(WL_INSPECTOR_PRODUCT_NAME).app` file reference because a product reference resolves one name for all configurations.
- Access the stock keymap test fixture via `Bundle.module`, not a `#filePath`-relative path.
- The Herdr command action (`InputAction.herdrCommand`) is a Herdr CLI line without `herdr`, run by `HerdrCommand`/`HerdrCLI` with an argument array (never a shell, never `command.invoke`); placeholders such as `{tab}` mean the *current* (focused) tab/workspace/pane, read fresh at press time. `{ask:…}` goes through `BridgeController.onAsk`, which the app wires to `HerdrAskPanel`. Only add an Examples entry whose syntax you checked against the local `herdr` usage text, offline.
- Permission UI: `InputMonitoringPrompt.request()` (in `Features/Permissions/PermissionHelper.swift`) asks, probes a listen-only event tap, and opens `PermissionHelperWindowController` (`.inputMonitoring` / `.accessibility`) when macOS shows nothing; reuse that helper and `AppIdentityCard` instead of adding separate "Open Settings" buttons. Launch requests stay quiet (`showHelperIfSilent: false`). Accessibility is named "Device Control and Data Access" on newer macOS; mention both names. HID report writes run on `WLDevice`'s private serial queue: never call `IOHIDDeviceSetReport` on main. Lighting saves after 3 s idle (preview paints are coalesced); Controls text saves on submit/blur/3 s idle.
- Env overrides: `WL_TERMINAL_BUNDLE_ID`, `HERDR_SOCKET_PATH`, `WL_HERDR_PATH`.
- GitButler support (the `stack`/`land` actions and panels) was removed; legacy `"stack"`/`"land"` values in `config.json` parse as no override (`InputAction.Kind.retiredConfigNames`).
