# Stoolap Adapter Strategy

Liquid Stoolap server is a Free Pascal program. Stoolap is an embedded Rust database with an official C API in `include/stoolap.h`, built with:

```bash
cargo build --manifest-path vendor/stoolap/Cargo.toml --release --no-default-features --features ffi
```

The Pascal server should call Stoolap through that C ABI, not through Python, Node.js, or a fake database layer.

## Integration Shape

The adapter is split into two layers:

1. `lsstoolapffi.pas` dynamically loads `libstoolap.so`, `libstoolap.dylib`, or `stoolap.dll` and resolves C symbols.
2. `lsstoolapadapter.pas` converts Liquid Stoolap request/result models into C API calls and JSON-safe values.

Dynamic loading is intentional. It lets the Free Pascal server build in CI even when the native Stoolap shared library is not installed, while still failing clearly at runtime if the configured library cannot be loaded.

## Minimum Required C Symbols

- `stoolap_version`
- `stoolap_open`
- `stoolap_open_in_memory`
- `stoolap_close`
- `stoolap_errmsg`
- `stoolap_exec`
- `stoolap_exec_named`
- `stoolap_exec_named_timeout`
- `stoolap_query`
- `stoolap_query_named`
- `stoolap_query_named_timeout`
- `stoolap_rows_next`
- `stoolap_rows_column_count`
- `stoolap_rows_column_name`
- `stoolap_rows_column_type`
- `stoolap_rows_column_is_null`
- `stoolap_rows_column_int64`
- `stoolap_rows_column_double`
- `stoolap_rows_column_text`
- `stoolap_rows_column_bool`
- `stoolap_rows_column_blob`
- `stoolap_rows_close`
- `stoolap_rows_errmsg`

## Smoke Test

The adapter smoke path is:

1. Build or provide `libstoolap.so`.
2. Load it with `lsstoolapffi.pas`.
3. Open `memory://`.
4. Execute `SELECT 1`.
5. Convert the result to Liquid Stoolap `result_set` JSON.

The server smoke test also verifies named params, command results, backend timeout mapping, multi-statement rejection, static tokens, token TTL expiry, CLI commands, and graceful shutdown.
