# App Review notes

Paste the "Notes for the reviewer" section into App Store Connect > App Review Information > Notes.

## Before submitting (owner)

- [ ] Replace `OWNER` in the Support URL (`https://github.com/OWNER/samsung-free-remote-ios-app/issues`) and
      the Privacy Policy URL (`https://OWNER.github.io/samsung-free-remote-ios-app/privacy/`) with the GitHub
      account that hosts the repository, in App Store Connect and in `AppStore/listing.md`.
- [ ] Enable GitHub Pages for the repository (branch `main`, folder `/docs`) and confirm the privacy URL loads.
- [ ] Record the demo video (see below) and replace the VIDEO LINK line.
- [ ] Confirm the multicast networking entitlement is approved and the release build uses
      `App/FreeRemote/FreeRemote+Multicast.entitlements`.

## Notes for the reviewer

Free Remote for Samsung TV is a free, open-source remote control for Samsung Smart TVs.
Works with Samsung Smart TVs running Tizen, 2022 and newer. Many 2018–2021 models also work. It finds TVs on
the local Wi-Fi network and sends the same commands as the TV's physical remote:
power, volume, mute, channel, arrows/OK, Back, Home, Source and HDMI inputs, Play/Pause, number keys and text
entry. There is no account, sign-in, in-app purchase, advertising or analytics.

**Testing requires a Samsung Smart TV running Tizen on the same Wi-Fi network as the iPhone.** Guest or
isolated networks block the connection. The first time the app connects, the TV shows a prompt; choose
"Allow" with the TV remote. Turning the TV on from the app also needs the TV's "Power On with Mobile"
(network standby) setting.

If a TV is not available, a demo video shows the app controlling a real TV:

VIDEO LINK: owner to add

(The app also has a demo mode with a simulated TV, used to produce the screenshots. It is enabled by a
developer launch argument, so it is not reachable from the installed app.)

**Why the app uses Local Network access and the multicast entitlement**

- Local Network permission: the app discovers TVs (Bonjour `_airplay._tcp`, filtered to Samsung devices),
  reads the TV's device information (`http://<tv>:8001/api/v2/`) and sends remote-control commands over an
  encrypted WebSocket (`wss://<tv>:8002`). All traffic stays on the local network; the app only contacts
  private (RFC 1918) or link-local addresses.
- Multicast networking entitlement (`com.apple.developer.networking.multicast`):
  - SSDP discovery: an `M-SEARCH` to the standard multicast group finds Samsung TVs that do not advertise over
    Bonjour.
  - Wake-on-LAN: when the TV is in deep standby and not answering, the app sends a "magic packet" UDP broadcast
    on the local subnet to turn it on.

**Encryption / export compliance**

The app uses only the encryption provided by iOS (standard TLS through the system networking frameworks) to
talk to the TV. It contains no proprietary or non-standard cryptography, so it is exempt;
`ITSAppUsesNonExemptEncryption` is `NO`. (It computes SHA-256 hashes with Apple's CryptoKit to recognise the
TV's certificate, which is authentication, not encryption.)

**Privacy**

No data is collected. TV pairing tokens are stored in the iPhone's Keychain; the list of TVs is stored on the
device; the optional names users give their TVs sync through the user's own iCloud key-value storage.

Not affiliated with or endorsed by Samsung. Samsung and Tizen are trademarks of Samsung Electronics Co., Ltd.
