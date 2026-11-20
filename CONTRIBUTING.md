# Contributing

Thanks for helping improve Free Remote for Samsung TV. Bug reports, TV compatibility reports, ideas and pull
requests are all welcome.

## How the project works

The maintainer publishes the app on the App Store, reviews every pull request, and decides what goes into
each release. You don't need an Apple Developer account, signing setup or anything release-related to
contribute: the simulator and demo mode (launch argument `-demo`) cover most work, and a real TV helps for
protocol changes. See "Building" in the [README](README.md) to run the app on your own iPhone.

## Ground rules

- **Privacy first.** The app collects no data and only talks to TVs on the local network. Pull requests that
  add analytics, advertising, tracking, crash uploaders or any network traffic beyond the local network will
  not be accepted.
- **No third-party dependencies.** Apple frameworks only — no Swift packages, CocoaPods or SDKs.
- **Swift 6 with complete strict concurrency.** No warnings. Do not use `@unchecked Sendable` without a
  comment proving it is safe.
- **Security.** Never disable TLS trust checks; control traffic stays on `wss://<tv>:8002` with certificate
  pinning. Only private (RFC 1918) or link-local IPv4 hosts may be contacted. Never log tokens; log hosts and
  MAC addresses with `privacy: .private`.
- **Works on any network.** Nothing may assume a particular subnet, address range, TV model or name.

## Never commit personal network data

This is a public repository. Do not commit, paste into issues, or include in test fixtures:

- IP addresses, MAC addresses, serial numbers or device IDs of your own TVs or devices
- Network names (SSIDs), host names, or TV names that identify you or your home
- Signing data: your Team ID, bundle identifier, certificates or provisioning profiles

Signing settings belong in the git-ignored `Config/Local.xcconfig`. Test fixtures must be anonymised: use
placeholder addresses (`192.0.2.x`, or `10.0.0.x` where a private address is required), made-up MACs and
fictional names. Before pushing, search your diff for anything copied from your own network (for example
`git diff --cached | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9A-Fa-f]{2}:){5}'`) and check every match is
a placeholder.

## Workflow

1. Fork, then create a branch from `main`.
2. Work test-first: write a failing test, watch it fail for the expected reason, make it pass, then tidy up.
   Use Swift Testing (`import Testing`, `@Test`, `#expect`). Put protocol and networking logic in
   `SamsungTVKit` with unit tests; keep the app layer thin.
3. Run all tests (below) and make sure the output is clean.
4. If behaviour on real TVs changed, update `docs/protocol-notes.md`. If user-facing features or requirements
   changed, update the README and say so in the pull request.
5. Open a pull request describing what changed, why, and how you tested it (including TV model years if you
   tested on hardware).

## Running tests

```sh
swift test --package-path SamsungTVKit

xcodebuild test -project FreeRemote.xcodeproj -scheme FreeRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' -parallel-testing-enabled NO
```

While iterating, add `-only-testing:FreeRemoteTests` to run only the app's unit tests, which finish in under a
second after the build; the UI tests take about two minutes, so run the full suite before opening a pull
request.

Real-TV behaviour is checked by hand with [`docs/testing/manual-checklist.md`](docs/testing/manual-checklist.md)
(run the parts your change touches) and the `tvprobe` tool
(`swift build --package-path SamsungTVKit --product tvprobe`).

## Style

Follow the existing code: small types, clear names, `os.Logger` for logging, every user-visible string ready
for localization, and every control with a VoiceOver label. Every button either works or tells the user why
not.

By contributing you agree that your contributions are licensed under the MIT license.
