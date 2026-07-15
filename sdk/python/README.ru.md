# liquidstoolap Python SDK

[English version](README.md)

Минимальные sync и async clients для Liquid Stoolap REST API.

## Установка для разработки

```bash
python -m pip install -e ".[dev]"
```

## Использование

Используйте username/password, если сервер выдаёт short-lived bearer tokens:

```python
from liquidstoolap import connect

with connect("http://127.0.0.1:8321", username="admin", password="secret") as db:
    rows = db.fetch_all("SELECT :id AS id", {"id": 42})
    one = db.fetch_one("SELECT :id AS id", {"id": 43})
    value = db.scalar("SELECT :id", {"id": 44})
    result = db.query("SELECT :id", {"id": 45})
    command = db.command("CREATE TABLE sdk_example (id INTEGER)")
```

Используйте static token, если сервер настроен с `[auth].allow_static_tokens = true`:

```python
from liquidstoolap import connect

with connect("http://127.0.0.1:8321", token="lst_static_token") as db:
    result = db.execute("SELECT :id", {"id": 42})
    rows = result.as_dicts()
```

`execute()` возвращает SQL result напрямую: `SqlResultSet` для queries или `SqlCommandResult` для commands. Используйте `raw_execute()` только когда нужны response metadata, например `request_id` или `duration_ms`.

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

`SqlResultSet` предоставляет:

- `columns`, `types`, `rows`, `row_count`, `truncated`;
- `as_dicts()` для `list[dict[str, value]]`;
- `as_tuples()` для tuple rows;
- `first()` для одной dict row или `None`;
- `scalar()` для первого столбца первой строки.

`SqlCommandResult` предоставляет `affected_rows` и `last_insert_id`.

## Ошибки

HTTP/API failures отображаются в typed exceptions:

- `AuthenticationError` для `401`.
- `AuthorizationError` для `403`.
- `ValidationError` для invalid request shapes.
- `QueryError` для backend SQL errors.
- `TimeoutError` для client-side transport timeouts.
- `ServerError` для `5xx` responses.

Каждое exception содержит `code` и `status_code`, если сервер их передал.

## Тесты

```bash
PYTHONPATH=src pytest -q tests/test_models.py tests/test_client_errors.py
ruff check src tests
mypy src/liquidstoolap
python tests/smoke_sdk.py
```
