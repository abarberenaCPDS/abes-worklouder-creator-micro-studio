# 🎛️ Abe's WorkLouder Creator Micro Studio

*All work & ~~no~~ play*<br>
*Human after all* `¯\_(ツ)_/¯`

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)

A macOS menu-bar app that lights each running [Herdr](https://herdr.dev) agent
on its own key of a Work Louder
**[Creator Micro 2](https://worklouder.cc/creator-micro-2)**, and jumps to that agent
when you press the key.

It is the bridge itself — no Node, no daemon, nothing to install on the Herdr
side. It reads Herdr's socket directly and drives the pad over raw HID.

![Screenshot of Abe's WorkLouder Creator Micro Studio workspace](docs/cover.png)

**[Download the latest release](https://github.com/abarberenaCPDS/abes-worklouder-creator-micro-studio/releases/latest/download/CreatorMicroStudio.zip)**
· [website](https://abarberenacpds.github.io/abes-worklouder-creator-micro-studio/)
· [hacking guide](docs/hacking.md)

---

## 📦 Install

Download, unzip, drag `AbesWorkLouderCreatorMicroStudio.app` to Applications, and launch it. macOS
will ask for **Input Monitoring**. Grant it, then toggle the studio off and on
from the menu-bar panel so it reconnects with the permission.

Or build it from the Xcode project:

```bash
open AbesWorkLouderCreatorMicroStudio.xcodeproj
```

In Xcode, choose **CreatorMicroStudio** and Run. The Inspector is embedded in the
studio app at build time; the separate **Inspector** scheme is also available.

You will also need a Creator Micro 2 and a running Herdr server with agents in
it. Quit Work Louder's Input app and the Codex desktop app while you use this —
all three drive the same lighting and will overwrite each other.

## 🎛️ What the pad does

**The icon** shows state at a glance: dimmed when off, a coloured dot when
running — green all idle, amber something working, red something needs you —
and a badge when the pad is missing or permission is denied.

**The six dedicated agent keys** focus one agent each, in the order Herdr's own
panel lists them. Colours are red (blocked, breathing), amber (working), blue
(done — finished but not yet looked at) and green (idle — finished and seen).
Herdr distinguishes done from idle by whether you have focused the pane yet, so
blue means something is waiting to be read and green means quiet. The
**underglow** carries the worst state across all agents.

Every physical key defaults to **Focus Agent**. Keys 0–5 focus their assigned
agent and bring its terminal forward; the remaining keys return focus to the
agent currently selected in Herdr. Set `WL_TERMINAL_BUNDLE_ID` if your panes do
not live in Ghostty. Use **Edit key values** in Studio to assign any action to
any key:

| action | what it does |
|---|---|
| Focus Agent | focuses the key's assigned agent, or returns to Herdr's current agent |
| GitButler stack | floats the stack for the focused agent |
| Cycle tabs | cycles the tabs of the focused Herdr window |
| Land branches | lands the focused agent's branches, bottom first |
| Prompt Macro | types the key's configured text into the agent's prompt |
| Voice Control | taps right command, unless prompt text is configured for the key |
| Do nothing | leaves the key without an action |

The 10 and 11 keycaps are physically separate and can be configured
independently; either can be assigned Voice Control.

**The dial** tunes reasoning effort. **The joystick** switches model: it puts
the model list on screen, north and south move, east confirms, west cancels.

### 🧩 The stack key

It floats `but status` in the middle of the screen; press again to put it away.
The window never takes focus — you are reading it *from* the terminal you were
already typing in, and a read-only view that steals the keyboard would cost two
keystrokes to undo. Click the output to select text, click anywhere else to
dismiss.

`but` is found by search, not by `PATH`: an app launched by launchd inherits
`/usr/bin:/bin:/usr/sbin:/sbin`, so the binary your terminal finds instantly is
invisible here. Homebrew and Cargo locations are checked directly, then your
login shell is asked. Set `WL_BUT_PATH` to skip all of it.

## 🪟 The panel

Click the menu-bar icon for quick status and controls. **Studio** opens the
full Device First workspace with the larger physical pad map, live agent cards,
and a native sidebar for Studio and Inspector. Click a mapped key or agent row
to focus it. The menu also has the on/off switch, an "Open at login" toggle,
emulation, and a warning when another app is fighting for the device.

**Off** clears the lights and stops driving, but deliberately leaves the device
keymap alone: rebinding is a flash write, and the keys light instantly on the
way back in if the bindings are still there.

The **Welcome** menu item opens the splash page; manual launches show it before
the menu-bar app starts. The splash uses the same locked app icon: Pure Pad
artwork with an `ABE'S` bezel engraving. Studio, standalone Inspector, and the
website favicons use that same artwork.

## 🔍 The Inspector

Choose **Inspector** in the Studio sidebar to view raw device traffic, decode
notifications, and drive per-key lighting, zones, key walks, and raw JSON-RPC
presets. It temporarily takes the pad from the Studio bridge, then returns
control when you navigate back. The **Input Monitoring** sidebar item provides
separate Studio and standalone Inspector permission actions. The standalone
Inspector helper is bundled inside the app, has its own prefixed app name and
bundle ID, and requests its own grant; Studio and the embedded sidebar Inspector
share Studio's grant. macOS may require changing a previously denied grant in
System Settings.

## 🎹 Key values

Choose **Edit key values** in Studio to inspect and change the action associated
with any physical key. This includes the built-in GitButler stack, tab-cycle,
and land commands, agent-focus keys, and macro/voice actions. Prompt text can
also be edited. Every key defaults to **Focus Agent**: keys 0–5 focus their
assigned slot, while other keys return focus to the agent currently selected in
Herdr. Values are saved to `~/.config/creator-micro-studio/config.json`; changes are host-side
and do not rewrite the device keymap or consume flash.

## 🎮 No pad to hand

Tick **Emulate the pad** in the panel and a window opens with a virtual Creator
Micro 2 in it. The bridge drives its lights exactly as it drives the hardware,
and clicking a key — or the dial, or the joystick — sends the same
`v.oai.hid` report back, so the whole loop works with nothing plugged in.

To start with the emulator in Xcode, edit the **CreatorMicroStudio** scheme’s Run
environment variables and set `WL_EMULATE=1`.

It is a stand-in for the firmware rather than a picture of one, and it
reproduces the firmware's more awkward habits deliberately, because those are
the ones that cost time on real hardware:

- it answers `{"ok":1}` to any lighting payload, right or wrong;
- it boots on the **stock F-key keymap**, so the app has to bind the keys
  before anything can light — and a key that is not bound to `KV_OAI_AG*`
  accepts its colour in silence and stays dark;
- an unbound key reports nothing when pressed, because on the pad it would be
  sending a keystroke instead.

The window also shows the RPC traffic, and **Reset** puts a factory pad back.

The emulator lives inside the Studio process. The Inspector sidebar shares that
process; the separately bundled Inspector helper is a different process and
still needs the physical pad.

## ⚙️ Configuration

Everything works without a config file. Studio saves action and prompt overrides
to `config.json` in
`~/.config/creator-micro-studio/`:

```json
{
  "keys": {
    "9":     "Open PRs for all active GitButler branches",
    "12":    "Run but pull",
    "10+11": "Summarise what you are working on"
  },
  "actions": {
    "0": "focus-agent",
    "6": "stack",
    "7": "cycle-tabs",
    "8": "land",
    "9": "macro",
    "10": "voice",
    "11": "voice"
  },
  "claude": { "models": ["fable", "opus"], "efforts": ["low", "high"] },
  "codex":  { "models": ["gpt-5.6-sol", "gpt-5.6-codex"] }
}
```

Existing `~/.config/micromanager/config.json` files are still read when the new
location does not exist.

A bound string is injected into the focused agent's prompt, unsubmitted — you
still read it and press enter. `"10+11"` binds both paired keycaps; `"10"` and
`"11"` address them separately. All 13 keys default to `focus-agent`; action
overrides may assign `focus-agent`, `stack`, `cycle-tabs`, `land`, `macro`,
`voice`, or `none` to any physical key. Empty prompt text clears that key's
suggested or configured text. Configuration changes do not rewrite device flash.

`codex.models` is your copy of what Codex's own `/model` menu offers, in its
order — the joystick steers that menu rather than owning it, so there is nothing
to read it from.

| variable | what it overrides |
|---|---|
| `WL_TERMINAL_BUNDLE_ID` | the terminal to raise (default Ghostty) |
| `WL_BUT_PATH` | the GitButler binary, skipping the search |
| `HERDR_SOCKET_PATH` | the Herdr socket |

## 🔏 Why it must be bundled and signed

Input Monitoring is granted to the app’s code signature. For local development,
Xcode can run the app directly; for a distributable build, use an appropriate
Apple Development or Developer ID signing identity in Xcode. Ad-hoc signing is
useful for local builds, but its identity can change between builds and may
require granting Input Monitoring again. The Xcode archive includes the nested
Inspector app and signs it as part of the host app build.

## 🔌 Only one bridge at a time

Work Louder's Input app and the Codex desktop app drive this same pad. Running
two at once means they overwrite each other. The panel detects this — the device
is opened shared, so we receive other clients' replies, and a response id we
never issued is a reliable tell.

## 🛠️ Development

### 🧑‍💻 Open and run in Xcode

The GUI apps are native Xcode targets; reusable device and integration code is
in a local Swift package. Open the project:

```bash
open AbesWorkLouderCreatorMicroStudio.xcodeproj
```

In Xcode, choose the **CreatorMicroStudio** scheme to run the menu-bar app or
**Inspector** to run the device inspector. To emulate hardware, edit the
CreatorMicroStudio scheme’s Run environment variables and set `WL_EMULATE=1`.

Command-line build and test:

```bash
swift test --package-path Packages/CreatorMicroStudioKit
xcodebuild -project AbesWorkLouderCreatorMicroStudio.xcodeproj -scheme CreatorMicroStudio -destination 'platform=macOS' build
CREATOR_MICRO_STUDIO_LIVE_TESTS=1 swift test --package-path Packages/CreatorMicroStudioKit
./scripts/archive.sh   # create a Release .xcarchive; choose Developer ID to distribute
./scripts/update-icons.sh  # regenerate app icons and website favicons together
```

Tests that access an actual device, Herdr server, or GitButler installation are
skipped unless `CREATOR_MICRO_STUDIO_LIVE_TESTS=1` is set; use that variable only when
you explicitly intend to contact the live integrations.

| | |
|---|---|
| `Apps/CreatorMicroStudio` | menu-bar app target, feature views, resources and app metadata |
| `Apps/Inspector` | standalone inspector app target and resources |
| `Packages/CreatorMicroStudioKit` | device/HID, Herdr, bridge logic and package tests |
| `scripts` | archive and website asset helpers |
| `docs/hacking.md` | how the pad protocol works, and how to drive it yourself |
| `docs/index.html` | the website, served by GitHub Pages from `docs/` |

The device protocol — raw-HID JSON-RPC, per-key colour, key and joystick events,
and the keymap binding that makes per-key lighting possible at all — is written
up in full in **[docs/hacking.md](docs/hacking.md)**.

---

An independent interoperability tool for hardware I own. Not affiliated with
Work Louder.
