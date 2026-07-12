from liquidstoolap import Row, SqlCommandResult, SqlResultSet
from liquidstoolap.models import parse_result


def test_result_set_as_dicts() -> None:
    result = SqlResultSet(
        kind="result_set",
        columns=["id", "name"],
        types=["INTEGER", "TEXT"],
        rows=[Row(values=[1, "one"])],
        row_count=1,
    )

    assert result.as_dicts() == [{"id": 1, "name": "one"}]
    assert result.as_tuples() == [(1, "one")]
    assert result.first() == {"id": 1, "name": "one"}
    assert result.scalar() == 1
    assert len(result) == 1
    assert list(result) == [{"id": 1, "name": "one"}]


def test_parse_result_set() -> None:
    result = parse_result(
        {
            "kind": "result_set",
            "columns": ["id", "active"],
            "types": ["INTEGER", "BOOLEAN"],
            "rows": [{"values": [7, True]}],
            "row_count": 1,
        }
    )

    assert isinstance(result, SqlResultSet)
    assert result.as_dicts() == [{"id": 7, "active": True}]


def test_parse_command_result() -> None:
    result = parse_result({"kind": "command", "affected_rows": 3, "last_insert_id": None})

    assert isinstance(result, SqlCommandResult)
    assert result.affected_rows == 3
    assert result.last_insert_id is None


def test_parse_unknown_result_kind() -> None:
    try:
        parse_result({"kind": "unexpected"})
    except ValueError as exc:
        assert "unknown result kind" in str(exc)
    else:
        raise AssertionError("unknown result kind should fail")
