# Code signing, permissions, and local deployment

How code signing affects the Studio and Inspector apps, why macOS sometimes
"forgets" a permission, and the steps for developing and installing the apps
on your own Mac.

---

## 1. Why signing matters here

Studio needs two macOS privacy grants:

| Grant | Needed for | System Settings → Privacy & Security |
|---|---|---|
| **Input Monitoring** (`ListenEvent`) | reading the pad over HID | Input Monitoring |
| **Accessibility** | system actions: scroll, keyboard shortcuts, media keys, typing, Voice | Accessibility — called **Device Control and Data Access** on newer macOS |

macOS keeps one record per app for each grant. A record holds:

1. the app's **bundle ID** (for example `dev.abeisonai.worklouder.creatormicrostudio`), and
2. the app's **designated requirement**, a rule taken from its code signature
   that says which builds count as "the same app".

When the app runs, macOS checks both. A matching bundle ID with a signature
that no longer satisfies the stored requirement counts as a *different app*.
The grant then silently stops applying, and macOS does not show its
"Keystroke Receiving" sheet again because a record already exists. That is the
"Review needed, but nothing prompts" state.

### Ad-hoc signing vs. a development certificate

| Signing | Designated requirement | Effect on grants |
|---|---|---|
| **Ad-hoc** ("Sign to Run Locally", no team) | the exact binary hash (`cdhash H"…"`) | **Every rebuild is a new app.** Grants break after each build. |
| **Apple Development** (a team selected) | your certificate + bundle ID | Grants survive rebuilds of the same bundle ID. |
| **Developer ID** (for others) | your Developer ID certificate + bundle ID | Same as above, and Gatekeeper accepts it on other Macs once notarized. |

Today the project uses **Automatic** signing with no team, so builds are ad-hoc.
Selecting a team (section 3) fixes this.

Check what a build is signed with:

```bash
codesign -dr - /path/to/AbesWorkLouderCreatorMicroStudio.app
# ad-hoc:          designated => cdhash H"…"
# with a team:     designated => identifier "dev.abeisonai…" and anchor apple generic and certificate leaf[subject.OU] = …
codesign --verify --deep --strict --verbose=2 /path/to/AbesWorkLouderCreatorMicroStudio.app
```

---

## 2. Stable and Dev apps

The project builds two separate apps. macOS treats them as unrelated, so
each has its own grants, preferences and login item:

| | **Stable** (Release / Archive) | **Dev** (Debug / Xcode ▶ Run) |
|---|---|---|
| Studio app | `AbesWorkLouderCreatorMicroStudio.app` | `AbesWorkLouderCreatorMicroStudioDev.app` |
| Studio bundle ID | `dev.abeisonai.worklouder.creatormicrostudio` | `dev.abeisonai.worklouder.creatormicrostudio.dev` |
| Embedded Inspector bundle ID | `dev.abeisonai.worklouder.inspector` | `dev.abeisonai.worklouder.inspector.dev` |
| Icon | app icon | app icon with a **DEV** badge |
| Where it lives | `/Applications` | Xcode's DerivedData build folder |
| Hardened runtime | on | off |

Each one asks for its permissions once. The embedded Inspector is a separate
app, so it needs its own Input Monitoring grant as well. Only one copy can drive
the pad at a time. The Xcode Run step quits the others before it launches.

Changing a bundle ID resets that app's grants, so avoid it.

---

## 3. One-time setup: choose a signing team

Do this once in Xcode, using your own Apple ID. A free Apple account is enough
for local development.

1. **Xcode → Settings → Accounts**: make sure your Apple ID is listed. If it
   isn't, add it with **+**.
2. Open `AbesWorkLouderCreatorMicroStudio.xcodeproj` and select the project in
   the navigator.
3. For **each target**, **CreatorMicroStudio** and **Inspector**:
   **Signing & Capabilities** → leave **Automatically manage signing** on →
   set **Team** to your team.
   - Use the **same team for both targets**. The Inspector is embedded and
     signed as part of Studio.
   - Check both the **Debug** and **Release** columns if the tab shows them.
4. Xcode stores this as `DEVELOPMENT_TEAM = <TEAMID>` in `project.pbxproj`.
   That file is committed, so the setting is shared with anyone who builds from
   this repo. Keep it, or set it again on each machine.

This Mac has two Apple Development certificates in its keychain. Pick the team
that belongs to the Apple ID you want these apps tied to, and keep using it. If
you switch teams later, the designated requirement changes and you have to grant
the permissions again once.

List the signing identities available:

```bash
security find-identity -v -p codesigning
```

> Text in parentheses in a certificate name is the certificate's user ID, not
> always the Team ID. Choose the team from Xcode's **Team** menu, not from that
> string.

After switching from ad-hoc to a team, the existing grant records belong to the
old ad-hoc signature. Reset them once (section 5), then grant again.

---

## 4. Everyday workflows (local only)

### Develop (Dev app)

1. In Xcode choose the **CreatorMicroStudio** scheme and press **▶ Run**. This
   builds and launches **…Studio Dev**.
2. On first run, macOS shows the "Keystroke Receiving" sheet for the Dev app.
   Choose **Open System Settings** and turn **AbesWorkLouderCreatorMicroStudioDev**
   on. Do the same for Accessibility if you use system actions.
3. No pad? Set `WL_EMULATE=1` in the scheme's Run environment.

With a team selected, rebuilding keeps the grants.

### Install or update the Stable app on this Mac

1. Quit the running Stable Studio (menu-bar icon → Quit) and any Dev copy.
2. Build an archive:
   ```bash
   ./scripts/archive.sh
   # → .build/archives/AbesWorkLouderCreatorMicroStudio.xcarchive
   ```
   Or in Xcode: **Product → Archive**.
3. Get the app out of the archive. Either:
   - **Organizer → Distribute App → Custom → Copy App**, or
   - copy it straight from the archive:
     ```bash
     ditto ".build/archives/AbesWorkLouderCreatorMicroStudio.xcarchive/Products/Applications/AbesWorkLouderCreatorMicroStudio.app" \
           "/Applications/AbesWorkLouderCreatorMicroStudio.app"
     ```
     `ditto` replaces the old copy in place and keeps the signature intact.
4. Launch it from `/Applications`. If the team hasn't changed since the last
   install, the grants still apply. Otherwise macOS asks again.

Keep the Stable app in one location (`/Applications`). macOS also notes where an
app lives, and a second copy elsewhere is easy to confuse with it.

### Version numbers

`MARKETING_VERSION` (semver) and `CURRENT_PROJECT_VERSION` (build number) are set
in the project and listed in `CHANGELOG.md`. The Welcome page shows the running
version and adds "· Dev" for the Dev app.

---

## 5. Troubleshooting

**The Input Monitoring helper**

**Request Access** (Welcome window, menu-bar panel, the Studio's Input
Monitoring page, and the dashboard's **Permission needed** button) clears the
app's own record if it is a Deny, asks macOS through IOHID and CoreGraphics,
and briefly creates a listen-only key event tap that is never enabled. That
attempt is what makes macOS evaluate the app and list it in Input Monitoring.
If after about two seconds neither a grant nor the system sheet has appeared,
the **Input Monitoring helper** opens. **Show me how…** opens it directly.

The helper shows exactly which app to allow: icon, display name, **Stable** or
**Dev**, file name (`AbesWorkLouderCreatorMicroStudio.app` or
`…StudioDev.app`), the folder it runs from (for the Dev app that is a
DerivedData folder, which is why it is hard to find in the **+** dialog), and
the bundle ID. **Reveal in Finder** selects the app so you can drag it into the
list; **Copy Path** copies the full path, which you can paste with ⇧⌘G in the
**+** dialog. **Quit & Reopen** relaunches the same bundle (`/usr/bin/open` on
its path a second after the app quits): macOS caches a running process's
decision, so a new grant often only applies to a fresh process. The status line
turns green as soon as macOS reports the grant.

The Controls page has the same helper for **Accessibility** (shown as
**Device Control and Data Access** on newer macOS). Its sheet appears when an
action first posts an event or when you click **Request access**.

**"Review needed" / no prompt appears / pad stays dark**

The grant record is stale: it was made by a different signature or denied
earlier. Reset only that app's record, then launch it again. Studio also does
this for itself when it isn't granted.

```bash
# Input Monitoring
tccutil reset ListenEvent dev.abeisonai.worklouder.creatormicrostudio        # Stable Studio
tccutil reset ListenEvent dev.abeisonai.worklouder.inspector                 # Stable Inspector
tccutil reset ListenEvent dev.abeisonai.worklouder.creatormicrostudio.dev    # Dev Studio
tccutil reset ListenEvent dev.abeisonai.worklouder.inspector.dev             # Dev Inspector

# Accessibility (system actions)
tccutil reset Accessibility dev.abeisonai.worklouder.creatormicrostudio
```

Each command clears only the named app. Don't run `tccutil reset ListenEvent`
without a bundle ID: that resets every app on the Mac.

**Granted in System Settings but still no pad**

macOS may say the app must quit before the change takes effect. Choose
**Quit & Reopen**, or quit it from the menu bar and launch it again.

**Two entries that look alike in Input Monitoring**

The Stable and Dev apps are separate entries on purpose: the Dev one is
`…StudioDev.app` / `…InspectorDev.app`. Remove stale entries with **−** and grant
again.

**Grant keeps breaking after every build**

The build is ad-hoc signed. Check with `codesign -dr -` (section 1) and choose a
team (section 3).

**"Unable to re-register with Process Instance Registry … com.apple.linkd.autoShortcut" in the Xcode console**

Harmless. It comes from linkd, the App Intents / Shortcuts daemon, during debug
runs, and has nothing to do with privacy grants. The app does not use or link
App Intents (the build log says “Metadata extraction skipped, no
AppIntents.framework dependency found”), so there is nothing to fix.

---

## 6. Later: sharing the app with other Macs

Local development and installing on your own Mac don't need any of this. To give
the app to someone else without Gatekeeper warnings you need:

1. a paid Apple Developer Program membership and a **Developer ID Application**
   certificate,
2. an archive exported with **Distribute App → Direct Distribution** (Developer
   ID), with hardened runtime on (Release already sets it), and
3. **notarization** (Xcode does this as part of Direct Distribution) and stapling.

The bundle IDs and the Stable/Dev split stay the same.
