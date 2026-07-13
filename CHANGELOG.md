# Changelog

## Unreleased
- Security hardening for `0.1.6`: SQL command params now use native Stoolap parameter binding instead of SQL text materialization.
- Hardened read-only SQL gating, bearer-token generation/validation, empty password handling, and JSON log escaping.
- Added regression smoke tests for command parameter injection, read-only `WITH` rejection, SQL log newline escaping, and ARMHF runtime.
- Инициализирована базовая структура монорепозитория.
- Реализован Free Pascal HTTP server с реальным Stoolap C FFI adapter.
- Добавлены Python SDK, Node-RED connector, OpenAPI/JSON Schema и пользовательская документация.
- Python SDK переведён на connector-style UX: lazy login, static token mode, query/command/fetch/scalar helpers.
- Добавлены server unit/smoke checks, SDK smoke/unit checks и Node-RED runtime/package checks.
- Реализованы server concurrency limit и default backend timeout через `max_concurrent_requests`/`busy_timeout_ms`.
- `observability.enable_metrics=true` теперь явно отклоняется как post-1.0 feature; добавлен SQL log с redaction.
- Добавлены сетевые TPC-H/TPC-DS-inspired benchmark results для x86 и Raspberry Pi ARM.
