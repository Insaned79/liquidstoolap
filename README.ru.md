# Liquid Stoolap

[English version](README.md)

Liquid Stoolap - лёгкий REST-сервер для выполнения SQL в embedded-базе Stoolap и набор официальных клиентских интеграций.

Сервер реализован на Free Pascal. Python используется для официального SDK, но не является серверным runtime.

## Компоненты

- `server/`: HTTP-сервер на Free Pascal.
- `sdk/python/`: Python SDK.
- `packages/node-red/`: Node-RED connector.
- `docs/`: пользовательская документация, SRS, OpenAPI, JSON Schema.
- `config/config.example.ini`: полный пример конфигурации.

## Документация

- [User guide](docs/user-guide.md)
- [Руководство пользователя](docs/user-guide.ru.md)
- [Server README](server/README.md)
- [SRS](docs/SRS.md)
- [OpenAPI](docs/api/openapi.yaml)

## Требования

- Free Pascal 3.2.2 или новее с FCL units.
- Rust/Cargo для сборки Stoolap C FFI library.
- `curl` для smoke-тестов.
- Python 3.10+ с `httpx` для smoke-тестов SDK.
- Node.js 18+ для проверок Node-RED пакета.

## Сборка Stoolap FFI

Сервер загружает Stoolap через официальный C API. Соберите shared library локально:

```bash
mkdir -p vendor .cargo-home .cargo-target
git clone --depth 1 https://github.com/stoolap/stoolap.git vendor/stoolap
CARGO_HOME="$PWD/.cargo-home" CARGO_TARGET_DIR="$PWD/.cargo-target" \
  cargo build --release --features ffi --no-default-features \
  --manifest-path vendor/stoolap/Cargo.toml
```

Результат: `.cargo-target/release/libstoolap.so`.

## Сборка сервера

```bash
cd server
make build
```

Бинарный файл: `server/build/liquidstoolap`.

## Конфигурация

Скопируйте `config/config.example.ini` и задайте как минимум:

```ini
[stoolap]
library_path = ../.cargo-target/release/libstoolap.so
database_path = memory://

[auth]
enabled = true
password_file = ./secrets/admin.password
```

Создайте файл пароля вне путей, попадающих в source control:

```bash
mkdir -p server/secrets
printf 'secret\n' > server/secrets/admin.password
```

Для сервисных клиентов можно включить статичные bearer-токены:

```ini
[auth]
allow_static_tokens = true
static_tokens_file = ./secrets/static.tokens
```

Каждая непустая строка без комментария в файле static tokens принимается как bearer token.

## Запуск

```bash
cd server
./build/liquidstoolap serve --config ../config/config.example.ini
```

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
  -d '{"sql":"SELECT :id","params":{"id":42}}'
```

Тот же сценарий можно выполнить через server binary:

```bash
cd server
./build/liquidstoolap health --url http://127.0.0.1:8321
./build/liquidstoolap token \
  --url http://127.0.0.1:8321 \
  --username admin \
  --password-file ./secrets/admin.password
./build/liquidstoolap sql \
  --url http://127.0.0.1:8321 \
  --token "$TOKEN" \
  --sql "SELECT :id" \
  --param id=42
```

## Тесты

Server smoke:

```bash
cd server
make smoke
```

Python SDK smoke:

```bash
cd sdk/python
python3 tests/smoke_sdk.py
```

Node-RED package checks:

```bash
cd packages/node-red
npm test
npm run pack:check
```

## Безопасность

- Bearer tokens принимаются только через `Authorization: Bearer ...`.
- Не выставляйте сервер в недоверенную сеть без TLS на reverse proxy, Tailscale, VPN или аналогичного защищённого транспорта.
- SQL params и bearer tokens не должны попадать в логи.
- Access logs пишутся как JSON records и включают method, path, status, duration и request id.
- Bind host по умолчанию: `127.0.0.1`.
