# Wanji repository instructions

- Treat the iOS and watch apps as one product with a shared BLE compatibility
  contract. Changes to UUIDs, frames, queue semantics, ACK behavior, binding or
  version negotiation require cross-client tests.
- Do not commit recordings, generated builds, device logs, signing keys,
  provisioning profiles or acceptance corpora.
- Validate UI changes with real rendered screenshots on the relevant simulator
  or device, then inspect hierarchy, spacing, overflow and state feedback.
- Keep the backend behind `docs/api-contract.md`; do not import or copy private
  backend internals into client code.
- Preserve local audio on transfer, upload or note-generation failure. Deletion
  must remain explicit and recoverable wherever practical.
