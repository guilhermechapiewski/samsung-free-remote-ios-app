# Protocol notes

How SamsungTVKit talks to Samsung Tizen TVs, as implemented. Items marked "unverified" have not yet been
confirmed on real hardware; see the checklist at the end.

## Endpoints

- `GET http://<host>:8001/api/v2/` — device info (JSON). Used for discovery, identity and power state.
  Only ever contacted for private (RFC 1918) or link-local IPv4 hosts. Responses are size-capped.
  TV Details also shows its informational fields: `resolution`, `Language`, `countryCode`, `ssid` (the
  access point's BSSID on the TVs seen so far; shown only when it is a MAC), the `*Support` feature flags,
  `developerMode`, `firmwareVersion` (most TVs say "Unknown"; hidden then) and the top-level `version`.
  The model year comes from the `model` code's two-digit prefix ("22_…" is 2022).
  While the app is in front, the app GETs this endpoint for the selected TV every 2 s, connected or not
  (not while pairing). While connected: `standby` means the TV was turned off with its own remote (in network
  standby the WebSocket can stay open), so it is shown as off with only Power usable; two missed answers in
  a row mean it lost power, so the connection is replaced (the transport's 15 s ping would take 15-30 s to
  notice). While not connected, when the TV answers `PowerState: on`, a
  failed session reconnects, and a retry stuck waiting out its backoff (still connecting after 4 checks)
  starts over at once; so a TV that boots late or is turned on with its own remote connects within seconds.
  A `standby` answer only marks the TV asleep; no answer while retrying shows "Couldn't reach the TV"
  instead of "Connecting…". The session's own retries (backoff 0.5 s doubling to 30 s, 5 failures, 5 s
  connect timeout) would otherwise take about 40 s to give up.
- `wss://<host>:8002/api/v2/channels/samsung.remote.control?name=<base64 name>[&token=<token>]` — the
  remote-control channel. The pairing name sent is the constant `TV Remote` (base64 encoded).
  Port 8001 is never used for control.
- SSDP (`M-SEARCH` for `urn:samsung.com:device:RemoteControlReceiver:1` and
  `urn:dial-multiscreen-org:service:dial:1`) and Bonjour (Samsung TXT records) provide candidate hosts;
  every candidate is confirmed with the device-info request before it is reported.

## Device info

Fields used: device id (stable TV identity), name, model name and code, Wi-Fi MAC, network type,
`PowerState` (absent or `on` means on, empty or `standby` means standby, anything else is kept as unknown) and
token-auth support.

## Messages

Events from the TV (JSON with an `event` field): `ms.channel.connect` (optionally carrying a `token`),
`ms.channel.unauthorized`, `ms.channel.timeOut`, `ms.remote.imeStart` (on-screen keyboard shown),
`ms.remote.imeEnd` (hidden). Anything else is reported as an unknown event name.

Commands to the TV are `ms.remote.control` messages with `TypeOfRemote`:
- `SendRemoteKey`: `Cmd` is `Click`, `Press` or `Release`; `DataOfCmd` is the key code (e.g. `KEY_VOLUP`).
- `SendInputString`: `Cmd` is the base64 text, `DataOfCmd` is `base64`.
- `SendInputEnd`: closes the text entry.

## Pairing

1. Connect without a token. The TV shows an "Allow" prompt; the session waits (default 30 s).
2. On `ms.channel.connect` the TV may include a token; it is stored with the pinned certificate.
3. Later connections send the stored token and no prompt appears. `unauthorized` or `timeOut` while
   pairing ends the session as denied or timed out.

## Certificate pinning

TVs use self-signed certificates, so system trust cannot be used and trust is never disabled.
On first connection the SHA-256 of the certificate's SubjectPublicKeyInfo is recorded (trust on first
use) and every later connection must present the same key; a mismatch fails as "identity changed".

## Connection handling

After an established connection drops, the session reconnects with backoff, giving up after a fixed number
of consecutive failures.

## Power logic

State is read from the device-info `PowerState`:
- on: send `KEY_POWER` (turn off), then confirm the state changed.
- standby (or unknown while the TV answers): send `KEY_POWER` over the channel to wake it.
- unreachable: send a Wake-on-LAN magic packet (UDP port 9) from the Wi-Fi interface: unicast to the TV's
  last known address and, with the multicast entitlement, also to the subnet and limited broadcast
  addresses. iOS refuses broadcasts without that entitlement (EHOSTUNREACH); the unicast packet reaches the
  TV only while its hardware address is still in the iPhone's or router's ARP cache.

Key repeat for held keys is `RepeatStrategy`: `.pressRelease` or `.clickEvery(Duration)`; the default is
repeated Click every 150 ms until measured otherwise (unverified).

## To verify on real TVs

Use `tvprobe` (`swift build --product tvprobe`), per model generation:

- [ ] (a) `tvprobe hold <host> KEY_VOLUP 2`: does Press/Release or repeated Click repeat correctly? Set
  `RepeatStrategy.default` accordingly.
- [ ] (b) Which of `KEY_PLAY`, `KEY_PAUSE`, `KEY_PLAY_BACK` toggles playback inside an app?
- [ ] (c) `tvprobe listen <host>` while focusing a search box: record the exact IME event names, then
  check `tvprobe text <host> <string>` fills the box.
- [ ] (d) Put the TV in standby with its remote: record the `PowerState` value from `tvprobe info` per model,
  and whether `KEY_POWER` over the channel wakes it.
- [ ] (e) `KEY_HDMI1` to `KEY_HDMI4`: which switch sources, per model.
- [ ] (f) After about 30 minutes in standby, is the TV still reachable over the network? Does
  `tvprobe wake <mac>` wake it afterwards?
