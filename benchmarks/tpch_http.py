#!/usr/bin/env python3
"""TPC-H inspired HTTP benchmark for the Liquid Stoolap server.

This is not an official TPC-H result. It uses a small deterministic schema and
TPC-H-shaped analytical queries executed through the public `/sql` endpoint.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from statistics import mean, median


ROOT = Path(__file__).resolve().parents[1]
SERVER_DIR = ROOT / "server"
SERVER_BIN = SERVER_DIR / "build" / "liquidstoolap"
LIBSTOOLAP = ROOT / ".cargo-target" / "release" / "libstoolap.so"


def post_json(url: str, body: dict, token: str | None = None, timeout: float = 120.0) -> dict:
    data = json.dumps(body).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        payload = exc.read().decode("utf-8")
        raise RuntimeError(f"HTTP {exc.code}: {payload}") from exc


def get_json(url: str, timeout: float = 5.0) -> dict:
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * pct)))
    return ordered[idx]


class Server:
    def __init__(self, port: int) -> None:
        self.port = port
        self.tmp = tempfile.TemporaryDirectory(prefix="liquidstoolap-tpch-")
        self.base = f"http://127.0.0.1:{port}"
        self.proc: subprocess.Popen[str] | None = None

    def __enter__(self) -> "Server":
        tmp_path = Path(self.tmp.name)
        password_file = tmp_path / "admin.password"
        config_file = tmp_path / "config.ini"
        log_file = tmp_path / "server.log"
        password_file.write_text("secret\n", encoding="utf-8")
        config_file.write_text(
            f"""[server]
host = 127.0.0.1
port = {self.port}
base_path = /
request_body_limit_bytes = 1048576
max_concurrent_requests = 32
cors_enabled = false
cors_allow_origin = *
health_requires_auth = false

[stoolap]
library_path = {LIBSTOOLAP}
database_path = memory://
read_only = false
busy_timeout_ms = 5000
startup_check = true

[auth]
enabled = true
issue_tokens = true
username = admin
password_file = {password_file}
token_ttl_seconds = 3600
allow_static_tokens = false
static_tokens_file =
token_revoke_on_restart = true

[timeouts]
request_timeout_ms = 120000
max_sql_timeout_ms = 120000
shutdown_grace_ms = 15000

[logging]
level = INFO
format = json
access_log = false
sql_log = false
redact_sql_params = true
include_request_id = true

[observability]
enable_metrics = false
metrics_bind_host = 127.0.0.1
metrics_port = 9095

[cli]
default_output = json
""",
            encoding="utf-8",
        )
        log = log_file.open("w", encoding="utf-8")
        self.proc = subprocess.Popen(
            [str(SERVER_BIN), "serve", "--config", str(config_file)],
            cwd=SERVER_DIR,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
        )
        for _ in range(100):
            if self.proc.poll() is not None:
                raise RuntimeError(f"server exited early; see {log_file}")
            try:
                health = get_json(f"{self.base}/health")
                if health.get("ready") is True:
                    return self
            except Exception:
                time.sleep(0.1)
        raise RuntimeError(f"server did not become ready; see {log_file}")

    def __exit__(self, *_exc: object) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        self.tmp.cleanup()


def sql(base: str, token: str, statement: str, timeout_ms: int = 120_000) -> dict:
    return post_json(f"{base}/sql", {"sql": statement, "timeout_ms": timeout_ms}, token=token, timeout=timeout_ms / 1000 + 5)


def setup_dataset(base: str, token: str, scale: int) -> list[tuple[str, float]]:
    customers = 5_000 * scale
    orders = 30_000 * scale
    lineitem = 120_000 * scale
    setup_sql = [
        "CREATE TABLE nation (n_nationkey INTEGER PRIMARY KEY, n_name TEXT, n_regionkey INTEGER)",
        "CREATE TABLE customer (c_custkey INTEGER PRIMARY KEY, c_nationkey INTEGER, c_mktsegment TEXT)",
        "CREATE TABLE orders (o_orderkey INTEGER PRIMARY KEY, o_custkey INTEGER, o_orderdate TEXT, o_totalprice FLOAT)",
        "CREATE TABLE lineitem (l_orderkey INTEGER, l_partkey INTEGER, l_quantity INTEGER, l_extendedprice FLOAT, l_discount FLOAT, l_shipdate TEXT, l_returnflag TEXT, l_linestatus TEXT)",
        "INSERT INTO nation SELECT value, CASE WHEN value % 5 = 0 THEN 'AMERICA' WHEN value % 5 = 1 THEN 'EUROPE' WHEN value % 5 = 2 THEN 'ASIA' WHEN value % 5 = 3 THEN 'AFRICA' ELSE 'MIDDLE EAST' END, value % 5 FROM generate_series(0, 24) AS g(value)",
        f"INSERT INTO customer SELECT value, value % 25, CASE WHEN value % 5 = 0 THEN 'BUILDING' WHEN value % 5 = 1 THEN 'AUTOMOBILE' WHEN value % 5 = 2 THEN 'MACHINERY' WHEN value % 5 = 3 THEN 'HOUSEHOLD' ELSE 'FURNITURE' END FROM generate_series(1, {customers}) AS g(value)",
        f"INSERT INTO orders SELECT value, (value % {customers}) + 1, CASE WHEN value % 3 = 0 THEN '1995-03-15' WHEN value % 3 = 1 THEN '1994-11-20' ELSE '1996-07-01' END, value * 1.37 FROM generate_series(1, {orders}) AS g(value)",
        f"INSERT INTO lineitem SELECT (value % {orders}) + 1, value % 20000, (value % 50) + 1, value * 0.91, (value % 10) / 100.0, CASE WHEN value % 3 = 0 THEN '1998-08-01' WHEN value % 3 = 1 THEN '1995-03-10' ELSE '1994-01-15' END, CASE WHEN value % 2 = 0 THEN 'R' ELSE 'N' END, CASE WHEN value % 2 = 0 THEN 'O' ELSE 'F' END FROM generate_series(1, {lineitem}) AS g(value)",
        "CREATE INDEX idx_customer_nation ON customer(c_nationkey)",
        "CREATE INDEX idx_orders_cust ON orders(o_custkey)",
        "CREATE INDEX idx_lineitem_order ON lineitem(l_orderkey)",
        "CREATE INDEX idx_lineitem_shipdate ON lineitem(l_shipdate)",
    ]
    timings: list[tuple[str, float]] = []
    for statement in setup_sql:
        start = time.perf_counter()
        sql(base, token, statement)
        timings.append((statement.split()[0] + " " + statement.split()[1], (time.perf_counter() - start) * 1000))
    return timings


QUERIES = {
    "Q1-pricing-summary": """
        SELECT l_returnflag, l_linestatus, SUM(l_quantity), SUM(l_extendedprice), AVG(l_discount), COUNT(*)
        FROM lineitem
        WHERE l_shipdate <= '1998-09-02'
        GROUP BY l_returnflag, l_linestatus
    """,
    "Q3-shipping-priority": """
        SELECT o.o_orderkey, SUM(l.l_extendedprice * (1 - l.l_discount)) AS revenue
        FROM customer c
        JOIN orders o ON c.c_custkey = o.o_custkey
        JOIN lineitem l ON l.l_orderkey = o.o_orderkey
        WHERE c.c_mktsegment = 'BUILDING' AND o.o_orderdate < '1995-03-15' AND l.l_shipdate > '1995-03-15'
        GROUP BY o.o_orderkey
        ORDER BY revenue DESC
        LIMIT 10
    """,
    "Q5-local-supplier-volume": """
        SELECT n.n_name, SUM(l.l_extendedprice * (1 - l.l_discount)) AS revenue
        FROM customer c
        JOIN orders o ON c.c_custkey = o.o_custkey
        JOIN lineitem l ON l.l_orderkey = o.o_orderkey
        JOIN nation n ON c.c_nationkey = n.n_nationkey
        WHERE o.o_orderdate >= '1994-01-01' AND o.o_orderdate < '1996-01-01'
        GROUP BY n.n_name
        ORDER BY revenue DESC
    """,
    "Q6-forecasting-revenue": """
        SELECT SUM(l_extendedprice * l_discount) AS revenue
        FROM lineitem
        WHERE l_shipdate >= '1994-01-01' AND l_shipdate < '1995-01-01'
          AND l_discount >= 0.05 AND l_discount <= 0.07
          AND l_quantity < 24
    """,
}


def run_query_bench(base: str, token: str, repeats: int) -> list[dict]:
    results = []
    for name, statement in QUERIES.items():
        sql(base, token, statement)
        samples = []
        backend_ms = []
        rows = 0
        for _ in range(repeats):
            start = time.perf_counter()
            response = sql(base, token, statement)
            elapsed_ms = (time.perf_counter() - start) * 1000
            samples.append(elapsed_ms)
            backend_ms.append(float(response.get("duration_ms", 0)))
            result = response["result"]
            rows = int(result.get("row_count", 0))
        results.append(
            {
                "query": name,
                "rows": rows,
                "client_avg_ms": mean(samples),
                "client_median_ms": median(samples),
                "client_p95_ms": percentile(samples, 0.95),
                "backend_avg_ms": mean(backend_ms),
                "min_ms": min(samples),
                "max_ms": max(samples),
            }
        )
    return results


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8331)
    parser.add_argument("--scale", type=int, default=1, help="1 = 5k customers, 30k orders, 120k lineitems")
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--json-out", type=Path, default=ROOT / "benchmarks" / "tpch_http_results.json")
    args = parser.parse_args()

    if not SERVER_BIN.exists():
        subprocess.check_call(["make", "build"], cwd=SERVER_DIR)
    if not LIBSTOOLAP.exists():
        raise SystemExit(f"missing {LIBSTOOLAP}; build Stoolap FFI first")

    with Server(args.port) as server:
        token_response = post_json(
            f"{server.base}/auth/token",
            {"username": "admin", "password": "secret"},
            timeout=5,
        )
        token = token_response["token"]["access_token"]
        setup = setup_dataset(server.base, token, args.scale)
        query_results = run_query_bench(server.base, token, args.repeats)

    output = {
        "benchmark": "TPC-H inspired HTTP benchmark",
        "official_tpc_result": False,
        "scale": args.scale,
        "repeats": args.repeats,
        "rows": {
            "customer": 5_000 * args.scale,
            "orders": 30_000 * args.scale,
            "lineitem": 120_000 * args.scale,
        },
        "setup_ms": [{"step": step, "duration_ms": ms} for step, ms in setup],
        "queries": query_results,
    }
    args.json_out.parent.mkdir(parents=True, exist_ok=True)
    args.json_out.write_text(json.dumps(output, indent=2), encoding="utf-8")

    print("TPC-H inspired HTTP benchmark")
    print(f"scale={args.scale} repeats={args.repeats}")
    print("query                         rows   avg_ms  median_ms  p95_ms  backend_avg_ms")
    for item in query_results:
        print(
            f"{item['query']:<28} {item['rows']:>5} "
            f"{item['client_avg_ms']:>8.2f} {item['client_median_ms']:>10.2f} "
            f"{item['client_p95_ms']:>7.2f} {item['backend_avg_ms']:>15.2f}"
        )
    print(f"wrote {args.json_out}")


if __name__ == "__main__":
    os.chdir(ROOT)
    main()
