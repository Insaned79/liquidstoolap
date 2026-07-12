# Liquid Stoolap User Guide

[Russian translation](user-guide.ru.md)

Liquid Stoolap is a local HTTP service for running SQL against an embedded Stoolap database. The server is a Free Pascal binary and loads Stoolap through `libstoolap.so`.

## Build

Build the Stoolap C FFI library first:

```bash
CARGO_HOME="$PWD/.cargo-home" CARGO_TARGET_DIR="$PWD/.cargo-target" \
  cargo build --manifest-path vendor/stoolap/Cargo.toml --release --no-default-features --features ffi
```

Then build the server:

```bash
cd server
make build
```

The server binary is `server/build/liquidstoolap`.

## Quick Start

```bash
CARGO_HOME="$PWD/.cargo-home" CARGO_TARGET_DIR="$PWD/.cargo-target" \
  cargo build --manifest-path vendor/stoolap/Cargo.toml --release --no-default-features --features ffi

cd server
make build
mkdir -p secrets
printf 'change-me\n' > secrets/admin.password
cp ../config/config.example.ini ../config/local.ini
```

Edit `../config/local.ini`:

```ini
[stoolap]
library_path = ../.cargo-target/release/libstoolap.so
database_path = memory://

[auth]
password_file = ./secrets/admin.password
```

Then run:

```bash
./build/liquidstoolap check-config --config ../config/local.ini
./build/liquidstoolap serve --config ../config/local.ini
```

## Configure

Create a password file:

```bash
mkdir -p server/secrets
printf 'change-me\n' > server/secrets/admin.password
```

Copy `config/config.example.ini` to a local file and set:

```ini
[stoolap]
library_path = ../.cargo-target/release/libstoolap.so
database_path = memory://

[auth]
enabled = true
username = admin
password_file = ./secrets/admin.password
```

Use `memory://` for an ephemeral database. Use a filesystem path such as `./data/stoolap.db` for a persistent database.

`[server].base_path` mounts the API under a path prefix. With `base_path = /api/v1`, the endpoints become `/api/v1/health`, `/api/v1/auth/token`, and `/api/v1/sql`; the CLI should then receive `--url http://127.0.0.1:8321/api/v1`.

`[server].max_concurrent_requests` limits the number of in-flight HTTP requests. Values above `1` enable the threaded Free Pascal HTTP server; requests above the configured limit receive `503`.

Set `[stoolap].read_only = true` when the HTTP layer must reject SQL commands such as `CREATE`, `INSERT`, `UPDATE`, and `DELETE`. Read queries still execute normally.

## Configuration Reference

`config/config.example.ini` is the canonical annotated example. The server uses INI sections and rejects invalid values during `check-config`.

`[server]`:

| Key | Default | Description |
| --- | --- | --- |
| `host` | `127.0.0.1` | Bind address. Keep loopback unless protected by VPN, reverse proxy, or trusted network. |
| `port` | `8321` | HTTP port. |
| `base_path` | `/` | API prefix. Example: `/api/v1`. |
| `request_body_limit_bytes` | `1048576` | Maximum request body size. |
| `max_concurrent_requests` | `32` | Maximum in-flight HTTP requests; values above `1` enable threaded handling. |
| `cors_enabled` | `false` | Enables browser CORS headers. |
| `cors_allow_origin` | `*` | `Access-Control-Allow-Origin` value when CORS is enabled. |
| `health_requires_auth` | `false` | Requires bearer auth for `/health`. |

`[stoolap]`:

| Key | Default | Description |
| --- | --- | --- |
| `library_path` | `../.cargo-target/release/libstoolap.so` | Stoolap shared library path. |
| `database_path` | `./data/stoolap.db` | `memory://` or persistent filesystem path. |
| `read_only` | `false` | Rejects non-query SQL commands when true. |
| `busy_timeout_ms` | `5000` | Default backend SQL execution timeout when request `timeout_ms` is absent. |
| `startup_check` | `true` | Runs `SELECT 1` during startup readiness initialization. |

`[auth]`:

| Key | Default | Description |
| --- | --- | --- |
| `enabled` | `true` | Enables bearer-token protection for `/sql`. |
| `issue_tokens` | `true` | Enables `/auth/token` username/password token issuance. |
| `username` | `admin` | Username accepted by `/auth/token`. |
| `password_file` | empty | File with password on first line. Required when auth is enabled without static tokens. |
| `token_ttl_seconds` | `3600` | Lifetime for issued in-memory tokens. |
| `allow_static_tokens` | `false` | Accept tokens from `static_tokens_file`. |
| `static_tokens_file` | empty | One static token per line. |
| `token_revoke_on_restart` | `true` | Issued tokens are in-memory and disappear on restart. |

`[timeouts]`:

| Key | Default | Description |
| --- | --- | --- |
| `request_timeout_ms` | `30000` | General server-side operation timeout. |
| `max_sql_timeout_ms` | `60000` | Upper bound for per-request `timeout_ms`. |
| `shutdown_grace_ms` | `15000` | Graceful shutdown wait after `SIGTERM`/`SIGINT`. |

`[logging]`:

| Key | Default | Description |
| --- | --- | --- |
| `level` | `INFO` | Reserved for filtering; v1 logs INFO JSON lines. |
| `format` | `json` | v1 log format. |
| `access_log` | `true` | Emits one access log per HTTP request. |
| `sql_log` | `false` | Emits accepted SQL text. |
| `redact_sql_params` | `true` | Redacts SQL params in SQL logs. |
| `include_request_id` | `true` | Includes request id in responses/logs. |

`[observability]`:

| Key | Default | Description |
| --- | --- | --- |
| `enable_metrics` | `false` | Reserved for post-1.0; v1 rejects `true`. |
| `metrics_bind_host` | `127.0.0.1` | Reserved for post-1.0. |
| `metrics_port` | `9095` | Reserved for post-1.0. |

`[cli]`:

| Key | Default | Description |
| --- | --- | --- |
| `default_output` | `json` | CLI output format used by v1. |

## Run

From `server/`:

```bash
./build/liquidstoolap check-config --config ../config/local.ini
./build/liquidstoolap serve --config ../config/local.ini
```

Stop the server with `Ctrl+C` or `SIGTERM`. The server marks itself as shutting down, stops accepting new requests, and closes the Stoolap adapter before exit.

## Health

```bash
curl -sS http://127.0.0.1:8321/health
```

A healthy server returns `200` with `ready: true`. If Stoolap cannot be opened or the startup check fails, `/health` returns `503` with a reason.

Example:

```json
{
  "ok": true,
  "status": "ok",
  "request_id": "...",
  "version": "0.1.0",
  "uptime_s": 12,
  "ready": true,
  "auth_enabled": true
}
```

## Authentication

Issue a bearer token:

```bash
curl -sS \
  -X POST http://127.0.0.1:8321/auth/token \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"change-me"}'
```

Use `token.access_token` as `Authorization: Bearer ...` for `/sql`.

For service-to-service access, enable static tokens:

```ini
[auth]
allow_static_tokens = true
static_tokens_file = ./secrets/static.tokens
```

Each non-empty, non-comment line in `static.tokens` is accepted as a bearer token.

Static token file example:

```text
# comments and empty lines are ignored
lst_service_token
lst_named_token = home automation flow
```

Bearer tokens are accepted only through the `Authorization` header. Query-string tokens and form-body tokens are not part of the v1 contract.

## Execute SQL

```bash
TOKEN=lst_...
curl -sS \
  -X POST http://127.0.0.1:8321/sql \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT :id","params":{"id":42},"timeout_ms":5000}'
```

`params` must be a JSON object. Values may be `null`, boolean, number, or string. Binary values returned by Stoolap are encoded as Base64 strings in JSON result rows.

One `/sql` request executes one SQL statement. Multi-statement scripts are rejected.

Query response:

```json
{
  "ok": true,
  "request_id": "...",
  "duration_ms": 1,
  "result": {
    "kind": "result_set",
    "columns": ["column1"],
    "types": ["INTEGER"],
    "rows": [{"values": [42]}],
    "row_count": 1
  }
}
```

Command response:

```json
{
  "ok": true,
  "request_id": "...",
  "duration_ms": 1,
  "result": {
    "kind": "command",
    "affected_rows": 1,
    "last_insert_id": null
  }
}
```

## CLI

The server binary also includes client commands:

```bash
./build/liquidstoolap health --url http://127.0.0.1:8321
./build/liquidstoolap token --url http://127.0.0.1:8321 --username admin --password-file ./secrets/admin.password
./build/liquidstoolap sql --url http://127.0.0.1:8321 --token "$TOKEN" --sql "SELECT :id" --param id=42
```

For manual work, use `connect`. It behaves like a small SQL shell:

```bash
./build/liquidstoolap connect \
  --url http://127.0.0.1:8321 \
  --username admin
```

When `--password-file` is omitted, `connect` asks for the password interactively without echoing it. You can still pass `--password-file ./secrets/admin.password` for scripts.

Inside the shell, enter SQL terminated by `;`:

```sql
liquidstoolap> SELECT 42 AS answer;
+--------+
| answer |
+--------+
| 42     |
+--------+
1 row(s)
```

Shell commands:

- `.help`: show shell help.
- `.format table`: use MySQL-style ASCII tables.
- `.format json`: print raw JSON responses.
- `.quit`, `.exit`, `\q`: exit.

On terminals with `libreadline`, the shell supports command history, up/down arrows, and cursor movement inside the current command. History is saved in `~/.liquidstoolap_history`. When stdin is not a terminal, for example in a pipe, the shell falls back to simple line reads.

Run one SQL statement without entering the shell:

```bash
./build/liquidstoolap connect \
  --url http://127.0.0.1:8321 \
  --token "$TOKEN" \
  -e "SELECT :id AS id" \
  --param id=42
```

Use `--format json` when scripts need the original REST response envelope.

CLI `--param` values parse `null`, `true`, `false`, integers, and floats as JSON scalar values. Other values are sent as strings.

CLI exit codes:

- `0`: command succeeded.
- `2`: local usage/config/client request error.
- `3`: authentication or authorization error.
- `4`: server/backend/transport failure.
- `5`: SQL execution or validation error.

## Timeouts

`timeout_ms` is optional per SQL request. When it is absent, `[stoolap].busy_timeout_ms` is used as the default backend execution timeout. When `timeout_ms` is present, the server clamps it to `[timeouts].max_sql_timeout_ms` and passes it to Stoolap's backend timeout execution path. Timeout failures return HTTP `504` with `error.code = "backend_timeout"`.

## Logging and Metrics

Access logs are enabled by default and written as JSON lines. Set `[logging].sql_log = true` to emit a separate JSON line for accepted SQL requests. SQL parameters are redacted when `[logging].redact_sql_params = true`.

`[observability].enable_metrics` is reserved for post-1.0. In v1, `check-config` rejects `enable_metrics = true` instead of silently starting without a metrics endpoint.

## Errors

All error responses use:

```json
{
  "ok": false,
  "request_id": "...",
  "error": {
    "code": "invalid_request",
    "category": "request",
    "message": "...",
    "retryable": false
  }
}
```

Common status codes:

- `400`: invalid JSON or request shape.
- `401`: missing or invalid bearer token.
- `422`: SQL validation or SQL execution error.
- `503`: Stoolap backend unavailable.
- `504`: backend timeout.

Stable error codes:

| Code | Category | Typical status |
| --- | --- | --- |
| `invalid_json` | `request` | `400` |
| `invalid_request` | `request` | `400` |
| `invalid_sql` | `request` | `422` |
| `multi_statement_not_allowed` | `request` | `422` |
| `invalid_token` | `auth` | `401` |
| `auth_disabled` | `auth` | `403` |
| `sql_error` | `sql` | `422` |
| `backend_unavailable` | `backend` | `503` |
| `backend_timeout` | `backend` | `504` |
| `internal_error` | `internal` | `500` |

## Test

```bash
cd server
make test
make smoke
```

`make test` runs fast Free Pascal unit tests for configuration loading and validation, auth/token behavior, error response mapping, and request validation helpers.

The smoke test builds the Free Pascal server, loads the real Stoolap C FFI library, verifies auth, `/health`, `/sql`, named params, CLI commands, backend timeout, base-path routing, read-only mode, token expiry, static tokens, and graceful SIGTERM shutdown.

Python SDK checks:

```bash
PYTHONPATH=sdk/python/src python sdk/python/tests/smoke_sdk.py
```

The Python SDK hides the REST JSON envelope in normal use. Create one client with either `username`/`password` or a static `token`, then use `execute`, `query`, `command`, `fetch_all`, `fetch_one`, or `scalar`.

Node-RED connector checks:

```bash
cd packages/node-red
npm test
npm run pack:check
```

## API Contract

The OpenAPI description lives at `docs/api/openapi.yaml`. JSON Schema files for request and response bodies live in `docs/api/schemas/`.

## Deployment

For a local or private-network deployment:

1. Keep `host = 127.0.0.1` for same-machine clients.
2. Use a reverse proxy, VPN, Tailscale, or another protected transport before exposing the API to other machines.
3. Keep password and static token files outside source control.
4. Use a persistent `database_path` if data must survive restarts.
5. Run `check-config` before starting or restarting the service.

Minimal systemd unit example:

```ini
[Unit]
Description=Liquid Stoolap
After=network.target

[Service]
WorkingDirectory=/opt/liquidstoolap/server
ExecStart=/opt/liquidstoolap/server/build/liquidstoolap serve --config /etc/liquidstoolap/config.ini
Restart=on-failure
User=liquidstoolap
Group=liquidstoolap

[Install]
WantedBy=multi-user.target
```

## Troubleshooting

`check-config` fails with `auth.password_file or auth.static_tokens_file is required`:

Set `[auth].password_file` or enable `[auth].allow_static_tokens` with `static_tokens_file`.

`/health` returns `503`:

Check `library_path`, `database_path`, file permissions, and whether the Stoolap FFI library was built with `--features ffi`.

`/sql` returns `401`:

Pass `Authorization: Bearer ...`, use a fresh issued token, or verify the static token file.

`/sql` returns `422`:

The SQL is invalid, rejected as multi-statement, rejected by `read_only`, or failed in Stoolap.

`/sql` returns `504`:

Increase request `timeout_ms`, `[stoolap].busy_timeout_ms`, or `[timeouts].max_sql_timeout_ms` as appropriate.

Server does not listen on the expected path:

Check `[server].base_path`. With `base_path = /api/v1`, root `/sql` intentionally returns `404`; use `/api/v1/sql`.

## Operational Notes

- Keep `host = 127.0.0.1` unless the service is behind a trusted network boundary.
- Put TLS, VPN, Tailscale, or another protected transport in front of the service before exposing it remotely.
- Do not put password or token files in source control.
- Access logs are JSON lines and do not include bearer tokens or SQL parameter values.
