from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterator, Literal

ScalarValue = str | int | float | bool | None


@dataclass(slots=True)
class Row:
    values: list[ScalarValue]


@dataclass(slots=True)
class SqlResultSet:
    kind: Literal["result_set"]
    columns: list[str]
    types: list[str]
    rows: list[Row]
    row_count: int
    truncated: bool = False

    def as_dicts(self) -> list[dict[str, ScalarValue]]:
        return [dict(zip(self.columns, row.values)) for row in self.rows]

    def as_tuples(self) -> list[tuple[ScalarValue, ...]]:
        return [tuple(row.values) for row in self.rows]

    def first(self) -> dict[str, ScalarValue] | None:
        rows = self.as_dicts()
        if not rows:
            return None
        return rows[0]

    def scalar(self) -> ScalarValue:
        if not self.rows or not self.rows[0].values:
            return None
        return self.rows[0].values[0]

    def __len__(self) -> int:
        return self.row_count

    def __iter__(self) -> Iterator[dict[str, ScalarValue]]:
        return iter(self.as_dicts())


@dataclass(slots=True)
class SqlCommandResult:
    kind: Literal["command"]
    affected_rows: int | None
    last_insert_id: str | int | float | None


@dataclass(slots=True)
class SqlResponse:
    ok: bool
    request_id: str
    duration_ms: int
    result: SqlResultSet | SqlCommandResult


SqlExecutionResult = SqlResultSet | SqlCommandResult


@dataclass(slots=True)
class TokenResponse:
    access_token: str
    token_type: str
    expires_in: int


@dataclass(slots=True)
class HealthResponse:
    ok: bool
    status: str
    version: str
    uptime_s: int
    ready: bool
    auth_enabled: bool
    request_id: str | None = None
    reason: str | None = None


def parse_result(payload: dict[str, Any]) -> SqlResultSet | SqlCommandResult:
    kind = payload.get("kind")
    if kind == "result_set":
        return SqlResultSet(
            kind="result_set",
            columns=list(payload["columns"]),
            types=list(payload["types"]),
            rows=[Row(values=list(row["values"])) for row in payload["rows"]],
            row_count=int(payload["row_count"]),
            truncated=bool(payload.get("truncated", False)),
        )
    if kind == "command":
        return SqlCommandResult(
            kind="command",
            affected_rows=payload.get("affected_rows"),
            last_insert_id=payload.get("last_insert_id"),
        )
    raise ValueError(f"unknown result kind: {kind!r}")
