# Wanji

**Record on your wrist. Bring the audio back to your phone.**

Wanji saves recordings on a watch, transfers them over Bluetooth to an iPhone,
and keeps a local audio library. Transcription and meeting notes are optional:
users explicitly configure a compatible HTTPS service and start processing.

[中文](README.md) · [Getting started](docs/GETTING_STARTED.md) · [Validation status](docs/STATUS.md)

## Source code

| Client | Directory | Implementation |
| --- | --- | --- |
| iPhone | `app/wanji-ios` | SwiftUI, iOS 17+, audio library and Bluetooth companion |
| Android watch | `app/android-watch` | Java, recording queue and BLE pull service |
| HarmonyOS watch | `app/harmony-watch` | ArkTS, recording queue, runtime binding and BLE push |

This is an initial developer source release. Device compatibility depends on
the watch OS and its ability to install third-party apps. It is not a claim of
support for every Huawei watch. There is no Apple Watch/watchOS client.

The audio backend remains private and is not included. Public builds have no
default backend URL, service credentials, or bundled model API keys. Local
recording, Bluetooth transfer and playback do not require an audio service.
See the [API contract](docs/api-contract.md) for an optional compatible backend.

## Build

On macOS with Xcode and an iOS SDK:

```sh
git clone https://github.com/hao-cyber/wanji-clients.git
cd wanji-clients
xcodebuild -project app/wanji-ios/Wanji.xcodeproj -scheme Wanji \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/wanji-derived-data CODE_SIGNING_ALLOWED=NO build
```

For an iPhone, select your own signing team and unique bundle identifier in
Xcode. To regenerate the project, run `xcodegen generate` in `app/wanji-ios`.

For the Android client, install JDK 17, Android SDK Platform 36 and Build Tools
36.0.0, then set `JAVA_HOME` and `ANDROID_HOME`:

```sh
cd app/android-watch
./gradlew test assembleDebug
```

The debug APK is written to `app/build/outputs/apk/debug/app-debug.apk`.
Install only on a device you select explicitly:
`./install_watch.sh <device-serial-or-ip:port>`.
Do not uninstall an existing recording app to resolve a signing conflict
without first exporting its unsynced audio.

Open `app/harmony-watch` in DevEco Studio for the HarmonyOS client; use your own
device signing configuration. See its [README](app/harmony-watch/README.md).

## Checks

```sh
uv sync --dev --locked
uv run pytest
./scripts/check_swift_contracts.sh
```

Swift checks require macOS. Protocol and persistence tests cannot replace a
real watch/iPhone transfer test. Consult [STATUS.md](docs/STATUS.md) for the
evidence and limitations of this source release.

Recordings are retained locally on transfer or generation failure. Remote
processing requires explicit user action and credentials. See
[privacy](docs/PRIVACY.md) and [contributing](CONTRIBUTING.md).

## License

Wanji source code is available under the [MIT License](LICENSE).
[Third-party tools](THIRD_PARTY_NOTICES.md) retain their own licenses. The
source license does not grant access to the private audio backend.
