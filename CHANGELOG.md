# Changelog

## v0.1.0-alpha.2 — 2026-11-09

- Require authentication on the current Android BLE connection before sending
  recording bytes through reads or notifications, including prewarmed audio.
- Reject remote replacement of an existing Android watch binding credential;
  repeated binding with the same credential remains supported.
- Preview external iPhone configuration links and require confirmation before
  changing the upload destination or saved credential.
- Add authorization and side-effect regression tests. These changes do not
  modify BLE UUIDs, wire frames, acknowledgements, or recording deletion rules.

This updates source code only. Installed apps require rebuilding and updating.
Physical-device BLE acceptance and encrypted pairing remain outstanding; see
[privacy and pairing boundaries](docs/PRIVACY.md) and [validation status](docs/STATUS.md).

## v0.1.0-alpha.1 — 2026-11-09

Initial public client source release:

- iPhone companion, Android watch recorder and HarmonyOS watch client.
- Local recording queues, Bluetooth binding and transfer, and optional audio API integration.
- Public builds start without a backend URL or personal signing team.
- Client API contract, build/pairing instructions, privacy notes and contribution guide.
- Client CI, cross-client protocol checks and public-source boundary tests.
- Version-aligned Gradle wrapper with SHA-256 checks and upstream license notices.

The audio backend remains private. This is a developer source release; store
distribution and current real-device acceptance are not part of this release.
See [validation status](docs/STATUS.md) for executed checks and remaining limits.
