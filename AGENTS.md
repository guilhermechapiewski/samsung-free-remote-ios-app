# Notes for coding agents

Simple Remote for Samsung TV: a free, open-source iPhone app (iOS 27+, iPhone only) that finds Samsung Tizen TVs
on the local network and controls them like the physical remote. Read `README.md` for the overview and
`CONTRIBUTING.md` for the full ground rules; this file is the short version plus what agents tend to miss.

## Maintainer context

If you have access to the maintainer's private companion repository (it sits next to this one on the
maintainer's machines), read its `HANDOFF.md` first. It has the project status, the owner's decisions,
pending work and the build history. Its contents are private: never copy anything from it into this
repository, issues or pull requests.

## Hard rules

- **This repository is public.** Never commit personal or network data: IP or MAC addresses, device ids,
  serial numbers, TV or Wi-Fi names, Team ID, real bundle identifier, certificates. Signing settings go in the
  git-ignored `Config/Local.xcconfig`. Fixtures use placeholders (`192.0.2.x`, or `10.0.0.x` where a private
  address is required, made-up MACs, fictional names). If a privacy-check script was provided to you, run it on
  your staged changes before every commit and never bypass it.
- **Must work on any user's network.** Nothing may assume a subnet, address, TV model or name.
- **Apple frameworks only.** No Swift packages, CocoaPods or SDKs; no analytics, ads, tracking or crash
  uploaders; no traffic beyond the local network.
- **Security.** Only private (RFC 1918) or link-local IPv4 hosts are contacted (`LocalAddress.isAllowed`).
  Never disable TLS trust checks; the control channel is `wss://<tv>:8002` with trust-on-first-use pinning.
  Never log tokens; log hosts and MACs with `privacy: .private`. No force unwraps on network data.
- **Swift 6, complete strict concurrency, no warnings.** No `@unchecked Sendable` without a comment proving it
  is safe.
- **Test-first** with Swift Testing (`import Testing`, `@Test`, `#expect`). Protocol and networking logic lives in
  `SamsungTVKit` with unit tests; keep the app layer thin.

## Build and test

```sh
swift test --package-path SamsungTVKit

xcodebuild test -project SamsungRemote.xcodeproj -scheme SamsungRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' -parallel-testing-enabled NO
```

- Use `OS=27.0`: newer simulator runtimes may not have that device. Keep `-parallel-testing-enabled NO`
  (parallel simulator clones were measured slower for the UI tests).
- While iterating, add `-only-testing:SamsungRemoteTests` to run only the app's unit tests (under a second after
  the build); the UI tests take about two minutes, so run them before committing. Each UI test launches the
  app, so extend an existing flow rather than adding a test per check.
- `ScreenshotTests` skip unless `scripts/screenshots.sh` runs them.
- The kit's integration tests run a fake TV on fixed ports 8001/8002 on 127.0.0.1; they fail if something else
  uses those ports.
- `swift run --package-path SamsungTVKit tvprobe` is a command-line probe for real TVs. Pairing pops an Allow
  prompt on the TV, so only pair with a TV whose owner is present and expecting it.

## Multicast entitlement

`SAMSUNG_REMOTE_MULTICAST` (`YES`/`NO`, default `NO`, set in `Config/Local.xcconfig`) selects the entitlements
file and tells the app (Info.plist `SRMulticastEnabled`) whether SSDP discovery and broadcast Wake-on-LAN are
available. Never set `SAMSUNG_REMOTE_ENTITLEMENTS` directly; the "Check entitlements" build phase fails the build
if the two disagree. Without the entitlement the app uses Bonjour discovery and a unicast wake packet. Leave it `NO`;
only the maintainer's builds can use `YES`. See `docs/protocol-notes.md`.

## When behaviour changes

Update `docs/protocol-notes.md` for real-TV protocol findings, and `README.md` when user-facing features or
requirements change; say so in your summary. Releases, store listings and anything else about publishing are
handled privately by the maintainer: keep them out of this repository.
