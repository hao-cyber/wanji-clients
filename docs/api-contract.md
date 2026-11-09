# Wanji client audio API contract

This public repository owns the watch/iPhone clients and their BLE contract.
The audio backend is private and is not included. These HTTPS endpoints describe
the interface expected by the iPhone client; a compatible service is optional.
The client must not import backend modules or assume a repository-local server.

## Authentication

The public iOS build starts with an empty service URL. Users explicitly configure
a compatible service in settings; its bearer token is stored in Keychain.
Requests use:

```http
Authorization: Bearer <token>
```

Production base URLs must use HTTPS. Localhost development is the only intended
plain-HTTP exception.

## Create an audio job

The iOS client prefers resumable upload so a slow or interrupted transfer never
depends on one long proxied request. It first initializes a deterministic upload
session:

```http
POST /internal/task/audio/uploads
Content-Type: application/json
Authorization: Bearer <token>

{
  "mode": "meeting_notes",
  "filename": "recording.m4a",
  "content_type": "audio/mp4",
  "size_bytes": 1234567,
  "sha256": "<lowercase file SHA-256>"
}
```

The response supplies `upload_id`, `chunk_bytes`, `uploaded_chunks`, and an
optional `completed_job_id`. The client skips already retained chunks and sends
each missing chunk independently:

```http
PUT /internal/task/audio/uploads/<upload-id>/chunks/<zero-based-index>
Content-Type: application/octet-stream
X-Chunk-SHA256: <lowercase chunk SHA-256>
Authorization: Bearer <token>
```

Chunk size is negotiated by the response (currently 512 KiB); the final chunk
may be shorter. A chunk write is atomic and idempotent. When all chunks are
present, the client completes the upload:

```http
POST /internal/task/audio/uploads/<upload-id>/complete
Authorization: Bearer <token>
```

The server verifies total length and whole-file SHA-256 before atomically
creating the retained job. Re-initializing the same file returns the same
session, and repeating completion returns the same job. Repeating completion
after a failed job revalidates the retained chunks and requeues that stable job.
Incomplete sessions are retained for retry; client audio remains local on every
transfer or completion failure.

The original single-request endpoint remains available during the compatibility
window:

```http
POST /internal/task/audio/jobs?mode=meeting_notes&new_session=1
Content-Type: audio/mp4
Authorization: Bearer <token>
```

The request body is the raw audio bytes, not multipart form data. The iOS client
only falls back to this endpoint when upload initialization returns `404` or
`405`, and also supplies the original filename as a `filename` query parameter.
A successful response from either protocol provides a stable job identifier
that can be polled.

## Poll a job

```http
GET /internal/task/audio/jobs/<job-id>
Authorization: Bearer <token>
```

The client currently understands queued/running/succeeded/failed states and
persists usable transcript evidence even when meeting-note generation fails.
Successful transcript results must include non-empty transcript text, duration,
provider/model metadata, ordered sentence segments, timing source, timeline
coverage and segment-text coverage. Meeting-note success additionally includes
the Markdown notes body and its generation metadata.

Meeting-note Markdown has two top-level sections: `## 内容` for dense facts,
decisions and outcomes, and `## TODO` for explicit actions only. Long
transcripts use rolling snapshots: every new transcript chunk rewrites the
previous complete note and the last snapshot is returned, without a second
model summarization pass. For compatibility, long results still report
`notes_strategy=chunked`; `notes_combine.mode=rolling_snapshot` identifies the
new behavior, while `notes_chunks` retains per-update evidence for auditing.

## Compatibility rule

Changes to endpoint paths, authentication, resumable-upload fields or checksum
semantics, status values, transcript segments, coverage semantics or
error-result retention are breaking changes. Update the iOS decoder and its
contract smoke tests in the same Wanji commit when the service contract changes.

## Local evaluation boundary

Recording, Bluetooth transfer and local playback do not require backend credentials.
Remote transcription and notes require an independently supplied compatible service.
No backend source, provider keys, live acceptance corpus or service-access grant
is part of this repository.
