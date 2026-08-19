# Research notes

Platform behaviour that shaped micwatch, and the things that cost time to
discover. Nothing here is needed to use the app — see [README.md](README.md) for
that.

## How detection works

Two CoreAudio layers, because neither alone is sufficient.

**Devices tell you *when*.** A listener on
`kAudioDevicePropertyDeviceIsRunningSomewhere` fires whenever an input device
starts or stops. There are only a handful of input devices, so the bookkeeping is
small, and a second listener on `kAudioHardwarePropertyDevices` catches hardware
appearing and disappearing (Bluetooth headphones connecting mid-call).

**Processes tell you *who*.** `kAudioHardwarePropertyProcessObjectList` plus
`kAudioProcessPropertyIsRunningInput` names the app holding the mic. This is
scanned on demand when a device event says something changed.

Idle cost is essentially zero: no polling, no timers, nothing runs until the
audio hardware changes state. A 5-minute backstop poll exists purely as insurance
against a listener going quiet.

### Process-level properties accept listeners and never fire

Registering on `kAudioProcessPropertyIsRunning`, `IsRunningInput` or `Devices`
returns `noErr` and then silently never notifies. Verified with 117 listeners
across 39 process objects while holding the mic open: only the device-level
property delivered anything. The headers document the property *values* and say
nothing about notification support, so this is only discoverable by trying it.

**In CoreAudio, "the read works" does not imply "the listener works."**

This is also why detection needs both layers. Devices notify but can't say which
app; processes name the app but can't tell you when.

### Poll versus listeners is a battery question, not a CPU one

Measured side by side against a 0.5s polling build: the polling version
accumulated idle wakeups continuously and about 0.06s of CPU per minute —
roughly 30 seconds of CPU over a working day, entirely to discover that nothing
changed. The listener version sits at the backstop timer's rate.

Idle wakeups, not CPU time, are what macOS counts as energy impact.

**Timer coalescing makes short intervals disproportionately expensive.** A 60s
timer usually rides a wake that was happening anyway and costs nothing; a 0.5s
timer can't be coalesced and forces a real wake almost every time. Measured
across four windows, a 60s backstop cost between 0 and 5 wakeups per 3 minutes
depending on how busy the machine already was.

### Electron and Chromium hold the mic in a helper process

A Slack huddle surfaces as `com.tinyspeck.slackmacgap.helper`, which macOS
doesn't consider an app, so `NSRunningApplication` returns nil. Walking up the
parent chain to the first ancestor that *is* an app gives "Slack". The same
applies to Chrome tabs and Zoom.

`NSRunningApplication` also only knows about processes LaunchServices launched,
so a bundle started directly from a shell has no `localizedName` despite having
a perfectly good one in its `Info.plist`. Name resolution therefore runs four
deep: `localizedName`, then `CFBundleDisplayName`/`CFBundleName` from the
process's own bundle, then the parent walk, then the bundle id.

### `kAudioProcessPropertyBundleID` is returned at +1

The header says the caller must release it. Bridging it straight to `CFString?`
leaks one string per call, and this runs for every audio process on every mic
event. Take it as `Unmanaged` and call `takeRetainedValue()`.

### Reading these properties requires an unsandboxed process

In a sandbox the device enumeration silently returns an empty list rather than
failing, which looks exactly like "no microphones are in use".

## Home network gate

The network is identified by the **default gateway's MAC address**
(`route -n get default`, then `arp -n`).

This is deliberately not the Wi-Fi SSID. Reading the SSID requires the
`com.apple.developer.networking.wifi-info` entitlement, which needs a paid Apple
Developer Program membership, *plus* Location Services authorization — a location
permission prompt on a menu bar app that has nothing to do with location. The
gateway MAC needs no entitlement and no permission at all, and identifies your
specific router rather than a name like `linksys` that every café reuses.

## Credentials

The token lives in `~/.config/micwatch-token`, mode `0600`, not in the Keychain.

A Keychain item's ACL grants silent access only to the code identity that created
it, which is exactly the property you'd want for a long-lived credential — any
other app asking triggers an approval prompt. But the item also records a
*cdhash* per build. macOS reconciles that automatically for apps signed with
**Developer ID** or distributed through the App Store; for a self-signed
certificate it does not, so every rebuild prompts for the login password again no
matter how stable the designated requirement is. Apple's own guidance is to move
to Developer ID rather than work around it.

That leaves a locally-built app paying for the protection on every rebuild and
not receiving it. A `0600` file is honest about what it protects: other users on
the machine, not other code running as you. If this app were ever signed with a
Developer ID certificate, the Keychain would become the better home again.

Two related traps, if you go that route: keychain ACLs identify a trusted
application by **executable path**, so a loose binary beside the bundle is a
separate application needing its own approval; and the documented way to preserve
an ACL when changing a stored secret is `SecItemUpdate` **in place**, because
deleting and re-adding the item discards it.

## Signing

`./build.sh --create-identity` creates a self-signed code signing certificate in
a keychain of its own, which locks on sleep and after an hour idle, and trusts it
for code signing on this machine. Builds sign with it, so the app has a stable
identity — which matters for launch-at-login and for macOS remembering
microphone permission across rebuilds.

Traps worth knowing:

- Homebrew's OpenSSL 3 writes PKCS12 archives that Apple's Security framework
  rejects outright (`MAC verification failed`). Use the system LibreSSL at
  `/usr/bin/openssl`.
- A self-signed certificate is untrusted by default, which makes
  `security find-identity -v` hide it and `codesign` refuse it.
  `security add-trusted-cert` is required.
- `security import -T` doesn't set the key's **partition list**, without which
  every build prompts for a password.
- `codesign` resolves identities through the keychain **search list**, so
  `--keychain` alone reports "no identity found". A locked keychain doesn't
  prompt during signing either — it reports the same thing, because the
  certificate stays readable while the private key doesn't.

## Menu bar and overlay

**Hover detection polls `NSEvent.mouseLocation`** rather than using a tracking
area or a global event monitor. `NSStatusBarButton` does its own tracking for
highlighting and doesn't deliver `mouseEntered` to another owner; a global
`mouseMoved` monitor didn't fire either. Mouse position needs no Accessibility
permission — only key events do — so the problem was event delivery, not
entitlements. Asking where the pointer is has nothing in between to fail. The
poll only runs while something is paused.

**Menu items are built once and mutated in place.** Removing and re-adding them
inside `menuNeedsUpdate` leaves the first display sized for a different set of
items, which shows as a gap at the bottom of the menu.

**A two-line menu item can't be aligned by hand.** An attributed string with
per-line paragraph styles, a sub-pixel indent for the larger glyph's side
bearing, and a padded image canvas to lift the icon onto the first line were all
approximating something AppKit does correctly for a plain single-line title.

**SwiftUI state must not be published during a view update.** A `@Published`
property initialised by a function that shells out — `gatewayMAC()` — runs while
`@StateObject` is being constructed inside `body`, which re-enters layout and
trips an `AttributeGraph` precondition, aborting the process. The crash log's own
frames name the culprit; guessing at which publish looked suspicious does not.
