# Manual test checklist (real devices)

Run before every release on a real iPhone, with the release build you will submit (with or without the
multicast networking entitlement; steps marked **[multicast]** apply only to builds with
`FREE_REMOTE_MULTICAST = YES`, and **[no multicast]** only to builds without it), against every TV model
generation available (ideally one TV per supported year range). Run it once per TV
unless a step says otherwise.

**Record results privately.** Do not commit IP addresses, MAC addresses, serial numbers, device IDs, network
names or TV names. In public notes, refer to TVs only by model year and series.

## Setup

- [ ] Release-configuration build installed on the iPhone; `FREE_REMOTE_MULTICAST` set as intended for this
      release (the build log's `CODE_SIGN_ENTITLEMENTS` line shows which entitlements file was used).
- [ ] iPhone and TVs on the same Wi-Fi network (not a guest network).
- [ ] On each TV, "Power On with Mobile" / network standby is enabled (note the menu path per model).
- [ ] Start clean: delete the app, and remove "TV Remote" (and any older "Free Remote" entry) from each TV's Device Connection Manager.

## Discovery

- [ ] First launch shows the Local Network permission prompt; after allowing it, all TVs that are on appear.
- [ ] **Slow answer to the prompt:** on first launch, wait 10 s before answering the Local Network prompt, then
      Allow → TVs appear without a relaunch.
- [ ] A TV that does not answer SSDP (find via `tvprobe`) is still found (Bonjour or the known-TV probe).
- [ ] A TV in standby that still answers on the network is found and shown as Asleep.
- [ ] "Scan again" refreshes the list; TVs that are on are listed first.
- [ ] Scan Again (TV menu) shows a spinner and "Looking for TVs…" on the TV card with a light tap, then
  "Found N new TVs" or "No new TVs found" with a success tap; the card returns to normal after about 3 s.
  Automatic scans (launch, returning to the app) show none of this.
- [ ] "Add TV by IP…" adds a TV by its address; a public or invalid address is rejected with a message.
- [ ] Relaunching the app shows remembered TVs immediately, including ones that are off (Unreachable/Asleep).

## Pairing

- [ ] Selecting a new TV shows "Look at your TV and choose Allow"; choosing Allow pairs and enables the remote.
- [ ] After relaunching the app, the TV connects without a new prompt.
- [ ] Waiting without answering the prompt ends with a timed-out message and a way to retry.
- [ ] **Pairing denied + recovery:** choose Deny on the TV; the app explains how to re-enable it in the TV's
      Device Connection Manager. Re-enable (or remove the entry) on the TV, retry in the app, choose Allow: pairs.

## Every button

On the TV's home screen and inside a streaming app, each press does what the physical remote does and gives
a haptic tap:

- [ ] Power (see Power below)
- [ ] Source; long-press Source → HDMI 1, 2, 3, 4 (note which work per model)
- [ ] Mute
- [ ] D-pad up, down, left, right, OK
- [ ] Volume up/down, channel up/down
- [ ] Back, Home, Play/Pause (pauses and resumes playback inside an app)
- [ ] "123" sheet: 0–9 change channel on live TV
- [ ] With the TV disconnected, buttons are disabled and show why (not paired / asleep / unreachable).

## Hold-repeat

- [ ] Holding volume up/down repeats steadily and stops immediately on release.
- [ ] Holding channel up/down and each arrow repeats and stops on release.
- [ ] Releasing after the app goes to the background (swipe home while holding) does not leave a key repeating.

## Text entry

- [ ] Focusing a search field on the TV (e.g. in YouTube) opens the keyboard sheet in the app.
- [ ] Typed text appears on the TV; Done/Enter submits; the sheet closes when the TV keyboard closes.

## Power

- [ ] **Power off:** with the TV on, Power shows "Turning off…" and the TV turns off; it never turns a TV on.
- [ ] After turning off with the app, confirm the TV shows Asleep/Off in the picker (not On) — some TVs keep
      the WebSocket open in standby — and the status line says the TV is off (never "Connecting…").
- [ ] **Power on from standby:** within a few minutes of turning it off, Power turns the TV on.
- [ ] **[multicast] Power on from deep sleep:** after the TV has been off for 30+ minutes (no longer answering
      on the network), Power sends Wake-on-LAN and the TV turns on; the app reconnects.
- [ ] **[no multicast] Power on after a short while:** turn the TV off with its own remote, wait until the
      picker shows it Asleep, then press Power within 5 minutes: record whether it turns on (unicast wake).
- [ ] **[no multicast] Power on from deep sleep:** after 30+ minutes off, press Power: record whether it turns
      on. If not, the message must suggest the TV's own remote (never a spinner without an explanation).
- [ ] With "Power On with Mobile" disabled, power-on fails with an explanation of that setting.

## Network changes

- [ ] **IP change:** renew the TV's DHCP lease on the router (or reboot router/TV) so the TV gets a new address;
      the app finds it again as the same TV (same name, still paired, no Allow prompt).
- [ ] **Airplane mode:** turn on airplane mode — the app shows a no Wi-Fi state; turn it off — the app
      reconnects without a relaunch.
- [ ] Background the app for a minute, return: it reconnects promptly.
- [ ] **Local Network denied:** in Settings > Privacy & Security > Local Network, turn TV Remote off; the
      app shows the permission state with a working link to Settings. Turn it back on: discovery works again.

## Names and sync

- [ ] **Rename:** "Rename…" sets a label shown in the picker; the sheet explains renaming in the TV's settings.
- [ ] **Rename sync across devices:** on a second device signed in to the same Apple Account, the new label
      appears (allow time for iCloud). Clearing it on one device clears it on the other.

## Forget

- [ ] "Forget…" asks for confirmation, then removes the TV, its label and its pairing.
- [ ] Scanning again finds the TV as new; selecting it asks for Allow again.

## Accessibility and appearance

- [ ] VoiceOver reads a label for every control; the status line is announced.
- [ ] Largest Dynamic Type size: text stays readable and nothing important is clipped.
- [ ] Light and dark mode both look correct; the app icon shows correctly in light, dark and tinted home
      screen styles.
