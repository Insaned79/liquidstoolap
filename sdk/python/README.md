# liquidstoolap Python SDK

[Russian translation](README.ru.md)

Minimal sync and async clients for the Liquid Stoolap REST API.

## Install for Development

```bash
python -m pip install -e ".[dev]"
```

## Usage

Use username/password when the server issues short-lived bearer tokens:

```python
from liquidstoolap import connect

with connect("http://127.0.0.1:8321", username="admin", password="secret") as db:
    rows = db.fetch_all("SELECT :id AS id", {"id": 42})
    one = db.fetch_one("SELECT :id AS id", {"id": 43})
    value = db.scalar("SELECT :id", {"id": 44})
    result = db.query("SELECT :id", {"id": 45})
    command = db.command("CREATE TABLE sdk_example (id INTEGER)")
```

Use a static token when the server is configured with `[auth].allow_static_tokens = true`:

```python
from liquidstoolap import connect

with connect("http://127.0.0.1:8321", token="lst_static_token") as db:
    result = db.execute("SELECT :id", {"id": 42})
    rows = result.as_dicts()
```

`execute()` returns the SQL result directly: `SqlResultSet` for queries or `SqlCommandResult` for commands. Use `raw_execute()` only when you need response metadata such as `request_id` or `duration_ms`.

```python
import asyncio

from liquidstoolap import connect_async


async def main() -> None:
    async with connect_async("http://127.0.0.1:8321", username="admin", password="secret") as db:
        rows = await db.fetch_all("SELECT :id AS id", {"id": 42})
        value = await db.scalar("SELECT :id", {"id": 43})


asyncio.run(main())
```

## Result Objects

`SqlResultSet` provides:

- `columns`, `types`, `rows`, `row_count`.
- `as_dicts()` for `list[dict[str, value]]`.
- `as_tuples()` for tuple rows.
- `first()` for one dict row or `None`.
- `scalar()` for the first column of the first row.

`SqlCommandResult` provides `affected_rows` and `last_insert_id`.

## Errors

HTTP/API failures are mapped to typed exceptions:

- `AuthenticationError` for `401`.
- `AuthorizationError` for `403`.
- `ValidationError` for invalid request shapes.
- `QueryError` for backend SQL errors.
- `TimeoutError` for client-side transport timeouts.
- `ServerError` for `5xx` responses.

Each exception exposes `code` and `status_code` when the server provided them.

## Test

```bash
PYTHONPATH=src pytest -q tests/test_models.py tests/test_client_errors.py
ruff check src tests
mypy src/liquidstoolap
python tests/smoke_sdk.py
```
