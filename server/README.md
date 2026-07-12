# Liquid Stoolap Server

[Russian translation](README.ru.md)

The server is implemented in Free Pascal. Python server runtimes are not part of the v1 architecture.

## Tooling

- Minimum verified compiler: FPC 3.2.2
- Build entrypoint: `make build`
- HTTP stack: FPC `fphttpserver`
- JSON: FPC `fpjson` / `jsonparser`
- Config: FPC `inifiles`

## Commands

```bash
make build
./build/liquidstoolap --help
./build/liquidstoolap --version
./build/liquidstoolap check-config --config ../config/config.example.ini
./build/liquidstoolap serve --config ../config/config.example.ini
./build/liquidstoolap health --url http://127.0.0.1:8321
./build/liquidstoolap token --url http://127.0.0.1:8321 --username admin --password-file ./secrets/admin.password
./build/liquidstoolap sql --url http://127.0.0.1:8321 --token "$TOKEN" --sql "SELECT :id" --param id=42
```

## Tested Server Behavior

`make smoke` verifies:

- Free Pascal build.
- real Stoolap C FFI load.
- in-memory Stoolap startup check.
- `GET /health`.
- `POST /auth/token`.
- bearer enforcement on `/sql`.
- backend-level SQL timeout mapped to `backend_timeout`.
- named SQL params.
- command result.
- multi-statement rejection.
- invalid JSON and invalid request shape.
- request body limit.
- static tokens.
- optional auth on `/health`.
- issued token TTL expiry.
- graceful SIGTERM shutdown.
- CLI `health`, `token`, and `sql`.
- JSON access logs.

## Stoolap FFI

The server loads the official `libstoolap.so` dynamically. Configure it with:

```ini
[stoolap]
library_path = ../.cargo-target/release/libstoolap.so
database_path = memory://
```

Persistent databases use `file://` DSNs internally when `database_path` is not `memory://`.
