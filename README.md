# Liquid Stoolap

![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)
![Server: Free Pascal](https://img.shields.io/badge/server-Free%20Pascal-blue.svg)
![Backend: Stoolap](https://img.shields.io/badge/backend-Stoolap-purple.svg)
![API: REST](https://img.shields.io/badge/API-REST-orange.svg)
![Python SDK](https://img.shields.io/badge/SDK-Python-yellow.svg)
![Node--RED](https://img.shields.io/badge/Node--RED-connector-red.svg)

Lightweight REST access to an embedded Stoolap database.

Liquid Stoolap is a small self-hosted server for executing SQL over HTTP, with official Python SDK and Node-RED integration. The server is implemented in Free Pascal and talks to Stoolap through the real C FFI library.

> Status: MVP/v1-oriented project. The server, Python SDK, Node-RED connector, OpenAPI contract, tests, and documentation are implemented. JS/TS SDK and public metrics endpoint are intentionally post-1.0 items.

---

## English

### What It Is

Liquid Stoolap gives local automation tools, scripts, edge devices, and small self-hosted services a narrow HTTP interface to Stoolap:

- `POST /sql` for one SQL statement per request.
- `POST /auth/token` for token issuance.
- `GET /health` for readiness.
- JSON request/response contract described by OpenAPI and JSON Schema.
- Official Python SDK with connector-style UX.
- Official Node-RED custom node package.

It is intentionally not an ORM, BI server, migration framework, or general data platform.

### Key Features

- Free Pascal HTTP server.
- Real Stoolap C FFI adapter.
- INI configuration with an annotated example.
- Bearer authentication with issued tokens and static service tokens.
- Optional read-only mode.
- Per-request SQL timeout and default backend timeout.
- Base path support, request size limit, CORS switch.
- JSON access logs and optional SQL logs with parameter redaction.
- Server unit tests and real FFI smoke tests.
- Python sync/async SDK.
- Node-RED connector.
- OpenAPI and JSON Schema contract.

### Repository Layout

| Path | Purpose |
| --- | --- |
| `server/` | Free Pascal server and server tests. |
| `sdk/python/` | Official Python SDK. |
| `packages/node-red/` | Official Node-RED connector. |
| `config/config.example.ini` | Annotated configuration example. |
| `docs/user-guide.md` | Full English user guide. |
| `docs/user-guide.ru.md` | Full Russian user guide. |
| `docs/api/openapi.yaml` | REST API contract. |
| `docs/api/schemas/` | JSON Schema files. |
| `docs/SRS.md` | Software requirements specification. |

### Quick Start

#### Docker On x86_64

Get the repository and run Docker from its root directory:

```bash
git clone https://github.com/Insaned79/liquidstoolap.git
cd liquidstoolap
docker build -t liquidstoolap:latest .
```

Run `docker build ... .` only from the repository root. The repository contains `.dockerignore`, so the Docker build context stays small; running the same command from your home directory will send unrelated local files to Docker.

The Dockerfile does not build Rust or Free Pascal code. It resolves the latest GitHub release, downloads the matching `liquidstoolap-server-<version>-linux-x86_64.tar.gz` asset, and places it into a small glibc-based runtime image. To pin a version, pass `--build-arg LIQUID_STOOLAP_VERSION=0.1.4`.

Create a mounted data directory with the Docker config and password file:

```bash
mkdir -p liquid-data
docker run --rm liquidstoolap:latest \
  cat /opt/liquidstoolap/config.example.ini > liquid-data/config.ini
printf 'secret\n' > liquid-data/admin.password
```

The Docker config keeps all mutable state on the mounted volume:

- `/data/config.ini` - server config.
- `/data/admin.password` - password used by `POST /auth/token`.
- `/data/stoolap.db` - persistent Stoolap database directory/file.

Validate the mounted config:

```bash
docker run --rm \
  -v "$PWD/liquid-data:/data" \
  liquidstoolap:latest \
  liquidstoolap check-config --config /data/config.ini
```

Start the server:

```bash
docker run -d \
  --name liquidstoolap \
  -p 8321:8321 \
  -v "$PWD/liquid-data:/data" \
  liquidstoolap:latest
```

Check it:

```bash
curl -sS http://127.0.0.1:8321/health
```

Stop and remove the container:

```bash
docker rm -f liquidstoolap
```

#### Build From Source

Build Stoolap with C FFI support:

```bash
mkdir -p vendor .cargo-home .cargo-target
git clone --depth 1 https://github.com/stoolap/stoolap.git vendor/stoolap
CARGO_HOME="$PWD/.cargo-home" CARGO_TARGET_DIR="$PWD/.cargo-target" \
  cargo build --manifest-path vendor/stoolap/Cargo.toml --release --no-default-features --features ffi
```

Build the server:

```bash
cd server
make build
```

Create a local config and password file:

```bash
mkdir -p secrets
printf 'secret\n' > secrets/admin.password
cp ../config/config.example.ini ../config/local.ini
```

Set at least:

```ini
[stoolap]
library_path = ../.cargo-target/release/libstoolap.so
database_path = memory://

[auth]
password_file = ./secrets/admin.password
```

Run:

```bash
./build/liquidstoolap check-config --config ../config/local.ini
./build/liquidstoolap serve --config ../config/local.ini
```

### Example API Flow

Health check:

```bash
curl -sS http://127.0.0.1:8321/health
```

Issue a token:

```bash
curl -sS \
  -X POST http://127.0.0.1:8321/auth/token \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"secret"}'
```

Execute SQL:

```bash
TOKEN=lst_...
curl -sS \
  -X POST http://127.0.0.1:8321/sql \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT :id","params":{"id":42},"timeout_ms":5000}'
```

### Python SDK

```python
from liquidstoolap import connect

with connect("http://127.0.0.1:8321", username="admin", password="secret") as db:
    rows = db.fetch_all("SELECT :id AS id", {"id": 42})
    one = db.fetch_one("SELECT :id AS id", {"id": 43})
    value = db.scalar("SELECT :id", {"id": 44})
    result = db.query("SELECT :id", {"id": 45})
    command = db.command("CREATE TABLE sdk_example (id INTEGER)")
```

Static token mode:

```python
from liquidstoolap import connect

with connect("http://127.0.0.1:8321", token="lst_static_token") as db:
    result = db.execute("SELECT :id", {"id": 42})
```

### Node-RED

The Node-RED package provides:

- `liquid-stoolap-config`: shared server configuration and credentials.
- `liquid-stoolap-sql`: SQL execution node.

SQL comes from the configured node field or `msg.topic`; params come from `msg.payload`.

### Tests

Server:

```bash
cd server
make test
make smoke
```

Python SDK:

```bash
cd sdk/python
PYTHONPATH=src pytest -q tests/test_models.py tests/test_client_errors.py
ruff check src tests
mypy src/liquidstoolap
python tests/smoke_sdk.py
```

Node-RED:

```bash
cd packages/node-red
npm test
npm run pack:check
```

### Documentation

- [Full user guide](docs/user-guide.md)
- [Russian user guide](docs/user-guide.ru.md)
- [Configuration example](config/config.example.ini)
- [OpenAPI contract](docs/api/openapi.yaml)
- [API schemas](docs/api/schemas/)
- [Python SDK README](sdk/python/README.md)
- [Node-RED README](packages/node-red/README.md)
- [SRS](docs/SRS.md)

### Security Notes

- Bearer tokens are accepted only through `Authorization: Bearer ...`.
- Do not expose the service to an untrusted network without TLS, VPN, Tailscale, or an equivalent protected transport.
- Keep password files and static token files outside source control.
- Access logs do not include bearer tokens.
- SQL params are redacted in SQL logs by default.
- The default bind host is `127.0.0.1`.

### License

MIT. See [LICENSE](LICENSE).

---

## Русский

Liquid Stoolap - лёгкий self-hosted REST-сервер для выполнения SQL в embedded-базе Stoolap. Сервер написан на Free Pascal и использует реальный Stoolap C FFI adapter.

> Статус: проект ориентирован на MVP/v1. Сервер, Python SDK, Node-RED connector, OpenAPI contract, тесты и документация реализованы. JS/TS SDK и публичный metrics endpoint сознательно вынесены за v1.0.

### Что это

Liquid Stoolap даёт локальным automation-сценариям, скриптам, edge-устройствам и небольшим self-hosted сервисам узкий HTTP-интерфейс к Stoolap:

- `POST /sql` - один SQL statement на request.
- `POST /auth/token` - выдача bearer token.
- `GET /health` - readiness.
- JSON contract через OpenAPI и JSON Schema.
- Официальный Python SDK с UX как у SQL connectors.
- Официальный Node-RED custom node package.

Это не ORM, не BI-сервер, не migration framework и не универсальная data platform.

### Возможности

- HTTP-сервер на Free Pascal.
- Реальный Stoolap C FFI adapter.
- INI-конфигурация с подробным примером.
- Bearer auth: issued tokens и static service tokens.
- Optional read-only mode.
- Per-request SQL timeout и default backend timeout.
- `base_path`, request size limit, CORS switch.
- JSON access logs и optional SQL logs с redaction параметров.
- Server unit tests и smoke tests с реальным FFI.
- Sync/async Python SDK.
- Node-RED connector.
- OpenAPI и JSON Schema contract.

### Структура проекта

| Путь | Назначение |
| --- | --- |
| `server/` | Сервер на Free Pascal и server tests. |
| `sdk/python/` | Официальный Python SDK. |
| `packages/node-red/` | Официальный Node-RED connector. |
| `config/config.example.ini` | Пример конфигурации с комментариями. |
| `docs/user-guide.md` | Полное руководство на английском. |
| `docs/user-guide.ru.md` | Полное руководство на русском. |
| `docs/api/openapi.yaml` | REST API contract. |
| `docs/api/schemas/` | JSON Schema files. |
| `docs/SRS.md` | Software requirements specification. |

### Быстрый старт

#### Docker на x86_64

Получите репозиторий и запускайте Docker из его корня:

```bash
git clone https://github.com/Insaned79/liquidstoolap.git
cd liquidstoolap
docker build -t liquidstoolap:latest .
```

Запускайте `docker build ... .` только из корня репозитория. В репозитории есть `.dockerignore`, поэтому Docker build context остаётся маленьким; если запустить ту же команду из домашнего каталога, Docker начнёт отправлять посторонние локальные файлы.

Dockerfile не собирает Rust или Free Pascal код. Он определяет latest GitHub release, скачивает подходящий asset `liquidstoolap-server-<version>-linux-x86_64.tar.gz` и кладёт его в небольшой glibc-based runtime image. Чтобы зафиксировать версию, передайте `--build-arg LIQUID_STOOLAP_VERSION=0.1.4`.

Создайте mounted data directory с Docker config и password file:

```bash
mkdir -p liquid-data
docker run --rm liquidstoolap:latest \
  cat /opt/liquidstoolap/config.example.ini > liquid-data/config.ini
printf 'secret\n' > liquid-data/admin.password
```

Docker config хранит всё изменяемое состояние на mounted volume:

- `/data/config.ini` - server config.
- `/data/admin.password` - password для `POST /auth/token`.
- `/data/stoolap.db` - persistent Stoolap database directory/file.

Проверьте mounted config:

```bash
docker run --rm \
  -v "$PWD/liquid-data:/data" \
  liquidstoolap:latest \
  liquidstoolap check-config --config /data/config.ini
```

Запустите сервер:

```bash
docker run -d \
  --name liquidstoolap \
  -p 8321:8321 \
  -v "$PWD/liquid-data:/data" \
  liquidstoolap:latest
```

Проверьте:

```bash
curl -sS http://127.0.0.1:8321/health
```

Остановить и удалить container:

```bash
docker rm -f liquidstoolap
```

#### Сборка из исходников

Соберите Stoolap с C FFI:

```bash
mkdir -p vendor .cargo-home .cargo-target
git clone --depth 1 https://github.com/stoolap/stoolap.git vendor/stoolap
CARGO_HOME="$PWD/.cargo-home" CARGO_TARGET_DIR="$PWD/.cargo-target" \
  cargo build --manifest-path vendor/stoolap/Cargo.toml --release --no-default-features --features ffi
```

Соберите сервер:

```bash
cd server
make build
```

Создайте локальный config и password file:

```bash
mkdir -p secrets
printf 'secret\n' > secrets/admin.password
cp ../config/config.example.ini ../config/local.ini
```

Минимально настройте:

```ini
[stoolap]
library_path = ../.cargo-target/release/libstoolap.so
database_path = memory://

[auth]
password_file = ./secrets/admin.password
```

Запустите:

```bash
./build/liquidstoolap check-config --config ../config/local.ini
./build/liquidstoolap serve --config ../config/local.ini
```

### Пример API

Health check:

```bash
curl -sS http://127.0.0.1:8321/health
```

Получить token:

```bash
curl -sS \
  -X POST http://127.0.0.1:8321/auth/token \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"secret"}'
```

Выполнить SQL:

```bash
TOKEN=lst_...
curl -sS \
  -X POST http://127.0.0.1:8321/sql \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT :id","params":{"id":42},"timeout_ms":5000}'
```

### Python SDK

```python
from liquidstoolap import connect

with connect("http://127.0.0.1:8321", username="admin", password="secret") as db:
    rows = db.fetch_all("SELECT :id AS id", {"id": 42})
    one = db.fetch_one("SELECT :id AS id", {"id": 43})
    value = db.scalar("SELECT :id", {"id": 44})
    result = db.query("SELECT :id", {"id": 45})
    command = db.command("CREATE TABLE sdk_example (id INTEGER)")
```

Static token mode:

```python
from liquidstoolap import connect

with connect("http://127.0.0.1:8321", token="lst_static_token") as db:
    result = db.execute("SELECT :id", {"id": 42})
```

### Node-RED

Node-RED package предоставляет:

- `liquid-stoolap-config`: общая server configuration и credentials.
- `liquid-stoolap-sql`: node для выполнения SQL.

SQL берётся из настроенного поля node или `msg.topic`; params берутся из `msg.payload`.

### Тесты

Сервер:

```bash
cd server
make test
make smoke
```

Python SDK:

```bash
cd sdk/python
PYTHONPATH=src pytest -q tests/test_models.py tests/test_client_errors.py
ruff check src tests
mypy src/liquidstoolap
python tests/smoke_sdk.py
```

Node-RED:

```bash
cd packages/node-red
npm test
npm run pack:check
```

### Документация

- [Полное руководство пользователя](docs/user-guide.ru.md)
- [Full user guide](docs/user-guide.md)
- [Пример конфигурации](config/config.example.ini)
- [OpenAPI contract](docs/api/openapi.yaml)
- [API schemas](docs/api/schemas/)
- [Python SDK README](sdk/python/README.ru.md)
- [Node-RED README](packages/node-red/README.ru.md)
- [SRS](docs/SRS.md)

### Безопасность

- Bearer tokens принимаются только через `Authorization: Bearer ...`.
- Не открывайте сервис в недоверенную сеть без TLS, VPN, Tailscale или аналогичного protected transport.
- Храните password files и static token files вне source control.
- Access logs не содержат bearer tokens.
- SQL params по умолчанию скрываются в SQL logs.
- Bind host по умолчанию: `127.0.0.1`.

### Лицензия

MIT. См. [LICENSE](LICENSE).
