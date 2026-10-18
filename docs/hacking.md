# Hacking the Work Louder Creator Micro 2

A step-by-step guide to driving the pad from your own code: setting individual
key colours, reading key presses back, and using the dial and joystick as
inputs. No Work Louder software involved — this talks to the firmware directly.

Everything here is verified on a
**[Creator Micro 2](https://worklouder.cc/creator-micro-2), firmware v0.6.0-rc.10**,
over USB and Bluetooth, on macOS. Examples are Node with
[`node-hid`](https://github.com/node-hid/node-hid); the same protocol is
implemented in Swift/IOKit in `Packages/CreatorMicroStudioKit/Sources/CreatorMicroStudioKit/Device/`, which is what the app itself
uses.

> **The one thing to know before you start.** The firmware answers `{"ok":1}` to
> almost any payload, including malformed ones. A wrong shape looks exactly like
> a right one. The only ground truth is the LEDs. Budget for that.

---

## Contents

1. [What you need](#1-what-you-need)
2. [Find the interface](#2-find-the-interface)
3. [The wire format](#3-the-wire-format)
4. [A minimal transport](#4-a-minimal-transport)
5. [First contact](#5-first-contact)
6. [Zone lighting: the easy win](#6-zone-lighting-the-easy-win)
7. [The keymap prerequisite](#7-the-keymap-prerequisite)
8. [Per-key colour](#8-per-key-colour)
9. [Key events](#9-key-events)
10. [The dial and the joystick](#10-the-dial-and-the-joystick)
11. [Turning everything off](#11-turning-everything-off)
12. [Reference](#12-reference)
13. [Traps](#13-traps)

---

## 1. What you need

- A Work Louder pad on vendor id `0x303A`. This guide is written for the
  Creator Micro 2 (`0x8297` / `0x8298`); the transport is shared with the other
  boards this firmware family covers.
- Node 18+ and `npm install node-hid`.
- **macOS: Input Monitoring** for whatever process runs your code — System
  Settings → Privacy & Security → Input Monitoring. Add your terminal while you
  are developing. Without it, opening the interface fails with `privilege
  violation`.
- **Linux:** a udev rule granting access to the `303a:` HID device.
- Quit Work Louder's Input app and the Codex desktop app first. Both drive this
  same pad and will fight you for it.

---

## 2. Find the interface

The pad presents several HID collections. You want the **vendor** one: usage
page `0xFF00`, usage `1`. That is where the JSON-RPC channel lives.

```js
const HID = require("node-hid");
const info = HID.devices().find(
  (d) => d.vendorId === 0x303a && d.usagePage === 0xff00 && d.usage === 1,
);
console.log(info);
```

Two things that will bite you if you skip them:

**Open non-exclusively.** hidapi seizes the device by default. This pad puts its
vendor collection on the same underlying device as a *keyboard* collection, and
macOS refuses to let anything seize a keyboard. A seizing open fails with
`0xE00002C1`, which reads exactly like a missing permission and is not.

```js
const hid = new HID.HID(info.path, { nonExclusive: true });
```

**Match on the usage pair, not the primary usage.** Over Bluetooth the pad is a
*single* device whose primary usage is keyboard (`usagePage 1, usage 6`), with
the vendor collection listed alongside in its usage pairs. Over USB each
interface is its own device, so picking the first vendor-id match lands you on
the keyboard and every write is silently dropped. `node-hid`'s `devices()` list
is already flattened per usage pair, so the filter above is correct; if you use
IOKit directly, check `DeviceUsagePairs` — see `WLDevice.hasVendorCollection` in
`Packages/CreatorMicroStudioKit/Sources/CreatorMicroStudioKit/Device/WLDevice.swift`.

---

## 3. The wire format

JSON-RPC 2.0, carried over 64-byte raw HID reports:

```
byte 0      report id, always 0x06
byte 1      channel: 1 = firmware debug log, 2 = JSON-RPC
byte 2      payload length in THIS report, max 61
bytes 3..   UTF-8 fragment of the JSON message
```

A message longer than 61 bytes is split across as many reports as it needs.
There is no sequence number and no end marker — you reassemble the incoming
stream by **scanning for balanced top-level braces**.

Requests look like `{"method": "...", "params": ..., "id": 42}`. Two rules:

- **Call ids must be under 1000.** The firmware rejects anything larger.
- **Responses and notifications use different envelopes.** A response carries
  `method`/`params` and an `id`. A device-pushed notification carries
  **`m`/`p`** and *no* id. Match only on `method` and every key press vanishes
  silently — this is the single most common way to conclude the keys are inert
  when they are not.

Colours go on the wire as a packed `0xRRGGBB` integer. `brightness`, `speed` and
`magic` are floats in `0..1`.

---

## 4. A minimal transport

Save this as `wl.js`. It is about 90 lines and is all you need for everything
below. (The production version, with reconnect handling and a fake-device mode,
is `Packages/CreatorMicroStudioKit/Sources/CreatorMicroStudioKit/Device/WLDevice.swift`, in Swift.)

```js
"use strict";
// wl.js - minimal Work Louder raw-HID JSON-RPC transport.
const HID = require("node-hid");

const VID = 0x303a, USAGE_PAGE = 0xff00, USAGE = 1;
const REPORT_ID = 0x06, CH_DEBUG = 1, CH_RPC = 2, CHUNK = 61;

function open() {
  const info = HID.devices().find(
    (d) => d.vendorId === VID && d.usagePage === USAGE_PAGE && d.usage === USAGE,
  );
  if (!info) throw new Error("no Work Louder vendor interface found");

  // nonExclusive is required: the vendor collection shares a device with a
  // keyboard collection, and macOS refuses to let anyone seize a keyboard.
  const hid = new HID.HID(info.path, { nonExclusive: true });

  const pending = new Map();
  let accum = "";
  const bus = { info, hid, onNotify: null, onLog: null, call, close };

  hid.on("data", (buf) => {
    // node-hid may or may not include the report id as byte 0.
    for (const off of [1, 0]) {
      const channel = buf[off], len = buf[off + 1];
      if (channel !== CH_DEBUG && channel !== CH_RPC) continue;
      if (len === undefined || len > CHUNK) continue;
      const text = buf.slice(off + 2, off + 2 + len).toString("utf8");
      if (channel === CH_DEBUG) { if (bus.onLog) bus.onLog(text); return; }
      accum += text;
      for (const obj of drain()) dispatch(obj);
      return;
    }
  });

  // Pull complete top-level JSON objects out of the accumulator. Brace counting
  // has to skip over strings: keymap.json arrives as a JSON string full of them.
  function drain() {
    const out = [];
    let depth = 0, start = -1, inStr = false, esc = false;
    for (let i = 0; i < accum.length; i++) {
      const c = accum[i];
      if (inStr) {
        if (esc) esc = false;
        else if (c === "\\") esc = true;
        else if (c === '"') inStr = false;
        continue;
      }
      if (c === '"') inStr = true;
      else if (c === "{") { if (depth++ === 0) start = i; }
      else if (c === "}" && depth > 0 && --depth === 0) {
        try { out.push(JSON.parse(accum.slice(start, i + 1))); } catch {}
        accum = accum.slice(i + 1);
        i = -1; start = -1;
      }
    }
    if (accum.length > 8192) accum = "";
    return out;
  }

  function dispatch(obj) {
    // Notifications use the abbreviated envelope {m, p}; responses use `method`.
    const method = obj.m !== undefined ? obj.m : obj.method;
    if (method !== undefined && obj.id === undefined) {
      if (bus.onNotify) bus.onNotify(method, obj.m !== undefined ? obj.p : obj.params);
      return;
    }
    const waiting = pending.get(obj.id);
    if (!waiting) return;          // a reply to an id we never sent: another client
    pending.delete(obj.id);
    clearTimeout(waiting.timer);
    if (obj.error) waiting.reject(new Error(obj.error.message || "rpc error"));
    else waiting.resolve(obj.result);
  }

  function call(method, params = null) {
    const id = Math.floor(Math.random() * 999);   // firmware rejects ids >= 1000
    const payload = Buffer.from(JSON.stringify({ method, params, id }), "utf8");
    for (let off = 0; off < payload.length; off += CHUNK) {
      const n = Math.min(CHUNK, payload.length - off);
      const report = Buffer.alloc(64);
      report[0] = REPORT_ID;
      report[1] = CH_RPC;
      report[2] = n;
      payload.copy(report, 3, off, off + n);
      hid.write(Array.from(report));
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`timeout waiting for ${method}`));
      }, 8000);
      pending.set(id, { resolve, reject, timer });
    });
  }

  function close() { try { hid.close(); } catch {} }

  return bus;
}

module.exports = { open };
```

---

## 5. First contact

```js
const { open } = require("./wl.js");

(async () => {
  const dev = open();
  console.log("device:", dev.info.product);
  console.log("firmware:", await dev.call("sys.version"));
  console.log("status:", await dev.call("device.status"));
  console.log("files:", await dev.call("fs.list", { checksum: false, rec: true }));
  dev.close();
})();
```

`sys.version` returns `{"version": "v0.6.0-rc.10"}`. `device.status` carries
`battery`, `is_charging` and `layer_index` among others. If all three answer,
your transport is correct and everything else is payload shape.

A method the firmware does not register answers **`Method not found`** — which
is genuinely useful, because it distinguishes "this variant doesn't have it"
from "I sent the wrong shape". Use it to probe the firmware you actually have.

---

## 6. Zone lighting: the easy win

Before per-key, get the two whole-device *zones* working. There are two:
`keys` (the plate under the keycaps) and `ambient` (the underglow).

```js
const GREEN = 0x00c853;
const zone = (color, effect = 1) => ({ e: effect, b: 1, s: 0.5, m: 1, c: color });

await dev.call("v.oai.rgbcfg", {
  keys:    zone(0, 0),        // effect 0 = off
  ambient: zone(GREEN),       // effect 1 = solid
});
```

Note the **abbreviated field names** — `e` effect, `b` brightness, `s` speed,
`m` magic, `c` colour — and that **`e` is a number**, not a string. This is the
part that silently no-ops if you get it wrong.

There is also an older `lights.preview` taking `backlight` and `underglow` with
*full* field names and *string* effects. It is what Work Louder's own Input app
uses. It works, but it cannot address individual keys, so it is a dead end for
anything interesting:

```js
await dev.call("lights.preview", {
  underglow: { effect: "solid", brightness: 1, speed: 0.5, magic: 1, color: GREEN },
});
```

---

## 7. The keymap prerequisite

**A key can only be lit individually if it is bound to a `KV_OAI_AG*` keycode on
the active layer.** This is the gate that makes per-key colour look impossible
until you find it. Nothing reports the mismatch: per-key calls still answer
`{"ok":1}` for a key that cannot light. Parking the codes on a spare layer does
nothing — it must be the *active* layer.

The trade-off is real and worth understanding before you do it: **an AG-bound
key stops sending its keystroke.** It does not go silent, though — it reports
itself over HID instead (see [§9](#9-key-events)), so it becomes a status light
*and* an input. Bind only the keys you intend to own.

### The keymap file

The device stores its configuration as `keymap.json`, read and written over the
same RPC channel. It is **double-encoded**: `fs.read` returns `{"data": "<a JSON
string>"}` where the inner string is the real config.

```js
const raw = await dev.call("fs.read", { file: "keymap.json" });
const config = JSON.parse(raw.data);
```

The shape you care about, from a stock Creator Micro 2:

```jsonc
{
  "activeProfileId": 0,
  "profiles": [{
    "layers": [{
      "layout": {
        // Rows are [2, 4, 4, 3]. Key index is row-major from 0.
        "keymap": [
          ["KC_F13", "KC_F14"],
          ["KC_F15", "KC_F16", "KC_F17", "KC_F18"],
          ["KC_F19", "KC_F20", "KC_F21", "KC_F22"],
          ["KC_F23", "KC_NONE", "KC_F24"]
        ],
        "encoders": [["KC_VOLU", "KC_VOLD", "KC_MPLY"]],   // [CW, CCW, press]
        "joystick": {
          "type": "RADIAL",
          "sectors": [
            { "k": "KI_X",  "a1": 0.1875, "a2": 0.3125 },
            { "k": "KC_P1", "a1": 0.3125, "a2": 0.4375 }
            // ...8 sectors in all
          ]
        }
      }
    }]
  }]
}
```

`layer_index` from `device.status` is 1-based against the `layers` list, so the
active layer is `layers[0]`.

### Back it up first

```js
require("fs").writeFileSync("keymap-backup.json", JSON.stringify(raw));
```

Keep it. Restoring is just writing that same `data` string back.

### Bind some keys

Read, modify, write, then **read back and verify** — the write is accepted
whether or not it took.

```js
// Bind key 3 (row 1, column 1) so it can be lit.
const layer = config.profiles[config.activeProfileId ?? 0].layers[0];
layer.layout.keymap[1][1] = "KV_OAI_AG03";

await dev.call("fs.write", { file: "keymap.json", data: JSON.stringify(config) });

const after = JSON.parse((await dev.call("fs.read", { file: "keymap.json" })).data);
console.log(after.profiles[0].layers[0].layout.keymap);
```

Key *N* takes keycode `KV_OAI_AG` + zero-padded *N* — key 3 is `KV_OAI_AG03`.
The mapping is positional, so write per key rather than per row unless you mean
to take a whole row's keycodes with it.

> This is a **flash write**. Do it once at startup when something has actually
> changed, not in a loop.

**Timing.** A whole `keymap.json` is ~2.5 KB of JSON, about 45 reports. Over
Bluetooth LE each `SetReport` waits for an acknowledgement, so just sending it
can take a few seconds, and then the firmware parses the file and writes
flash. Start the reply timeout only once the last report is written (the
Studio's `WLDevice` does, and gives `fs.write` 30 s and `fs.read` 15 s), and
treat a write that times out as *unknown*, not failed: the pad may still be
writing. Wait a moment (~750 ms) before the read-back and read again if it
does not match yet. Do not send lighting while the write is in flight.

### Geometry

The matrix is `[2, 4, 4, 3]` and the key index runs row-major from 0. One
surprise: **the top row is wired right to left**, so index 0 is the top-**right**
key.

```
 [DIAL]  [ 1 ] [ 0 ]  [JOYSTICK]   top controls plus reversed key row
         [ 2 ] [ 3 ] [ 4 ] [ 5 ]
         [ 6 ] [ 7 ] [ 8 ] [ 9 ]
 [MARK]  [10 ] [11 ] [12 ]
```

The dial, joystick and circular case mark are not key-matrix entries. The
physical key matrix remains `[2, 4, 4, 3]`; row 0 is wired right to left, so
key 0 is the right-hand top key. The bottom row has three separate keycaps.
Keys 10 and 11 are paired for the default voice action, but each can be bound
or lit independently. The stock map leaves 11 as `KC_NONE` until it is bound.

---

## 8. Per-key colour

This is the payoff. The method is `v.oai.thstatus`, and each key is a "thread".

**Params are a bare ARRAY**, not an object — one entry per key you want to
change:

```js
// Key 3, solid red, full brightness.
await dev.call("v.oai.thstatus", [
  { id: 3, c: 0xff0000, b: 1, e: 1, s: 0.5 },
]);
```

That is the whole trick. Three keys, three colours:

```js
await dev.call("v.oai.thstatus", [
  { id: 0, c: 0xff2d2d, b: 1, e: 4, s: 0.5 },   // red, breathing
  { id: 1, c: 0xffaa00, b: 1, e: 1, s: 0.5 },   // amber, solid
  { id: 2, c: 0x00c853, b: 1, e: 1, s: 0.5 },   // green, solid
]);
```

Fields, all optional except `id` — **omitted fields leave that aspect
unchanged on the device**:

| field | meaning |
|---|---|
| `id`  | key index, 0-based, row-major (required) |
| `c`   | packed `0xRRGGBB` integer |
| `b`   | brightness, `0..1` |
| `e`   | effect **as a number** (see table below) |
| `s`   | speed, `0..1` |
| `sk`  | `1`/`0` — mirror this thread onto the keys zone |
| `sa`  | `1`/`0` — mirror this thread onto the ambient zone |

Effects are the firmware's own set:

| value | effect | value | effect |
|---|---|---|---|
| 0 | off     | 4 | breathing |
| 1 | solid   | 5 | gradient |
| 2 | snake   | 6 | shallow breath |
| 3 | rainbow |   | |

Each key can carry its **own** effect, not just its own colour — one key
breathing while its neighbours sit solid works fine.

**Thread state paints over zone state.** A key with a thread colour ignores the
`keys` zone; the zone only shows through where no thread colour is set. That is
also why turning the pad off takes two calls — see [§11](#11-turning-everything-off).

### Prove it with a walk

The test that settles whether an index really maps to the physical key you
think it does: light one key at a time and watch it move.

```js
for (let id = 0; id <= 12; id++) {
  const threads = Array.from({ length: 13 }, (_, i) => ({
    id: i, c: i === id ? 0x00ff00 : 0, b: i === id ? 1 : 0, e: i === id ? 1 : 0,
  }));
  await dev.call("v.oai.thstatus", threads);
  await new Promise((r) => setTimeout(r, 400));
}
```

If a key stays dark while the rest walk past it, that key is not AG-bound on the
active layer. Go back to [§7](#7-the-keymap-prerequisite).

---

## 9. Key events

An AG-bound key sends no keystroke, but it reports itself as a **notification**:

```json
{"m": "v.oai.hid", "p": {"k": "AG01", "act": 1}}
```

- `k` — the key name, `AG00`..`AG19`. The number is the key index, the same one
  you use as a thread id.
- `act` — `1` on press, `0` on release.
- `ag` — an agent field belonging to the Codex firmware's own agent-key
  feature. `OAI.agIndex` in `Packages/CreatorMicroStudioKit/Sources/CreatorMicroStudioKit/Device/OAIProtocol.swift` ignores it, and
  nothing here depends on it.

Remember the envelope is `m`/`p`, not `method`/`params`.

```js
const dev = open();
dev.onNotify = (method, params) => {
  if (method !== "v.oai.hid") return;
  const match = /^AG(\d+)$/.exec(params.k || "");
  if (!match) return;
  const index = Number(match[1]);
  console.log(`key ${index} ${params.act === 1 ? "pressed" : "released"}`);
};
// keep the process alive
setInterval(() => {}, 1 << 30);
```

So a single key is both a lamp and a button: light it with thread `id`, and it
answers on the same index. That is what makes "the key you look at is the key
you press" work.

---

## 10. The dial and the joystick

Neither has an LED, but both can be turned into the same clean `v.oai.hid`
events as the keys — which is usually what you want, because you get discrete,
debounced signals instead of a raw stream to threshold yourself.

### The dial

`layout.encoders` is a list of `[clockwise, counter-clockwise, press]`. Bind
the two rotation slots, and the press if you want it too:

```js
layer.layout.encoders[0][0] = "KV_OAI_AG13";   // CW
layer.layout.encoders[0][1] = "KV_OAI_AG14";   // CCW
layer.layout.encoders[0][2] = "KV_OAI_AG19";   // press
```

Each detent now arrives as `AG13` / `AG14`, and a click as `AG19`, through the
same notification handler. There is nothing at index 13/14/19 to light — these
ids are inputs only.

Abe's WorkLouder Creator Micro Studio binds all three. Binding the press takes
away the stock `KC_MPLY` keystroke, so the Studio's default action for the dial
push is a host-side Play/Pause media key — the click behaves as before, but it
can be remapped. Unlike the firmware's `KC_MPLY`, that media key is a
synthesised `CGEvent`, so it needs the **Accessibility** permission for the
Studio and only works while the Studio bridge is running; the Controls page
marks the dial push accordingly. Set the dial push to `none` (or any action
that posts no system event) to avoid the grant. A pad bound by an earlier build gets exactly one more keymap
write (read → check → write → read back) the first time this build connects.
AG19 is the last free id, so the joystick diagonals and its centre press stay
unbound: there is no id left for them, and the keymap schema has no slot for a
centre press at all.

**AG19 on the press is best-effort.** It has not been confirmed that every
firmware keeps `KV_OAI_AG19` as a keymap keycode in `encoders[0][2]` (the docs
only say the thread-id table runs to AG19), and the firmware answers
`{"ok":1}` to writes it ignores. So the Studio checks in two tiers:

- **Core** — keys `AG00`–`AG12`, rotations `AG13`/`AG14`, cardinals
  `AG15`–`AG18`. Without these the pad does not light or report, which is an
  error.
- **Dial push** — `AG19`. Missing after a write means this firmware keeps its
  own code (stock `KC_MPLY`, so the click still plays/pauses on its own). That
  is not an error: the Studio records it for that `sys.version` on the Mac
  (UserDefaults, never on the pad), stops counting the push as needing
  Accessibility, and the Controls page's dial push row says it is unavailable,
  with **Retry dial push binding**.

At most two writes per connection: the full keymap with AG19, and only if the
*core* then fails to read back, one fallback written without AG19 (the press
slot left as read). If the core still does not stick, that refusal is recorded
too and the Studio stops writing on later launches until **Retry binding**.
A Bluetooth reconnect within the same run never writes once the outcome is
known.

### The joystick

The joystick is radial: eight sectors, each with an angle range `a1..a2`
expressed as a **fraction of a full turn**, where **0 is east and the angle
increases counter-clockwise**.

| sector centre | direction | stock keycode |
|---|---|---|
| 0.000 | east  | `KC_P6` |
| 0.125 | NE    | `KC_P7` |
| 0.250 | north | `KI_X`  |
| 0.375 | NW    | `KC_P1` |
| 0.500 | west  | `KC_P2` |
| 0.625 | SW    | `KC_P3` |
| 0.750 | south | `KC_P4` |
| 0.875 | SE    | `KC_P5` |

Bind whichever you want. Match on the sector's centre rather than its bounds —
the east sector wraps through zero (`a1: 0.9375, a2: 0.0625`), so a naive
midpoint gives you 0.5 instead of 0.0:

```js
const centre = (a1, a2) => ((a2 >= a1 ? (a1 + a2) / 2 : (a1 + a2 + 1) / 2) % 1);
const cardinals = { 0.25: "KV_OAI_AG15",   // north
                    0.50: "KV_OAI_AG16",   // west
                    0.75: "KV_OAI_AG17",   // south
                    0.00: "KV_OAI_AG18" }; // east

for (const sector of layer.layout.joystick.sectors) {
  const c = centre(sector.a1, sector.a2);
  const hit = Object.keys(cardinals).find((k) => Math.abs(Number(k) - c) < 0.01);
  if (hit) sector.k = cardinals[hit];
}
```

Deflections now arrive as `AG15`–`AG18`.

### Raw joystick position

The device also pushes a continuous radial notification:

```json
{"m": "v.oai.rad", "p": {"a": 0.25, "d": 0.8}}
```

`a` is the angle on the same 0..1 scale, `d` the distance from centre, 0..1.
Use this if you want analogue position rather than four discrete directions —
you handle your own deadzone and repeat-rate. The sector-binding route above is
the easier one and is what Abe's WorkLouder Creator Micro Studio uses; the Inspector decodes and logs
`v.oai.rad` if you want to watch it.

---

## 11. Turning everything off

Clearing the zones is **not** enough — thread state overrides them, so the keys
stay lit. Clear both. The firmware's keycode table runs to `AG19`, so clear the
whole id space rather than just the 13 visible keys:

```js
const dark = { e: 0, b: 0, s: 0.5, m: 1, c: 0 };

await dev.call(
  "v.oai.thstatus",
  Array.from({ length: 20 }, (_, id) => ({ id, b: 0, e: 0, sk: 0, sa: 0 })),
);
await dev.call("v.oai.rgbcfg", { keys: dark, ambient: dark });
```

---

## 12. Reference

### Methods

| method | direction | purpose |
|---|---|---|
| `sys.version` | call | firmware version |
| `device.status` | call | battery, charging, active layer index |
| `fs.list` | call | list device files — `{checksum: false, rec: true}` |
| `fs.read` | call | read a file — `{file: "keymap.json"}` |
| `fs.write` | call | write a file — `{file, data}`, flash write |
| `v.oai.thstatus` | call | **per-key lighting**, params are a bare array |
| `v.oai.rgbcfg` | call | zone lighting — `{keys, ambient}` |
| `lights.preview` | call | legacy two-surface lighting — `{backlight, underglow}` |
| `host.focused_app` | call | tell the device which app has focus |
| `v.oai.hid` | **notify** | key press/release — `{k, act, ag}` |
| `v.oai.rad` | **notify** | joystick position — `{a, d}` |

The two notification names are *not* callable; calling them returns `Method not
found`, which is correct and not a sign of trouble.

### AG keycodes

| keycode | what it addresses |
|---|---|
| `KV_OAI_AG00`–`KV_OAI_AG12` | the 13 keys, in matrix order |
| `KV_OAI_AG13` / `KV_OAI_AG14` | dial clockwise / counter-clockwise |
| `KV_OAI_AG15`–`KV_OAI_AG18` | joystick north / west / south / east |
| `KV_OAI_AG19` | dial press — also the table's limit; clear this far when blanking |

### Field-name cheatsheet

`v.oai.*` uses abbreviated names and numeric effects. `lights.preview` uses full
names and string effects. Mixing them is the classic silent failure.

| | `v.oai.rgbcfg` / `thstatus` | `lights.preview` |
|---|---|---|
| colour | `c` (int) | `color` (int) |
| brightness | `b` | `brightness` |
| effect | `e` (**number**) | `effect` (**string**) |
| speed | `s` | `speed` |
| magic | `m` | `magic` |
| sections | `keys`, `ambient` | `backlight`, `underglow` |

---

## 13. Traps

Collected from the time each one cost.

**`{"ok":1}` means nothing.** The firmware accepts any payload, including
malformed ones, and returns success. Verify against the LEDs.

**Matching on `method` drops every key event.** Notifications use `m`/`p`.

**A key that is not AG-bound on the *active* layer cannot be lit,** and nothing
tells you. Threads for it still return `{"ok":1}`.

**Thread colour overrides zone colour.** Zones only show through where no thread
colour is set, and "all off" needs both cleared.

**Call ids must be under 1000.**

**Effects are integers in `v.oai.*`.** Passing `"solid"` is accepted and does
nothing.

**Open non-exclusively,** or macOS refuses with `0xE00002C1` — which looks
exactly like a permission problem and is not.

**If you use IOKit directly, hold the `IOHIDManager`** for the lifetime of the
connection. Let it go out of scope and the devices it opened are torn down with
it; every later `IOHIDDeviceSetReport` fails with `kIOReturnNotOpen`
(`0xE00002CD`) even though the open reported success.

**You are not the only client.** Opening shared means you also receive *other*
applications' responses. A response carrying an id you never issued is a
reliable tell that something else is driving the pad — Work Louder's Input app
and the Codex desktop app both do.

**Variant gating is real.** These vendor methods are registered per hardware
variant. If `v.oai.thstatus` returns `Method not found` rather than `{"ok":1}`,
this firmware genuinely does not have it. Older Creator Micro 2 firmware
(v0.4.0, v0.6.0-rc.8) registered the methods as no-op stubs — accepted
everything, lit nothing. `docs/per-key-rgb-investigation.md` is the write-up
from before it worked, kept because the elimination process is the useful part.

---

## Where the working code lives

| | |
|---|---|
| `lib/wl-device.js` | the transport, production version |
| `lib/oai.js` | the vendor lighting API and notification decoding |
| `lib/keymap.js` | reading, checking and writing the keymap |
| `bin/probe.js` | which methods this firmware actually registers |
| `bin/interactive-lab.js` | 12 lighting experiments, prompting after each |
| `bin/lights-off.js` | the two-call blanking above |
| `Packages/CreatorMicroStudioKit/Sources/CreatorMicroStudioKit/Device/` | the same protocol in Swift/IOKit |
| `Apps/Inspector/` | a GUI for watching traffic and driving lights by hand |

`WLInspector` is the fastest way to try a payload shape: it has a raw JSON-RPC
panel with presets, and logs every message in both directions with the
notifications decoded.

Whatever the Inspector paints is temporary: the pad keeps no lighting state of
its own, so Studio's next repaint replaces it. Its **Save to Studio** buttons
copy the selected keys' look, the underglow or the keys zone into the
`"lighting"` section of Studio's `config.json`, which Studio reloads when it
takes the pad back (and its Lighting page whenever it appears or the app
becomes active). Both apps do every write as a read-modify-write under an
advisory `flock` on `config.json.lock` next to the file, and Studio's Lighting
saves only write the fields edited there, so neither app's save drops the
other's. Nothing the Inspector saves is written to the device.

Open `AbesWorkLouderCreatorMicroStudio.xcodeproj`, choose the **Inspector** scheme, then Run. For
hardware access, grant Input Monitoring to the app/process macOS identifies.

Run it from a terminal that already has Input Monitoring — macOS attributes the
grant to the responsible process, so a binary launched from Finder will be
refused.
