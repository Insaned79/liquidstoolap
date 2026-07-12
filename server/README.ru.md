# Liquid Stoolap Server

[English version](README.md)

Сервер реализован на Free Pascal. Python server runtimes не входят в архитектуру v1.

## Инструменты

- Минимально проверенный compiler: FPC 3.2.2
- Build entrypoint: `make build`
- HTTP stack: FPC `fphttpserver`
- JSON: FPC `fpjson` / `jsonparser`
- Config: FPC `inifiles`

## Команды

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

## Проверяемое поведение сервера

`make smoke` проверяет:

- сборку Free Pascal;
- загрузку реального Stoolap C FFI;
- in-memory Stoolap startup check;
- `GET /health`;
- `POST /auth/token`;
- bearer enforcement на `/sql`;
- backend-level SQL timeout как `backend_timeout`;
- named SQL params;
- command result;
- multi-statement rejection;
- invalid JSON и invalid request shape;
- request body limit;
- static tokens;
- optional auth на `/health`;
- истечение issued token TTL;
- graceful SIGTERM shutdown;
- CLI `health`, `token` и `sql`;
- JSON access logs.

## Stoolap FFI

Сервер динамически загружает официальный `libstoolap.so`. Настройка:

```ini
[stoolap]
library_path = ../.cargo-target/release/libstoolap.so
database_path = memory://
```

Persistent databases используют `file://` DSN internally, если `database_path` не равен `memory://`.
