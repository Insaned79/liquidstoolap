# Руководство пользователя Liquid Stoolap

[English version](user-guide.md)

Liquid Stoolap - локальный HTTP-сервис для выполнения SQL в embedded-базе Stoolap. Сервер представляет собой бинарный файл на Free Pascal и загружает Stoolap через `libstoolap.so`.

## Сборка

Сначала соберите Stoolap C FFI library:

```bash
CARGO_HOME="$PWD/.cargo-home" CARGO_TARGET_DIR="$PWD/.cargo-target" \
  cargo build --manifest-path vendor/stoolap/Cargo.toml --release --no-default-features --features ffi
```

Затем соберите сервер:

```bash
cd server
make build
```

Бинарный файл сервера: `server/build/liquidstoolap`.

## Быстрый старт

```bash
CARGO_HOME="$PWD/.cargo-home" CARGO_TARGET_DIR="$PWD/.cargo-target" \
  cargo build --manifest-path vendor/stoolap/Cargo.toml --release --no-default-features --features ffi

cd server
make build
mkdir -p secrets
printf 'change-me\n' > secrets/admin.password
cp ../config/config.example.ini ../config/local.ini
```

Отредактируйте `../config/local.ini`:

```ini
[stoolap]
library_path = ../.cargo-target/release/libstoolap.so
database_path = memory://

[auth]
password_file = ./secrets/admin.password
```

Затем запустите:

```bash
./build/liquidstoolap check-config --config ../config/local.ini
./build/liquidstoolap serve --config ../config/local.ini
```

## Конфигурация

Создайте файл пароля:

```bash
mkdir -p server/secrets
printf 'change-me\n' > server/secrets/admin.password
```

Скопируйте `config/config.example.ini` в локальный файл и задайте:

```ini
[stoolap]
library_path = ../.cargo-target/release/libstoolap.so
database_path = memory://

[auth]
enabled = true
username = admin
password_file = ./secrets/admin.password
```

Используйте `memory://` для временной in-memory базы. Для постоянной базы задайте путь к файлам, например `./data/stoolap.db`.

`[server].base_path` монтирует API под префиксом. При `base_path = /api/v1` endpoints будут `/api/v1/health`, `/api/v1/auth/token` и `/api/v1/sql`; CLI в этом случае должен получать `--url http://127.0.0.1:8321/api/v1`.

`[server].max_concurrent_requests` ограничивает количество HTTP-запросов в обработке. Значения больше `1` включают threaded HTTP server Free Pascal; запросы сверх лимита получают `503`.

Установите `[stoolap].read_only = true`, если HTTP-слой должен отклонять SQL-команды вроде `CREATE`, `INSERT`, `UPDATE` и `DELETE`. Read-запросы продолжают работать.

## Справочник конфигурации

`config/config.example.ini` - канонический пример с комментариями. Сервер использует INI-секции и отклоняет некорректные значения во время `check-config`.

`[server]`:

| Key | Default | Описание |
| --- | --- | --- |
| `host` | `127.0.0.1` | Адрес bind. Оставляйте loopback, если сервис не защищён VPN, reverse proxy или доверенной сетью. |
| `port` | `8321` | HTTP port. |
| `base_path` | `/` | Префикс API. Пример: `/api/v1`. |
| `request_body_limit_bytes` | `1048576` | Максимальный размер request body. |
| `max_concurrent_requests` | `32` | Максимум in-flight HTTP requests; значения больше `1` включают threaded handling. |
| `cors_enabled` | `false` | Включает browser CORS headers. |
| `cors_allow_origin` | `*` | Значение `Access-Control-Allow-Origin`, если CORS включён. |
| `health_requires_auth` | `false` | Требует bearer auth для `/health`. |

`[stoolap]`:

| Key | Default | Описание |
| --- | --- | --- |
| `library_path` | `../.cargo-target/release/libstoolap.so` | Путь к Stoolap shared library. |
| `database_path` | `./data/stoolap.db` | `memory://` или путь к persistent database. |
| `read_only` | `false` | Отклоняет non-query SQL commands, если true. |
| `busy_timeout_ms` | `5000` | Default backend SQL execution timeout, если request не содержит `timeout_ms`. |
| `startup_check` | `true` | Выполняет `SELECT 1` при startup readiness initialization. |

`[auth]`:

| Key | Default | Описание |
| --- | --- | --- |
| `enabled` | `true` | Включает bearer-token protection для `/sql`. |
| `issue_tokens` | `true` | Включает выдачу tokens через `/auth/token` по username/password. |
| `username` | `admin` | Username для `/auth/token`. |
| `password_file` | empty | Файл с паролем в первой строке. Обязателен, если auth включена без static tokens. |
| `token_ttl_seconds` | `3600` | Lifetime issued in-memory tokens. |
| `allow_static_tokens` | `false` | Принимать tokens из `static_tokens_file`. |
| `static_tokens_file` | empty | Один static token на строку. |
| `token_revoke_on_restart` | `true` | Issued tokens хранятся in-memory и исчезают после restart. |

`[timeouts]`:

| Key | Default | Описание |
| --- | --- | --- |
| `request_timeout_ms` | `30000` | Общий server-side operation timeout. |
| `max_sql_timeout_ms` | `60000` | Верхняя граница для per-request `timeout_ms`. |
| `shutdown_grace_ms` | `15000` | Graceful shutdown wait после `SIGTERM`/`SIGINT`. |

`[logging]`:

| Key | Default | Описание |
| --- | --- | --- |
| `level` | `INFO` | Зарезервировано для filtering; v1 пишет INFO JSON lines. |
| `format` | `json` | Формат логов v1. |
| `access_log` | `true` | Пишет один access log на HTTP request. |
| `sql_log` | `false` | Пишет accepted SQL text. |
| `redact_sql_params` | `true` | Скрывает SQL params в SQL logs. |
| `include_request_id` | `true` | Добавляет request id в responses/logs. |

`[observability]`:

| Key | Default | Описание |
| --- | --- | --- |
| `enable_metrics` | `false` | Зарезервировано для post-1.0; v1 отклоняет `true`. |
| `metrics_bind_host` | `127.0.0.1` | Зарезервировано для post-1.0. |
| `metrics_port` | `9095` | Зарезервировано для post-1.0. |

`[cli]`:

| Key | Default | Описание |
| --- | --- | --- |
| `default_output` | `json` | CLI output format в v1. |

## Запуск

Из `server/`:

```bash
./build/liquidstoolap check-config --config ../config/local.ini
./build/liquidstoolap serve --config ../config/local.ini
```

Остановите сервер через `Ctrl+C` или `SIGTERM`. Сервер помечает себя как shutting down, перестаёт принимать новые запросы и закрывает Stoolap adapter перед выходом.

## Health

```bash
curl -sS http://127.0.0.1:8321/health
```

Здоровый сервер возвращает `200` с `ready: true`. Если Stoolap не открывается или startup check падает, `/health` возвращает `503` с причиной.

Пример:

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

## Аутентификация

Выдать bearer token:

```bash
curl -sS \
  -X POST http://127.0.0.1:8321/auth/token \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"change-me"}'
```

Используйте `token.access_token` как `Authorization: Bearer ...` для `/sql`.

Для service-to-service доступа включите static tokens:

```ini
[auth]
allow_static_tokens = true
static_tokens_file = ./secrets/static.tokens
```

Каждая непустая строка без комментария в `static.tokens` принимается как bearer token.

Пример static token file:

```text
# comments and empty lines are ignored
lst_service_token
lst_named_token = home automation flow
```

Bearer tokens принимаются только через `Authorization` header. Query-string tokens и form-body tokens не входят в v1 contract.

## Выполнение SQL

```bash
TOKEN=lst_...
curl -sS \
  -X POST http://127.0.0.1:8321/sql \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT :id","params":{"id":42},"timeout_ms":5000}'
```

`params` должен быть JSON object. Значения могут быть `null`, boolean, number или string. Binary values, возвращённые Stoolap, кодируются как Base64 strings в JSON result rows.

Один `/sql` request выполняет один SQL statement. Multi-statement scripts отклоняются.

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

Server binary также включает client commands:

```bash
./build/liquidstoolap health --url http://127.0.0.1:8321
./build/liquidstoolap token --url http://127.0.0.1:8321 --username admin --password-file ./secrets/admin.password
./build/liquidstoolap sql --url http://127.0.0.1:8321 --token "$TOKEN" --sql "SELECT :id" --param id=42
```

Для ручной работы используйте `connect`. Это небольшой SQL shell:

```bash
./build/liquidstoolap connect \
  --url http://127.0.0.1:8321 \
  --username admin
```

Если `--password-file` не передан, `connect` спросит пароль интерактивно без отображения ввода. Для scripts можно по-прежнему передать `--password-file ./secrets/admin.password`.

Внутри shell вводите SQL, заканчивая statement символом `;`:

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

- `.help`: показать помощь.
- `.format table`: выводить MySQL-style ASCII tables.
- `.format json`: выводить raw JSON responses.
- `.quit`, `.exit`, `\q`: выйти.

В терминале с `libreadline` shell поддерживает command history, стрелки вверх/вниз и перемещение курсора внутри текущей команды. История сохраняется в `~/.liquidstoolap_history`. Если stdin не terminal, например при pipe, shell использует простое чтение строк.

Выполнить один SQL statement без входа в shell:

```bash
./build/liquidstoolap connect \
  --url http://127.0.0.1:8321 \
  --token "$TOKEN" \
  -e "SELECT :id AS id" \
  --param id=42
```

Используйте `--format json`, если scripts нужен исходный REST response envelope.

CLI `--param` values разбирает `null`, `true`, `false`, integers и floats как JSON scalar values. Остальные значения отправляются как strings.

CLI exit codes:

- `0`: command succeeded.
- `2`: local usage/config/client request error.
- `3`: authentication или authorization error.
- `4`: server/backend/transport failure.
- `5`: SQL execution или validation error.

## Timeouts

`timeout_ms` опционален для SQL request. Если он отсутствует, используется `[stoolap].busy_timeout_ms` как default backend execution timeout. Если `timeout_ms` передан, сервер ограничивает его через `[timeouts].max_sql_timeout_ms` и передаёт в backend timeout execution path Stoolap. Timeout failures возвращают HTTP `504` с `error.code = "backend_timeout"`.

## Логи и метрики

Access logs включены по умолчанию и пишутся как JSON lines. Установите `[logging].sql_log = true`, чтобы писать отдельную JSON line для accepted SQL requests. SQL parameters скрываются, если `[logging].redact_sql_params = true`.

`[observability].enable_metrics` зарезервирован для post-1.0. В v1 `check-config` отклоняет `enable_metrics = true`, чтобы сервер не стартовал молча без metrics endpoint.

## Ошибки

Все error responses используют:

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

Основные status codes:

- `400`: invalid JSON или request shape.
- `401`: отсутствует или неверный bearer token.
- `422`: SQL validation или SQL execution error.
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

## Тесты

```bash
cd server
make test
make smoke
```

`make test` запускает быстрые Free Pascal unit tests для configuration loading/validation, auth/token behavior, error response mapping и request validation helpers.

Smoke test собирает Free Pascal server, загружает реальный Stoolap C FFI library, проверяет auth, `/health`, `/sql`, named params, CLI commands, backend timeout, base-path routing, read-only mode, token expiry, static tokens и graceful SIGTERM shutdown.

Проверки Python SDK:

```bash
PYTHONPATH=sdk/python/src python sdk/python/tests/smoke_sdk.py
```

Python SDK скрывает REST JSON envelope в нормальном использовании. Создайте один client с `username`/`password` или static `token`, затем используйте `execute`, `query`, `command`, `fetch_all`, `fetch_one` или `scalar`.

Проверки Node-RED connector:

```bash
cd packages/node-red
npm test
npm run pack:check
```

## API Contract

OpenAPI описание находится в `docs/api/openapi.yaml`. JSON Schema файлы request/response bodies находятся в `docs/api/schemas/`.

## Deployment

Для локального или private-network deployment:

1. Оставьте `host = 127.0.0.1` для клиентов на той же машине.
2. Используйте reverse proxy, VPN, Tailscale или другой protected transport перед открытием API для других машин.
3. Храните password и static token files вне source control.
4. Используйте persistent `database_path`, если данные должны переживать restart.
5. Запускайте `check-config` перед start/restart сервиса.

Минимальный systemd unit:

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

`check-config` падает с `auth.password_file or auth.static_tokens_file is required`:

Задайте `[auth].password_file` или включите `[auth].allow_static_tokens` с `static_tokens_file`.

`/health` возвращает `503`:

Проверьте `library_path`, `database_path`, права файлов и то, что Stoolap FFI library была собрана с `--features ffi`.

`/sql` возвращает `401`:

Передайте `Authorization: Bearer ...`, используйте свежий issued token или проверьте static token file.

`/sql` возвращает `422`:

SQL некорректен, отклонён как multi-statement, отклонён из-за `read_only` или завершился ошибкой в Stoolap.

`/sql` возвращает `504`:

Увеличьте request `timeout_ms`, `[stoolap].busy_timeout_ms` или `[timeouts].max_sql_timeout_ms` по ситуации.

Сервер слушает не тот path:

Проверьте `[server].base_path`. При `base_path = /api/v1` root `/sql` намеренно возвращает `404`; используйте `/api/v1/sql`.

## Operational Notes

- Оставляйте `host = 127.0.0.1`, если сервис не находится за доверенной network boundary.
- Используйте TLS, VPN, Tailscale или другой protected transport перед внешней публикацией сервиса.
- Не кладите password или token files в source control.
- Access logs пишутся как JSON lines и не включают bearer tokens или SQL parameter values.
