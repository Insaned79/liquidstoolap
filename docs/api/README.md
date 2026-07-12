# Liquid Stoolap API Contract

[Russian translation](README.ru.md)

`openapi.yaml` is the public REST contract for the Free Pascal server.

The schemas in `schemas/` describe the wire-format request and response bodies:

- `sql-request.json`: `/sql` request body.
- `sql-response.json`: successful `/sql` response wrapper.
- `sql-result-set.json`: query result payload.
- `sql-command-result.json`: command result payload.
- `token-response.json`: `/auth/token` response body.
- `health-response.json`: `/health` response body.
- `error-response.json`: shared error response body.

When `[server].base_path` is not `/`, the same endpoints are mounted under that prefix. For example, `base_path = /api/v1` exposes `/api/v1/health`, `/api/v1/auth/token`, and `/api/v1/sql`.

All protected endpoints accept bearer tokens only through the `Authorization` header. Tokens in query parameters or form bodies are not part of the v1 contract.
