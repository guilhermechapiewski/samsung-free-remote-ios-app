---
title: Privacy Policy
---

# Privacy Policy — Free Remote for Samsung TV

Effective date: 18 November 2026

Free Remote for Samsung TV ("the app") is a free, open-source iPhone app that controls Samsung Smart TVs on
your local network. **The app does not collect any data.**

## What the app does not do

- It does not collect, store on any server, sell or share any personal information or usage data.
- It contains no analytics, advertising, tracking or crash-reporting code, and no third-party SDKs.
- It does not require an account or sign-in.
- It never sends anything to the developer or to any internet service.

## Network use

The app talks only to TVs on your own local network (private or link-local addresses). It uses your local
network to find TVs, read their device information, send remote-control commands over an encrypted connection,
and, if you turn a TV on, send a Wake-on-LAN packet on your local network. This is why iOS asks for Local
Network permission. None of this traffic leaves your network.

## Data kept on your iPhone

To work, the app keeps a small amount of information on your device only:

- **Your TVs**: each TV's identifier, network address, hardware (MAC) address used to wake it, model and
  name, so the app can find it again. Stored in the app's private storage on your iPhone.
- **Pairing**: the access token the TV issues when you choose "Allow", and a fingerprint of the TV's security
  certificate. Stored in the iPhone's Keychain, on this device only.
- **The TV you used last**, so the app opens on it.

## iCloud

If you give a TV your own name, that name is saved in your personal iCloud key-value storage so it appears on
your other devices signed in to the same Apple Account. This uses Apple's iCloud service under your Apple
Account; the developer cannot see it. If iCloud is off, names are kept on the device only.

## Deleting your data

Use "Forget this TV" in the app to remove a TV, its pairing and its name. Deleting the app removes everything
it stored on the device. You can also remove the pairing on the TV in its Device Connection Manager settings.

## Children

The app is suitable for all ages and collects no information from anyone, including children.

## Changes

If this policy changes, the updated version will be published at this address with a new effective date. The
app's source code, including this policy's history, is public on GitHub.

## Contact

Questions about privacy: open an issue in the app's GitHub repository.

Not affiliated with or endorsed by Samsung. Samsung and Tizen are trademarks of Samsung Electronics Co., Ltd.
