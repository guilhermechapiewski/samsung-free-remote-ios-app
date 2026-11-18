# Samsung TV Remote for iPhone — Design

Date: 2026-11-18
Status: Draft for owner approval

## 1. Intent

A free iPhone app on the App Store that replaces the physical Samsung TV
remote. It should feel like Apple's TV Remote app: open it, and every Samsung
TV on the Wi-Fi network appears in a picker at the top; choose one and control
it. Source code is public on the owner's GitHub so others can contribute, but
almost all users will only ever see the App Store listing — so the app must
work with zero setup, no accounts, and no knowledge of networking.

Success: on the owner's three TVs, the app finds every TV that is on or in
network standby, pairs once per TV, and then every button responds instantly
and reliably, including turning the TV on.

## 2. Goals, non-goals, anti-goals

**Goals (v1)**
- Automatic discovery of Samsung TVs on the local network; a picker to choose one.
- Remembering TVs between launches (including while they are asleep/unreachable).
- User-assigned labels per TV, synced via iCloud across the user's own devices.
- Every everyday function of the physical remote: power on/off, volume up/down,
  mute, channel up/down, arrows + OK, Back, Home, Source (input) menu, direct
  HDMI 1–4, play/pause, number keys, text entry into TV text fields.
- One-time pairing per TV per iPhone (TV shows "Allow"; app stores the token).
- Robust, fast, secure, well tested.

**Non-goals (v1; possible later)**
- SmartThings / Samsung account / any cloud control (owner decided: local only now, evaluate later).
- Renaming the TV itself. No local API exists; the app shows the name the TV
  reports and explains how to rename it in the TV's own Settings so everyone sees it.
- iPhone hardware volume buttons controlling the TV. No supported API outside
  an active camera session; workarounds risk App Store rejection.
- Native iPad layout (iPad users can run the iPhone app). Mac, Watch, widgets,
  Control Center controls, Siri/Shortcuts, Live Activities.
- Voice control, casting/screen mirroring, app launcher grid, touchpad mode.
- TVs older than 2016 (non-Tizen) or non-Samsung TVs.
- Localization beyond English (strings are still externalized so it's easy later).

**Anti-goals (would be a failure even if it "works")**
- Any data leaving the local network: no analytics, ads, tracking, crash
  uploaders, or third-party SDKs.
- Disabling TLS certificate checks ("trust anything") to talk to the TV.
- A button that silently does nothing. Every press either works or the user
  sees why not (asleep, not paired, unreachable).
- Accidentally turning a TV *on* when the user meant off (or vice versa) because
  of a stale power state.
- Requiring any account or setup beyond the TV's one-time "Allow".

## 3. Constraints

- iOS 27 only; iPhone only (`TARGETED_DEVICE_FAMILY = 1`). Xcode 27.2 available.
- Swift 6 language mode with strict concurrency; SwiftUI; Observation (`@Observable`).
- No third-party dependencies (Apple frameworks only).
- Distributed free on the App Store under the owner's paid developer account.
- Requires the `com.apple.developer.networking.multicast` entitlement (for SSDP
  discovery and Wake-on-LAN broadcast). Must be requested by the Apple developer
  **Account Holder** and approved by Apple. Until approval, the app must still
  work using Bonjour discovery and direct-wake-from-standby (see §6.4); the
  multicast features are enabled behind the entitlement and degrade gracefully.
  **Owner decision: the first App Store release waits for this approval**, so
  Wake-on-LAN power-on is a v1 requirement. The owner (Account Holder) files
  the request at the very start of the project; the graceful fallback still
  exists (development builds, or if Apple ever revokes it) but is not the
  release path.
- Local Network privacy permission is required (`NSLocalNetworkUsageDescription`,
  `NSBonjourServices = [_airplay._tcp]`).
- Public GitHub repo: no secrets in the repo, ever.
- **Works on any user's network.** Nothing about the owner's network (IPs,
  subnet, TV ids/names/models, SSIDs) may appear in app code or configuration.
  The broadcast address for Wake-on-LAN is computed from the active Wi-Fi
  interface's address and netmask (never assume 192.168.1.x or /24); discovery
  never relies on a fixed IP range; behaviour must not depend on the specific
  model strings seen in §4. The owner's network data appears only in this doc
  and in anonymised test fixtures (ids/MACs/serials replaced).
- Signing: Apple Developer Team ID `2JNHX2X73J` (owner's paid account). Kept in
  a git-ignored `Config/Local.xcconfig`, with a committed
  `Local.example.xcconfig` so contributors can sign with their own team.

## 4. Owner's TVs (test fleet, scanned 2026-11-18)

| Reported name | Model | Year / platform | IP (DHCP) | Notes |
|---|---|---|---|---|
| `85&quot; Micro RGB` | MRN85R95HAFXZA (Micro RGB R95H) | 2026, `26_RSM_MTV` | 192.168.1.94 | Wi-Fi. Reported `PowerState: ""` while asleep, `"on"` when on. Answers SSDP. |
| `Samsung QN90BA 85` | QN85QN90BAFXZA (Neo QLED QN90B) | 2022, `22_PONTUSM_QTV` | 192.168.1.238 | Wi-Fi. **Did not answer SSDP** in two scans; found via AirPlay Bonjour and port 8001. |
| `65&quot; The Terrace` | QN65LST9DAFXZA (The Terrace outdoor) | 2024, `24_PONTUSM_QTV_LTR` | 192.168.1.114 | Wi-Fi. Answers SSDP. |

All three: Tizen, `TokenAuthSupport: true`, ports 8001 and 8002 open,
`remote_available: true`, AirPlay advertised with `manufacturer=Samsung`.
Names arrive HTML-entity-encoded and must be decoded.

## 5. Approaches considered

- **A. Apple frameworks only, implemented from scratch (chosen by owner).**
  Network.framework / URLSession for SSDP, Bonjour, REST, secure WebSocket;
  Keychain for secrets. Zero supply-chain risk, readable for contributors,
  full control over TLS pinning. More upfront work, but the protocol is small.
- **B. Existing open-source Swift Samsung library.** Faster start, but the known
  libraries are small hobby projects that typically disable TLS validation and
  lack tests; we'd own their bugs and rewrite most of it.
- **C. Samsung Smart View SDK.** Abandoned, not maintained for current iOS,
  aimed at casting rather than remote control. Ruled out.

Remote screen layouts considered (mockups shown): A Apple-style touchpad,
B classic remote, C hybrid with switchable centre. **Owner chose B, no changes.**

## 6. Design

### 6.1 Architecture

Two modules in one Xcode project:

- **`SamsungTVKit`** (local Swift package, no UI, fully unit-testable):
  discovery, device info, pairing/session, key commands, text input, wake,
  persistence protocols. Public API is `async`/`Sendable`; actors own mutable
  network state.
- **App target** (SwiftUI): screens, view models (`@Observable`, `@MainActor`),
  persistence implementations (Keychain, iCloud KVS, file store), haptics.

Every network boundary sits behind a small protocol (e.g. `TVInfoFetching`,
`RemoteChannel`, `DatagramSender`, `ServiceBrowser`) so tests substitute fakes.

### 6.2 Discovery

Run these concurrently whenever the picker is visible or the app comes to the
foreground, and merge results:

1. **Bonjour**: `NWBrowser` for `_airplay._tcp`; keep results whose TXT
   `manufacturer` is `Samsung`; resolve to an IP. (Needs no multicast
   entitlement. This is what found the QN90B.)
2. **SSDP** (requires multicast entitlement): M-SEARCH for
   `urn:samsung.com:device:RemoteControlReceiver:1` and
   `urn:dial-multiscreen-org:service:dial:1`, sent 2–3 times; collect responders' IPs.
3. **Known TVs**: probe each remembered TV's last IP directly.

Every candidate IP is **verified** with `GET http://<ip>:8001/api/v2/`
(short timeout, response size cap, strict JSON decoding). Only responses with
`device.type == "Samsung SmartTV"` and `device.OS == "Tizen"` count. The TV's
stable identity is `device.id` (UUID); IP is just the current address. Results
are deduplicated by id; a known TV whose IP changed is updated in place.

Captured per TV: id, IP, `name` (entity-decoded), `modelName`, `model`,
`wifiMac` (needed for Wake-on-LAN), `networkType`, `PowerState`, `TokenAuthSupport`.

A **manual "Add TV by IP address"** entry in the picker is the last-resort
fallback for unusual networks (my call — cheap and saves support issues).

### 6.3 Pairing and the control channel

- The name sent to the TV (shown in its Allow prompt and Device Connection
  Manager) is a **fixed constant, `Free Remote`**, deliberately independent of
  the App Store display name, so renaming the app later never forces users
  to re-pair.

- Connect only via **`wss://<ip>:8002/api/v2/channels/samsung.remote.control`**
  with query `name=<base64(app display name)>` and, once paired, `token=<token>`.
  Port 8001 (unencrypted WebSocket) is never used for control; port 8001 HTTP
  is used only for the read-only info endpoint above.
- **TLS**: the TV presents a self-signed certificate. Use
  **trust-on-first-use pinning**: on first pairing, record the SHA-256 of the
  leaf certificate's public key, stored with the token. Later connections must
  match; on mismatch, refuse and ask the user to re-pair (explaining the TV's
  security identity changed, e.g. after a firmware update).
- First connection: TV shows "Allow/Deny". Show an in-app "Look at your TV and
  choose Allow" state with a timeout (~30 s). Handle events:
  `ms.channel.connect` (store `data.token` if present → paired),
  `ms.channel.unauthorized` (user denied → explain how to re-enable in the TV's
  Device Connection Manager), `ms.channel.timeout`.
- Token + pin stored in **Keychain**, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
  keyed by TV id. Not synced (each iPhone pairs separately).
- Session lifecycle: connect when a TV is selected and the app is active;
  close on background; reconnect immediately on foreground; reconnect with
  capped exponential backoff on drop. Keep-alive via WebSocket ping.

### 6.4 Commands

Key presses: `{"method":"ms.remote.control","params":{"Cmd":"Click","DataOfCmd":"KEY_X","Option":"false","TypeOfRemote":"SendRemoteKey"}}`.
Hold-to-repeat (volume, channel, arrows) uses `Press` on touch-down and
`Release` on touch-up where the TV supports it, otherwise repeated `Click` at a
fixed interval; the builder verifies which behaves better on the test fleet.

| Button | Key |
|---|---|
| Arrows / OK | KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_ENTER |
| Back, Home | KEY_RETURN, KEY_HOME |
| Volume, Mute | KEY_VOLUP, KEY_VOLDOWN, KEY_MUTE |
| Channel | KEY_CHUP, KEY_CHDOWN |
| Source | KEY_SOURCE; long-press → menu of HDMI 1–4 (KEY_HDMI1…4) |
| Play/Pause | KEY_PLAY / KEY_PAUSE (builder confirms the best toggle on the fleet) |
| Numbers | KEY_0…KEY_9 (in the "123" sheet) |
| Power | see below |

**Power** (state-aware to meet the anti-goal):
- Refresh info first (≤1 s). If `PowerState == "on"` → send KEY_POWER (off).
- If the TV answers but is not "on" (standby, e.g. `""`/`"standby"`) → send
  KEY_POWER over the channel to wake it.
- If the TV does not answer → **Wake-on-LAN**: magic packet (6×0xFF + 16×MAC)
  to UDP port 9 on the subnet broadcast address and 255.255.255.255, sent a
  few times (needs multicast entitlement), then poll the info endpoint until it
  reports "on" (~20 s timeout) and reconnect.
- UI shows "Turning on…" / "Turning off…" progress; on failure, explain the
  "Power On with Mobile" / network standby setting on the TV.

**Text entry**: when the TV signals an on-screen keyboard (`ms.remote.imeStart`),
the app offers a keyboard field and sends text via `SendInputString`
(base64), with Enter/Done. Builder verifies event names on the fleet.

### 6.5 Persistence

- **Known TVs** (id, last IP, MAC, model info, reported name, last seen):
  JSON file in Application Support, written atomically.
- **Labels**: `NSUbiquitousKeyValueStore` keyed by TV id (iCloud sync across
  the user's devices; works locally without iCloud).
- **Secrets**: Keychain only (see 6.3).
- Last selected TV id: `UserDefaults`.
- "Forget this TV" removes all of the above for that id.

### 6.6 UI (layout B — classic remote)

Single main screen, dark-first, follows system appearance:

- **Top: TV picker** — shows label (or reported name), status dot + text
  (On / Asleep / Unreachable / Pairing). Tap → menu: list of TVs (online first),
  "Rename…", "Forget…", "Add TV by IP…", "Scan again".
- Row: **Power** (red), **Source** (long-press for HDMI 1–4), **Mute**.
- **Circular D-pad** with OK in the centre.
- Bottom: **VOL rocker** (left), Back / Home / Play-Pause / 123 (centre),
  **CH rocker** (right).
- "123" opens a sheet with a number pad. Keyboard field appears when the TV
  requests text.
- Haptic tap on every press. Buttons disabled with a clear reason when not
  connected.
- **Empty / error states**: no Wi-Fi; Local Network permission denied (with
  link to Settings); searching; no TVs found (tips: same Wi-Fi, TV on, Power
  On with Mobile); pairing; pairing denied; TV security identity changed.
- **Rename** sheet: edits the label only, with a note "To change the name
  everyone sees, rename the TV in its Settings → General → Device Name"
  (wording verified/adjusted per model).
- Accessibility: every control has a VoiceOver label and hint; supports
  Dynamic Type for text; contrast meets WCAG AA.

### 6.7 Security and privacy

- ATS: `NSAllowsLocalNetworking` only (for the HTTP info endpoint on the LAN).
- All control traffic over TLS with TOFU pinning (6.3). No `trust all`.
- Only connect to RFC1918 / link-local addresses (rejects manual entry or
  discovery results outside the local network).
- Defensive parsing: size limits on HTTP/WebSocket/SSDP payloads, timeouts on
  every network call, no force unwraps on network data.
- No logging of tokens; `os.Logger` with private redaction for IPs/MACs.
- App Privacy label: "Data Not Collected".

### 6.8 Testing

- **Swift Testing** for `SamsungTVKit`: message encoding/decoding (fixtures from
  the real TVs' JSON above), HTML-entity name decoding, SSDP response parsing,
  Bonjour TXT filtering, discovery merge/dedupe/IP-change logic, magic packet
  bytes, power decision logic (every state → expected action), pairing state
  machine (connect, unauthorized, timeout, pin mismatch), reconnect/backoff
  (with an injected clock).
- **Integration tests**: an in-process fake TV (Network.framework listener with
  a self-signed TLS identity) implementing the info endpoint and WebSocket
  channel, to exercise real sockets end-to-end, including pin mismatch.
- **App**: view-model tests with fake kit; a small set of UI tests for the
  main flows (empty state, pick TV, rename) using a fake environment.
- **Manual test checklist** run on the three real TVs before each release
  (discovery, pairing, every button, power on from standby and from deep
  sleep, IP change, denied pairing).
- CI: GitHub Actions running build + tests on macOS (builder picks the runner
  image that has Xcode 27).

### 6.9 App Store listing (deliverable)

The repo includes `AppStore/listing.md` with the App Store copy, kept in sync
with what the app actually supports: name, subtitle, promotional text,
description, keywords, privacy answers ("Data Not Collected"), review notes
for Apple (how to test without a Samsung TV, why the multicast and Local
Network permissions are needed), and an explicit **Requirements** section:
- Samsung Smart TV running Tizen, 2016 or newer — tested on 2022, 2024 and
  2026 models; final wording is set from manual testing (if anything older than
  2022 can't be verified, say "tested on 2022 and newer").
- iPhone and TV on the same Wi-Fi/local network; no guest/isolated networks.
- Allow the app on the TV the first time ("Allow" prompt).
- For power-on: the TV's "Power On with Mobile" / network standby setting enabled.
- Local Network permission granted on the iPhone.
- Not affiliated with Samsung (trademark disclaimer); the app name must not
  lead with "Samsung" (App Review trademark rules).

### 6.10 Submission readiness (in scope; owner presses Submit)

- Privacy policy page (states no data is collected) hosted free on GitHub
  Pages from the repo; its URL goes in App Store Connect.
- App Review notes: what the app does, that a Samsung TV on the same network
  is needed, why Local Network and multicast are used, plus a short demo video
  link if reviewers can't test (owner records it).
- Export compliance: uses only standard OS-provided TLS → `ITSAppUsesNonExemptEncryption = NO`.
- Age rating answers (4+), category (Utilities), screenshots generated from the
  simulator at required iPhone sizes using a demo mode with a fake TV.
- App icon (original artwork; no Samsung logo or likeness).

### 6.11 Repository

- README (what it is, privacy stance, how to build, how to contribute),
  **MIT** LICENSE, CONTRIBUTING, issue templates, `.gitignore`.
- No secrets: signing team set via a local, git-ignored xcconfig.

## 7. Decided by the owner

- App Store distribution, free; source on GitHub for contributors.
- Request the multicast entitlement.
- Local only; SmartThings evaluated later.
- Approach A (Apple frameworks only).
- iPhone only; iOS 27 only.
- Remote layout B (classic), no changes.
- App name: **Free Remote for Samsung TV**.
- Release waits for multicast entitlement approval (owner files the request first).
- Scope runs through submission-ready; owner presses Submit.
- License: MIT.
- Must work on any user's network; nothing hardcoded to the owner's network.
- App Store listing with an explicit requirements section.

## 7a. Calls made by the designer (owner can override)

- Bundle ID `com.chapiewski.FreeRemote` (set in the git-ignored xcconfig, so a
  wrong guess is a one-line change before the first App Store Connect record).
- Manual "Add TV by IP" fallback; TOFU certificate pinning; tokens not synced.
- Hardware volume buttons dropped (no supported API).
- Testing on the real TVs is done by the builder from the owner's Mac on the
  same network; the owner only presses **Allow** on each TV once.

## 8. Left to the builder

Exact SwiftUI composition and styling within layout B; Press/Release vs repeated
Click; play/pause key choice; IME event handling details; timeouts and backoff
constants; project/file structure within the two modules; CI runner image.
