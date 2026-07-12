# Контракт API Liquid Stoolap

[English version](README.md)

`openapi.yaml` - публичный REST contract сервера на Free Pascal.

Схемы в `schemas/` описывают wire-format request и response bodies:

- `sql-request.json`: request body для `/sql`.
- `sql-response.json`: wrapper успешного response для `/sql`.
- `sql-result-set.json`: payload query result.
- `sql-command-result.json`: payload command result.
- `token-response.json`: response body для `/auth/token`.
- `health-response.json`: response body для `/health`.
- `error-response.json`: общий error response body.

Если `[server].base_path` не равен `/`, те же endpoints монтируются под этим префиксом. Например, `base_path = /api/v1` открывает `/api/v1/health`, `/api/v1/auth/token` и `/api/v1/sql`.

Все protected endpoints принимают bearer tokens только через `Authorization` header. Tokens в query parameters или form bodies не входят в v1 contract.
