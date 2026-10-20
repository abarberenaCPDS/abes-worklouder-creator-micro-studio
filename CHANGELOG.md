# Changelog

This project follows [Semantic Versioning](https://semver.org). The version is
`MARKETING_VERSION` in `AbesWorkLouderCreatorMicroStudio.xcodeproj`, shared by
the Studio and Inspector targets; `CURRENT_PROJECT_VERSION` is the build number.

## [0.4.0] — 2026-10-20

Version 0.4.0, build 9.

### Added

- **Configurable agent layout in Controls.** Dedicate any of the 13 keycaps to
  agent slots, in physical reading order, with numbered previews and confirmation
  before replacing custom actions. Layout and binding changes save together;
  existing configurations retain their six-key layout and custom actions.
- Studio, Controls, Lighting, Herdr and the menu-bar panel use the configured
  assignments. Explicit Focus slot actions support slots 1–13 independently of
  the number of dedicated keys. Agents without dedicated keys remain visible
  and still contribute to underglow status.

### Clarified

- The original six slots were a Studio pad-layout choice, not a Herdr limit.
  Agent layout changes are host-side and do not write the hardware keymap.

## [0.3.2] — 2026-10-20

Version 0.3.2, build 8.

### Fixed

- **Focus Agent now raises the terminal actually running Herdr.** The host app
  was assumed to be Ghostty, so with iTerm2, Terminal or any other client the
  tab changed inside Herdr but no window came forward. It is now detected from
  the running `herdr` client (the GUI ancestor of its process), with the known
  terminals as a fallback, and all of the app's windows are raised. A press
  that already had focus still returns quietly. `WL_TERMINAL_BUNDLE_ID` still
  forces a specific app.

## [0.3.1] — 2026-10-18

Version 0.3.1, build 7.

### Added

- **Input Monitoring helper.** When macOS shows no request, the helper window
  opens on its own a couple of seconds after **Request Access**. **Show me
  how…** on the Welcome window, the menu-bar panel and the Studio's Input
  Monitoring page also opens it. It shows which app to allow (icon, name,
  Stable/Dev, file name, folder, bundle ID) with **Reveal in Finder** and
  **Copy Path**, lists the steps, and has **Open System Settings** and **Quit &
  Reopen** buttons. A live status line turns green when the grant arrives.
  Controls offers the same helper for Accessibility, which newer macOS calls
  “Device Control and Data Access”.
- **Ask panel** for Herdr commands: `{ask:Prompt}` and
  `{ask:Prompt=Default}` open a small floating text box that takes keyboard
  focus. Return runs the command; Esc cancels it silently. Focus then goes
  back to the app you were in.
- **Lighting:** a “Previewing — saves in 3 s” status with **Save now** (⌘S)
  and **Revert**, and a **Live preview** switch. When it is off, the pad only
  changes when the edit is saved.

### Changed

- **Herdr command is now a Herdr CLI command line** without the leading
  `herdr`, for example `tab rename {tab} {ask:New tab name={tab_label}}`.
  Placeholders are read fresh from Herdr at press time. `{tab}` and
  `{tab_label}` are the *current* tab (the focused tab in the focused
  workspace), not the agent's tab. The others are `{workspace}`,
  `{workspace_label}`, `{pane}` and `{agent}`. Arguments use shell-style
  quoting but never go through a shell. The Controls editor has a monospaced
  field, a list of placeholders, an **Examples** menu (Rename current tab, New
  tab, Rename current workspace, New workspace, Rename current pane, Show
  notification) and a “Runs: herdr …” preview. `command.invoke` is no longer
  used. A saved keybinding such as `prefix+shift+t`, or an old command id,
  now shows an error that explains the new syntax.
- **Request Access** now also tries a listen-only event tap, which makes macOS
  evaluate the app and list it in Input Monitoring. It no longer sits next to
  a separate “Open Settings…” button; the helper covers that.
- The Studio dashboard's status is a **button** only when there is something
  to fix. **Permission needed ›** opens the Input Monitoring page and asks
  again. Connected, Waiting for the pad and Inspector active are now plain
  status text with a coloured dot.
- **Lighting saves 3 seconds** after the last change (it was 0.6 s), and
  saves at once when you leave the page or switch apps. Previews are
  coalesced: one paint at a time, at least 150 ms apart, and the last one
  always uses the latest settings.
- **Controls text fields save** on Return, when the field loses focus, or
  3 seconds after the last keystroke. Before, they saved 0.7 s after typing
  stopped. Pickers still save immediately.

### Fixed

- Dragging a lighting slider no longer stalls the UI with a spinner. HID
  report writes now run on a private serial queue instead of the main
  thread. Replies, timeouts and disconnects are still handled on main, in
  order.
- **“Keymap: fs.write: Timed out waiting for fs.write”** over Bluetooth. The
  8 s reply timeout started when a message was queued, so sending a ~45-report
  keymap over Bluetooth LE used it up before the firmware had even started
  writing flash. Reply timeouts now start after the last report is written.
  `fs.write` gets 30 s and `fs.read` 15 s, and an outer cap still fails a stuck
  write queue. A write that times out is treated as unknown: the Studio waits
  a moment, reads the keymap back (up to three times) and goes by what it
  finds.
- **“Keymap: The device did not accept the agent keymap.”** The dial push's
  `KV_OAI_AG19` is now best-effort. If the pad keeps its own code there (stock
  play/pause), the keys, dial turns and joystick still count as bound. This is
  not an error: the Studio remembers it for that firmware version on the Mac
  and never rewrites the pad for it again. The dial push row in Controls says
  “Dial push isn't available on firmware X – the pad keeps play/pause”, with
  **Retry dial push binding**, and the push no longer counts as needing
  Accessibility. If the core bindings will not stick, one fallback write
  without AG19 follows. If that fails too, the error names each slot and what
  the pad has there, for example “Joystick right (has KC_RIGHT)”, and adds
  any firmware log lines. The refusal is recorded and **Retry binding** is
  offered instead of the Studio rewriting flash on every launch. There are at
  most two keymap writes per connection, none on a Bluetooth reconnect once
  the outcome is known, and lighting is held while a keymap write is in
  flight. A write that errors, drops mid-way, or can't be read back is also
  treated as "may have reached flash": Studio stops writing until you press
  Retry, instead of trying again on the next reconnect or launch. If the
  firmware version can't be read, any recorded refusal is honoured.
- **The Controls page showed a blank sidebar and grey placeholder rows.** The
  Studio window's detail column sized each page by its ideal height, and a
  List's ideal height is all of its rows, so the page grew taller than the
  window and AppKit centred it, pushing the header, sidebar and the top of
  the list out of view. Pages are now pinned to the column's size, and
  Controls switches to a single scrolling column when the window is too
  narrow for the pad and the list side by side (rows no longer wrap letter by
  letter).
- **"The pad kept its old bindings for: Joystick left, Joystick right"** on a
  pad profile whose joystick has only two sectors (up, and one sector for
  everything else, which reports as down). A direction the profile has no
  sector for is no longer treated as a missing binding: there is nothing to
  write, so Studio no longer tries (and no longer records a refusal). Controls
  marks those rows "Not on this pad profile". The active profile is now found
  by its `id`, not by its position in the list.
- **The Controls page got stuck with a spinner.** Every bridge publish (several
  per Herdr poll or status event) rebuilt all 20 list rows, each with a menu
  of 26 action kinds, which took about 140 ms of main-thread time in a Debug
  build. Rows, the pad drawing and the editor are now built from plain values
  and skip unchanged updates, and the row menus leave out their symbols. A
  publish now costs about 10 ms. The bridge also publishes only what changed:
  Herdr status is assigned once per refresh, and key colours, zones, agents
  and the Accessibility state only when they differ. Event-driven refreshes
  are spaced at least 0.5 s apart.
- **The menu-bar icon redrew on every poll.** It now watches only its own
  state, and each state's image is drawn once.
- HID replies and key presses are no longer held back while a menu or dialog
  is open. The device is scheduled in the run loop's common modes, so a reply
  timer can't fire on an answer that had already arrived.
- Herdr sockets: a closed connection's descriptor is released only by its
  reader, so a new connection can't reuse the number and get its reply read
  by the old loop. An `events.subscribe` error is reported instead of reading
  as subscribed.
- Finding the `herdr` binary runs off the main thread, once: callers that
  arrive meanwhile share one lookup, and nothing that renders the UI starts
  it.
- Fewer redundant publishes behind Xcode's “Publishing changes from within
  view updates” warnings: page changes no longer reassign Inspector state, and
  the Lighting page adopts saved lighting on the next run-loop turn.

## [0.3.0] — not released separately (included in 0.3.1)

### Added

- **Every input is configurable.** The 13 keys, the dial (turn right, turn
  left and the new **push**) and the joystick (up, down, left, right) are 20
  inputs, ids 0–19, and every one of them can run every action. The Studio now
  binds the dial press to `KV_OAI_AG19` through the same read → check → write →
  read-back keymap path, so a pad bound by 0.2.0 gets exactly one more keymap
  write. The dial push defaults to a host-side Play/Pause, like the stock
  `KC_MPLY`, but because the Studio now sends it as a media key event it needs
  the Accessibility permission and only works while the Studio bridge is on.
  Joystick diagonals and the centre press are not supported: AG19 is
  the last free id.
- **New actions** alongside Focus Agent: focus a
  specific slot, next/previous tab and workspace, focus pane by direction, zoom
  pane, send keys to the agent, run a Herdr command, insert text, submit a
  prompt, effort up/down, next/previous model, confirm/cancel the model picker,
  scroll up/down/left/right by 1–20 lines, a keyboard shortcut, a media key,
  Voice, type text system-wide, open a URL, file or app, and run a shell
  command (`/bin/zsh -lc`, failures reported in the Studio; the 30 s timeout
  stops the command's whole process group, and a command that leaves
  something running in the background, such as `my-server &`, finishes when
  the shell exits).
  Scroll, shortcut, media, Voice and type-text post system events and need the
  Accessibility permission; the Studio marks those inputs, lists exactly which
  ones need it when it is missing, and offers the grant.
- **Controls** page in the Studio sidebar: a clickable pad drawing (keys, dial
  segments including push, joystick directions) and a list of all 20 inputs
  that share one selection (click, ⌘-click, ⇧-click). Edit an action inline,
  set one action for many inputs at once, test it (Test runs the action shown
  in the editor), or reset to the default.
  Changes save straight to `config.json`.
- **Lighting** page: global brightness and speed, underglow (agent status,
  custom or off), backlight (off or custom), the four agent status colours and
  effects, and fixed at-rest colours for individual keys, with a live preview
  and **Restore defaults**. Saved to a new `"lighting"` section of
  `config.json`, so it survives restarts and comes back after the Inspector.
  A save only writes what you changed, merged into the file as it is then, so
  the Inspector's **Save to Studio** and hand edits made while the Studio is
  open are kept; the page picks those up when it appears or the app becomes
  active.
- **Herdr** page: socket path and where it came from, connection state, version
  and protocol, last refresh, event-stream state, each agent key's slot → agent
  with its workspace › tab, pane, status and folder, agents that no input
  reaches, and every input bound to a Herdr action. Click a row to focus that
  agent.
- The Inspector says plainly that its changes are temporary, and has **Save to
  Studio** buttons for the selected keys, the underglow and the keys zone.
- The emulator and the Studio pad mirror have a dial-push control.

### Changed

- Key actions are now `InputAction` values with parameters. Parameterless
  actions are still written as strings (`"focus-agent"`); parameterised ones
  are written as objects (`{"type": "scroll", "direction": "up", "amount": 3}`).
  Older files keep working: `"macro"`, `"voice"`, `"cycle-tabs"`, the `"keys"`
  text map including `"10+11"`, and aliases such as `"dial-push"` and
  `"joy-up"` for input ids.
- The dial and joystick no longer have hard-wired behaviour. Their defaults
  are the same as before (dial tunes effort; joystick up/down move the model
  picker, right confirms, left cancels) but are ordinary, editable bindings.
- **Edit key values…** and its one-key-at-a-time sheet are gone; **Edit
  controls…** on the dashboard opens the Controls page.
- `config.json` writes are a single atomic read-modify-write that keeps keys the
  Studio does not know about, under a file lock (`config.json.lock`) shared by
  the Studio and the standalone Inspector so their saves cannot interleave.
- The Debug build embeds its Inspector as
  `AbesWorkLouderCreatorMicroStudioInspectorDev.app`, so the Input Monitoring
  list tells the Dev and Stable helpers apart.

### Fixed

- A Release build failed once the Dev Inspector had its own name, because the
  embed phase used the product name from the Debug configuration. It now uses
  a per-configuration path, and the Inspector is no longer installed as a
  second app in archives (`SKIP_INSTALL`).
- When `"10+11"` and `"10"` were both set, which one applied was random. The
  specific id now wins.
- A failed Herdr refresh now marks Herdr unreachable and clears the agent keys
  instead of leaving stale state, and the pad still shows the saved lighting.
  A successful Herdr call no longer clears a device error.
- A race in the Herdr client's request timeout.
- In the Inspector, applying the underglow no longer blanks the keys zone and
  applying the keys zone no longer blanks the underglow.
- Lighting changes to speed or either zone now trigger a repaint.

### Removed

- **GitButler integration.** The Studio is no longer tied to GitButler: the
  GitButler stack and Land branches actions, their floating Stack and Land
  panels and key lights, the `but` binary search and its `WL_BUT_PATH`
  override, and the ANSI renderer used for `but status` output are gone.
- Legacy `"stack"` and `"land"` values in an existing `config.json` are
  ignored rather than rejected: an input still set to one of them falls back
  to its default action (Focus Agent for keys 6 and 8, as before), and the
  rest of the file loads as before.
- The built-in suggested prompt texts for keys 9 and 12 no longer mention
  GitButler or `but`.

## [0.2.0] — not released separately (included in 0.3.1)

### Added

- The Welcome screen shows the app version and build.
- Separate **Stable** and **Dev** apps. Release/Archive builds keep the
  existing bundle IDs, name and icon. Debug builds from Xcode's Run are
  "… Studio Dev" (`dev.abeisonai.worklouder.creatormicrostudio.dev`,
  embedding `dev.abeisonai.worklouder.inspector.dev`) with a DEV-badged icon,
  so their Input Monitoring grant, settings and login item never collide with
  the installed app. `scripts/update-icons.sh` also generates the badged icons,
  and the Run schemes stop both channels' apps before launching.

### Changed

- The menu-bar icon is now a monochrome glyph of the Creator Micro 2 pad from
  the app icon artwork, instead of the generic SF Symbols keyboard. Keys are
  outlined when Studio is off or idle and filled while agents are active, and
  the coloured status dot works as before.

### Fixed

- Every launch brings up the macOS "Keystroke Receiving" request for Studio
  until Input Monitoring is granted, even when the bridge is switched off. The
  standalone Inspector prompted while Studio did not because both make the
  same request, and macOS only shows its sheet while no decision is recorded
  for the bundle ID. When Studio already has a record (a Deny, or a grant for
  an earlier build's signature), it now clears its own record with `tccutil`
  first so the same request shows the sheet again.
- The menu-bar icon now updates with the bridge state. It used to stay frozen
  at launch because the label never observed the bridge.
- Studio starts the bridge at launch rather than only after the menu-bar panel
  was first opened, which had left the pad dark.
- The Welcome screen shows whether Input Monitoring is allowed and offers
  **Request Access** and **Open Settings…**. The bridge keeps retrying, so the pad
  connects once macOS applies the grant (macOS may ask to quit and reopen
  Studio first).
- Emulation mode (`WL_EMULATE=1` / Emulate the pad) no longer prompts for
  Input Monitoring, since the virtual pad needs no HID access.

## [0.1.0]

- First stable release of Creator Micro Studio.
