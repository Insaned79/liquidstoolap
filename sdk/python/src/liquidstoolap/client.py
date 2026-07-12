from __future__ import annotations

from typing import Any

import httpx

from .exceptions import (
    AuthenticationError,
    AuthorizationError,
    LiquidStoolapError,
    QueryError,
    ServerError,
    TimeoutError,
    TransportError,
    ValidationError,
)
from .models import HealthResponse, ScalarValue, SqlCommandResult, SqlExecutionResult, SqlResponse, SqlResultSet, TokenResponse, parse_result


def _parse_health(data: dict[str, Any]) -> HealthResponse:
    return HealthResponse(
        ok=bool(data["ok"]),
        status=str(data["status"]),
        version=str(data["version"]),
        uptime_s=int(data["uptime_s"]),
        ready=bool(data["ready"]),
        auth_enabled=bool(data["auth_enabled"]),
        request_id=data.get("request_id"),
        reason=data.get("reason"),
    )


def _parse_token(data: dict[str, Any]) -> TokenResponse:
    token = data["token"]
    return TokenResponse(
        access_token=str(token["access_token"]),
        token_type=str(token["token_type"]),
        expires_in=int(token["expires_in"]),
    )


def _parse_sql_response(data: dict[str, Any]) -> SqlResponse:
    return SqlResponse(
        ok=bool(data["ok"]),
        request_id=str(data["request_id"]),
        duration_ms=int(data["duration_ms"]),
        result=parse_result(data["result"]),
    )


def _sql_body(sql: str, params: dict[str, object] | None, timeout_ms: int | None) -> dict[str, Any]:
    body: dict[str, Any] = {"sql": sql}
    if params is not None:
        body["params"] = params
    if timeout_ms is not None:
        body["timeout_ms"] = timeout_ms
    return body


def _raise_api_error(response: httpx.Response) -> None:
    code: str | None = None
    message = response.text
    try:
        error = response.json().get("error", {})
        code = error.get("code")
        message = error.get("message", message)
    except ValueError:
        pass

    if response.status_code == 401:
        raise AuthenticationError(message, code=code, status_code=response.status_code)
    if response.status_code == 403:
        raise AuthorizationError(message, code=code, status_code=response.status_code)
    if response.status_code in (400, 422):
        if code == "sql_error":
            raise QueryError(message, code=code, status_code=response.status_code)
        raise ValidationError(message, code=code, status_code=response.status_code)
    if response.status_code >= 500:
        raise ServerError(message, code=code, status_code=response.status_code)
    raise LiquidStoolapError(message, code=code, status_code=response.status_code)


class LiquidStoolapClient:
    def __init__(
        self,
        base_url: str,
        username: str | None = None,
        password: str | None = None,
        token: str | None = None,
        timeout: float = 30.0,
        verify: bool = True,
        headers: dict[str, str] | None = None,
        auto_authenticate: bool = True,
    ) -> None:
        self._username = username
        self._password = password
        self._token = token
        self._auto_authenticate = auto_authenticate
        client_headers = dict(headers or {})
        if token:
            client_headers["Authorization"] = f"Bearer {token}"
        self._client = httpx.Client(
            base_url=base_url.rstrip("/"),
            timeout=timeout,
            verify=verify,
            headers=client_headers,
        )

    def __enter__(self) -> "LiquidStoolapClient":
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        self.close()

    def close(self) -> None:
        self._client.close()

    @property
    def token(self) -> str | None:
        return self._token

    def set_token(self, token: str | None) -> None:
        self._token = token
        if token:
            self._client.headers["Authorization"] = f"Bearer {token}"
        else:
            self._client.headers.pop("Authorization", None)

    def health(self) -> HealthResponse:
        response = self._request("GET", "/health")
        return _parse_health(response.json())

    def authenticate(self, username: str, password: str) -> TokenResponse:
        response = self._request("POST", "/auth/token", json={"username": username, "password": password})
        token = _parse_token(response.json())
        self.set_token(token.access_token)
        return token

    def login(self, username: str | None = None, password: str | None = None) -> TokenResponse:
        if username is not None:
            self._username = username
        if password is not None:
            self._password = password
        if self._username is None or self._password is None:
            raise AuthenticationError("username and password are required for login")
        return self.authenticate(self._username, self._password)

    def execute(
        self,
        sql: str,
        params: dict[str, object] | None = None,
        timeout_ms: int | None = None,
    ) -> SqlExecutionResult:
        return self.raw_execute(sql, params, timeout_ms).result

    def raw_execute(
        self,
        sql: str,
        params: dict[str, object] | None = None,
        timeout_ms: int | None = None,
    ) -> SqlResponse:
        self._ensure_authenticated()
        response = self._request("POST", "/sql", json=_sql_body(sql, params, timeout_ms))
        return _parse_sql_response(response.json())

    def query(
        self,
        sql: str,
        params: dict[str, object] | None = None,
        timeout_ms: int | None = None,
    ) -> SqlResultSet:
        result = self.execute(sql, params, timeout_ms)
        if not isinstance(result, SqlResultSet):
            raise QueryError("SQL did not return a result set")
        return result

    def command(
        self,
        sql: str,
        params: dict[str, object] | None = None,
        timeout_ms: int | None = None,
    ) -> SqlCommandResult:
        result = self.execute(sql, params, timeout_ms)
        if not isinstance(result, SqlCommandResult):
            raise QueryError("SQL returned a result set, not a command result")
        return result

    def fetch_all(
        self,
        sql: str,
        params: dict[str, object] | None = None,
        timeout_ms: int | None = None,
    ) -> list[dict[str, ScalarValue]]:
        return self.query(sql, params, timeout_ms).as_dicts()

    def fetch_one(
        self,
        sql: str,
        params: dict[str, object] | None = None,
        timeout_ms: int | None = None,
    ) -> dict[str, ScalarValue] | None:
        return self.query(sql, params, timeout_ms).first()

    def scalar(
        self,
        sql: str,
        params: dict[str, object] | None = None,
        timeout_ms: int | None = None,
    ) -> ScalarValue:
        return self.query(sql, params, timeout_ms).scalar()

    def _ensure_authenticated(self) -> None:
        if self._token or not self._auto_authenticate:
            return
        if self._username is not None and self._password is not None:
            self.login()

    def _request(self, method: str, url: str, **kwargs: Any) -> httpx.Response:
        try:
            response = self._client.request(method, url, **kwargs)
        except httpx.TimeoutException as exc:
            raise TimeoutError(str(exc)) from exc
        except httpx.HTTPError as exc:
            raise TransportError(str(exc)) from exc

        if response.status_code >= 400:
            _raise_api_error(response)
        return response


class AsyncLiquidStoolapClient:
    def __init__(
        self,
        base_url: str,
        username: str | None = None,
        password: str | None = None,
        token: str | None = None,
        timeout: float = 30.0,
        verify: bool = True,
        headers: dict[str, str] | None = None,
        auto_authenticate: bool = True,
    ) -> None:
        self._username = username
        self._password = password
        self._token = token
        self._auto_authenticate = auto_authenticate
        client_headers = dict(headers or {})
        if token:
            client_headers["Authorization"] = f"Bearer {token}"
        self._client = httpx.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=timeout,
            verify=verify,
            headers=client_headers,
        )

    async def __aenter__(self) -> "AsyncLiquidStoolapClient":
        return self

    async def __aexit__(self, exc_type: object, exc: object, tb: object) -> None:
        await self.aclose()

    async def aclose(self) -> None:
        await self._client.aclose()

    @property
    def token(self) -> str | None:
        return self._token

    def set_token(self, token: str | None) -> None:
        self._token = token
        if token:
            self._client.headers["Authorization"] = f"Bearer {token}"
        else:
            self._client.headers.pop("Authorization", None)

    async def health(self) -> HealthResponse:
        response = await self._request("GET", "/health")
        return _parse_health(response.json())

    async def authenticate(self, username: str, password: str) -> TokenResponse:
        response = await self._request("POST", "/auth/token", json={"username": username, "password": password})
        token = _parse_token(response.json())
        self.set_token(token.access_token)
        return token

    async def login(self, username: str | None = None, password: str | None = None) -> TokenResponse:
        if username is not None:
            self._username = username
        if password is not None:
            self._password = password
        if self._username is None or self._password is None:
            raise AuthenticationError("username and password are required for login")
        return await self.authenticate(self._username, self._password)

    async def execute(
        self,
        sql: str,
        params: dict[str, object] | None = None,
        timeout_ms: int | None = None,
    ) -> SqlExecutionResult:
        return (await self.raw_execute(sql, params, timeout_ms)).result

    async def raw_execute(
        self,
        sql: str,
        params: dict[str, object] | None = None,
        timeout_ms: int | None = None,
    ) -> SqlResponse:
        await self._ensure_authenticated()
        response = await self._request("POST", "/sql", json=_sql_body(sql, params, timeout_ms))
        return _parse_sql_response(response.json())

    async def query(
        self,
        sql: str,
        params: dict[str, object] | None = None,
        timeout_ms: int | None = None,
    ) -> SqlResultSet:
        result = await self.execute(sql, params, timeout_ms)
        if not isinstance(result, SqlResultSet):
            raise QueryError("SQL did not return a result set")
        return result

    async def command(
        self,
        sql: str,
        params: dict[str, object] | None = None,
        timeout_ms: int | None = None,
    ) -> SqlCommandResult:
        result = await self.execute(sql, params, timeout_ms)
        if not isinstance(result, SqlCommandResult):
            raise QueryError("SQL returned a result set, not a command result")
        return result

    async def fetch_all(
        self,
        sql: str,
        params: dict[str, object] | None = None,
        timeout_ms: int | None = None,
    ) -> list[dict[str, ScalarValue]]:
        return (await self.query(sql, params, timeout_ms)).as_dicts()

    async def fetch_one(
        self,
        sql: str,
        params: dict[str, object] | None = None,
        timeout_ms: int | None = None,
    ) -> dict[str, ScalarValue] | None:
        return (await self.query(sql, params, timeout_ms)).first()

    async def scalar(
        self,
        sql: str,
        params: dict[str, object] | None = None,
        timeout_ms: int | None = None,
    ) -> ScalarValue:
        return (await self.query(sql, params, timeout_ms)).scalar()

    async def _ensure_authenticated(self) -> None:
        if self._token or not self._auto_authenticate:
            return
        if self._username is not None and self._password is not None:
            await self.login()

    async def _request(self, method: str, url: str, **kwargs: Any) -> httpx.Response:
        try:
            response = await self._client.request(method, url, **kwargs)
        except httpx.TimeoutException as exc:
            raise TimeoutError(str(exc)) from exc
        except httpx.HTTPError as exc:
            raise TransportError(str(exc)) from exc

        if response.status_code >= 400:
            _raise_api_error(response)
        return response


def connect(
    base_url: str,
    *,
    username: str | None = None,
    password: str | None = None,
    token: str | None = None,
    timeout: float = 30.0,
    verify: bool = True,
    headers: dict[str, str] | None = None,
    auto_authenticate: bool = True,
) -> LiquidStoolapClient:
    return LiquidStoolapClient(
        base_url,
        username=username,
        password=password,
        token=token,
        timeout=timeout,
        verify=verify,
        headers=headers,
        auto_authenticate=auto_authenticate,
    )


def connect_async(
    base_url: str,
    *,
    username: str | None = None,
    password: str | None = None,
    token: str | None = None,
    timeout: float = 30.0,
    verify: bool = True,
    headers: dict[str, str] | None = None,
    auto_authenticate: bool = True,
) -> AsyncLiquidStoolapClient:
    return AsyncLiquidStoolapClient(
        base_url,
        username=username,
        password=password,
        token=token,
        timeout=timeout,
        verify=verify,
        headers=headers,
        auto_authenticate=auto_authenticate,
    )
