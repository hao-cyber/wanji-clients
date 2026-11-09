# Contributing

Use the build and test commands in [README.md](README.md). Include the affected
client, OS version, reproduction steps and expected behavior with an issue or PR.
Keep recordings, transcripts, device identifiers, credentials and raw device
logs out of public issues. Use synthetic audio or a small redacted reproduction.

The clients share a BLE compatibility contract. Changes to UUIDs, framing,
binding, acknowledgements, retry behavior or queue persistence require paired
client changes and protocol tests. Report separately which builds passed and
which real devices were tested; do not describe a simulator test as BLE hardware
validation.

Keep audio on failed transfers or processing. Deletion must stay explicit.
Do not introduce a dependency on private backend source code. Implementations
communicate through [the HTTPS contract](docs/api-contract.md).

Never commit signing keys, provisioning profiles, recordings or local settings.
Configure signing with your own account. Contributions are submitted under the
repository's MIT license unless explicitly agreed otherwise.
