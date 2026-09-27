# Storage reliability

Liquid Stoolap builds Stoolap 0.4.0 from commit
`7e6634ba8447f33ae99aefb99693459cd691394a` with the reviewed patch in
`patches/stoolap-0.4.0-liquidstoolap.patch`. Release builds never follow the
moving Stoolap `main` branch.

## Recovery guarantees

- A volume is written to a temporary file, fsynced, read back, and CRC-checked
  before it can be renamed and published in a table manifest.
- Volume headers and block indexes are checked against the physical file size
  before their values are used for memory allocation.
- Recovery replays the WAL before its final integrity decision, allowing a
  committed `DROP TABLE` or `TRUNCATE TABLE` to remove older volume references.
- After WAL replay, every segment still referenced by a live manifest must be
  present and pass format and CRC validation. Otherwise database open fails
  with `storage integrity error`; partial rows are never silently served.
- `DROP TABLE` removes the complete table volume directory after its WAL record
  is durable. `TRUNCATE TABLE` publishes an empty manifest before old volume
  files are removed.
- A compaction pass loads at most 16 input volumes. This gives compaction a
  bounded working set even after an extended backlog.

Physical media corruption cannot be repaired from a single copy. A storage
integrity error therefore requires recovery from a verified backup or replica.
The fail-closed behavior protects applications from accepting incomplete query
results as valid data.

## Verification

The patched engine follows upstream's development checks:

```bash
cargo fmt --all -- --check
cargo test --test volume_checkpoint_test
cargo test --test durability_test
cargo test
```

Regression coverage includes missing and corrupt manifest volumes, bounded
compaction, interrupted volume publication, manifest corruption, WAL recovery,
and crash-safe `DROP`/`TRUNCATE` ordering.
