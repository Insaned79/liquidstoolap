from __future__ import annotations

import asyncio

import httpx

from liquidstoolap import (
    AsyncLiquidStoolapClient,
    AuthenticationError,
    LiquidStoolapClient,
    QueryError,
    ServerError,
    ValidationError,
)


def result_payload(value: int = 42) -> dict[str, object]:
    return {
        "ok": True,
        "request_id": "r",
        "duration_ms": 1,
        "result": {
            "kind": "result_set",
            "columns": ["column1"],
            "types": ["INTEGER"],
            "rows": [{"values": [value]}],
            "row_count": 1,
        },
    }


def command_payload() -> dict[str, object]:
    return {
        "ok": True,
        "request_id": "r",
        "duration_ms": 1,
        "result": {"kind": "command", "affected_rows": 3, "last_insert_id": None},
    }


def client_for(status_code: int, payload: dict[str, object]) -> LiquidStoolapClient:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(status_code, json=payload, request=request)

    client = LiquidStoolapClient("http://testserver")
    client._client = httpx.Client(transport=httpx.MockTransport(handler), base_url="http://testserver")
    return client


def test_authentication_error_mapping() -> None:
    client = client_for(
        401,
        {"ok": False, "request_id": "r", "error": {"code": "invalid_token", "message": "bad token"}},
    )

    try:
        client.execute("SELECT 1")
    except AuthenticationError as exc:
        assert exc.code == "invalid_token"
        assert exc.status_code == 401
    else:
        raise AssertionError("401 should map to AuthenticationError")
    finally:
        client.close()


def test_sql_error_mapping() -> None:
    client = client_for(
        422,
        {"ok": False, "request_id": "r", "error": {"code": "sql_error", "message": "bad SQL"}},
    )

    try:
        client.execute("SELECT * FROM missing")
    except QueryError as exc:
        assert exc.code == "sql_error"
        assert exc.status_code == 422
    else:
        raise AssertionError("sql_error should map to QueryError")
    finally:
        client.close()


def test_validation_error_mapping() -> None:
    client = client_for(
        400,
        {"ok": False, "request_id": "r", "error": {"code": "invalid_request", "message": "bad request"}},
    )

    try:
        client.execute("")
    except ValidationError as exc:
        assert exc.code == "invalid_request"
        assert exc.status_code == 400
    else:
        raise AssertionError("400 should map to ValidationError")
    finally:
        client.close()


def test_server_error_mapping() -> None:
    client = client_for(
        503,
        {"ok": False, "request_id": "r", "error": {"code": "backend_unavailable", "message": "down"}},
    )

    try:
        client.execute("SELECT 1")
    except ServerError as exc:
        assert exc.code == "backend_unavailable"
        assert exc.status_code == 503
    else:
        raise AssertionError("503 should map to ServerError")
    finally:
        client.close()


def test_static_token_execute_and_helpers() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        assert request.headers["Authorization"] == "Bearer static-token"
        return httpx.Response(200, json=result_payload(7), request=request)

    client = LiquidStoolapClient("http://testserver", token="static-token")
    client._client = httpx.Client(
        transport=httpx.MockTransport(handler),
        base_url="http://testserver",
        headers={"Authorization": "Bearer static-token"},
    )
    try:
        result = client.execute("SELECT :id", {"id": 7})
        assert result.as_dicts() == [{"column1": 7}]
        assert client.fetch_all("SELECT 7") == [{"column1": 7}]
        assert client.fetch_one("SELECT 7") == {"column1": 7}
        assert client.scalar("SELECT 7") == 7
        assert requests[0].url.path == "/sql"
    finally:
        client.close()


def test_lazy_username_password_authentication() -> None:
    seen_paths: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen_paths.append(request.url.path)
        if request.url.path == "/auth/token":
            assert request.read() == b'{"username":"admin","password":"secret"}'
            return httpx.Response(
                200,
                json={"ok": True, "request_id": "auth", "token": {"access_token": "issued", "token_type": "Bearer", "expires_in": 3600}},
                request=request,
            )
        assert request.headers["Authorization"] == "Bearer issued"
        return httpx.Response(200, json=result_payload(9), request=request)

    client = LiquidStoolapClient("http://testserver", username="admin", password="secret")
    client._client = httpx.Client(transport=httpx.MockTransport(handler), base_url="http://testserver")
    try:
        assert client.scalar("SELECT 9") == 9
        assert client.token == "issued"
        assert seen_paths == ["/auth/token", "/sql"]
    finally:
        client.close()


def test_command_and_raw_execute() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=command_payload(), request=request)

    client = LiquidStoolapClient("http://testserver", token="token")
    client._client = httpx.Client(
        transport=httpx.MockTransport(handler),
        base_url="http://testserver",
        headers={"Authorization": "Bearer token"},
    )
    try:
        command = client.command("CREATE TABLE t (id INTEGER)")
        assert command.affected_rows == 3
        raw = client.raw_execute("CREATE TABLE t2 (id INTEGER)")
        assert raw.request_id == "r"
        assert raw.result.kind == "command"
    finally:
        client.close()


def test_async_client_success_path() -> None:
    async def run() -> None:
        def handler(request: httpx.Request) -> httpx.Response:
            assert request.headers["Authorization"] == "Bearer token"
            assert request.url.path == "/sql"
            return httpx.Response(
                200,
                json={
                    "ok": True,
                    "request_id": "r",
                    "duration_ms": 1,
                    "result": {
                            "kind": "result_set",
                            "columns": ["column1"],
                            "types": ["INTEGER"],
                            "rows": [{"values": [42]}],
                            "row_count": 1,
                        },
                },
                request=request,
            )

        client = AsyncLiquidStoolapClient("http://testserver", token="token")
        client._client = httpx.AsyncClient(
            transport=httpx.MockTransport(handler),
            base_url="http://testserver",
            headers={"Authorization": "Bearer token"},
        )
        try:
            result = await client.execute("SELECT :id", {"id": 42}, timeout_ms=1000)
            assert result.as_dicts() == [{"column1": 42}]
        finally:
            await client.aclose()

    asyncio.run(run())
