# Unreleased

### Fixed

- `svc-start.sh` no longer fails a fresh clone with
  `svc-gen-nanomq.sh: Permission denied`. The generator was committed `100644`
  while the rest of the set is `100755`, so executing it died before its own
  no-op path could run. It is now invoked through `bash`, which does not care
  about the mode bit — the bit does not survive every checkout, and a copy
  committed from Windows lands `644`.

### Changed

- `svc-gen-nanomq.sh` is removed from this repo. SaamSaam runs no broker — there
  is no `nanomq`, and no `MQTT_*` value anywhere in `.env.example` — so the
  generator had nothing to generate and only raised the question of why a
  SaamSaam deploy was doing something for nanomq.
- `svc-start.sh` calls the broker generator only where the file is present, so a
  stack with no broker skips it outright instead of running a no-op. Where a
  broker IS present the call stays automatic: the files it writes are gitignored,
  so a fresh clone has none, and a broker started first has docker bind-mount an
  empty directory over each missing file and crash-loop.
- The `svc-*` set moves to `svc-scripts 0.1.2`.
