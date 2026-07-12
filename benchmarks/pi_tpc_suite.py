#!/usr/bin/env python3
"""Raspberry Pi network benchmark suite.

Runs TPC-H/TPC-DS inspired analytical workloads from this machine against
database servers listening on the Raspberry Pi. These are not official TPC
results.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import time
from pathlib import Path
from typing import Any

import pymysql
import psycopg2

from network_tpc_suite import (
    Engine,
    FirebirdEngine,
    LiquidEngine,
    ROOT,
    run_query_set,
    setup_tpcds,
    setup_tpch,
    ssh,
    sudo_ssh,
    tpcds_queries,
    tpch_queries,
    wait_port,
)


REMOTE_ROOT = "~/liquidstoolap-bench/LiquidStoolap"
REMOTE_ROOT_ABS = "/home/pi/liquidstoolap-bench/LiquidStoolap"


class PiMySqlEngine(Engine):
    name = "mariadb"

    def __init__(self, host: str, port: int, user: str, password: str) -> None:
        admin = pymysql.connect(host=host, port=port, user=user, password=password, database="mysql", autocommit=True)
        with admin.cursor() as cur:
            cur.execute("DROP DATABASE IF EXISTS bench")
            cur.execute("CREATE DATABASE bench")
        admin.close()
        self.con = pymysql.connect(host=host, port=port, user=user, password=password, database="bench", autocommit=False)

    def execute(self, sql: str) -> None:
        with self.con.cursor() as cur:
            cur.execute(sql)
        self.con.commit()

    def query(self, sql: str) -> list[tuple[Any, ...]]:
        with self.con.cursor() as cur:
            cur.execute(sql)
            rows = cur.fetchall()
        return list(rows)

    def begin(self) -> None:
        self.con.begin()

    def commit(self) -> None:
        self.con.commit()

    def rollback(self) -> None:
        self.con.rollback()

    def close(self) -> None:
        self.con.close()


class PiPostgresEngine(Engine):
    name = "postgres"

    def __init__(self, host: str, port: int, user: str, password: str) -> None:
        admin = psycopg2.connect(host=host, port=port, user=user, password=password, dbname="postgres")
        admin.autocommit = True
        with admin.cursor() as cur:
            cur.execute("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'bench'")
            cur.execute("DROP DATABASE IF EXISTS bench")
            cur.execute("CREATE DATABASE bench")
        admin.close()
        self.con = psycopg2.connect(host=host, port=port, user=user, password=password, dbname="bench")
        self.con.autocommit = False

    def execute(self, sql: str) -> None:
        with self.con.cursor() as cur:
            cur.execute(sql)
        self.con.commit()

    def query(self, sql: str) -> list[tuple[Any, ...]]:
        with self.con.cursor() as cur:
            cur.execute(sql)
            rows = cur.fetchall()
        return list(rows)

    def begin(self) -> None:
        self.con.autocommit = False

    def commit(self) -> None:
        self.con.commit()

    def rollback(self) -> None:
        self.con.rollback()

    def close(self) -> None:
        self.con.close()


def start_liquid(remote: str, host: str, port: int, remote_data_dir: str) -> None:
    ssh(
        remote,
        f"cd {REMOTE_ROOT} && "
        f"rm -rf {remote_data_dir}/liquid && mkdir -p bench-runtime {remote_data_dir}/liquid && "
        "printf 'secret\\n' > bench-runtime/admin.password && "
        f"cat > bench-runtime/liquid-pi.ini <<'EOF'\n"
        "[server]\n"
        "host = 0.0.0.0\n"
        f"port = {port}\n"
        "base_path = /\n"
        "request_body_limit_bytes = 1048576\n"
        "max_concurrent_requests = 8\n"
        "cors_enabled = false\n"
        "cors_allow_origin = *\n"
        "health_requires_auth = false\n"
        "\n"
        "[stoolap]\n"
        f"library_path = {REMOTE_ROOT_ABS}/.cargo-target/release/libstoolap.so\n"
        f"database_path = {remote_data_dir}/liquid/stoolap.db\n"
        "read_only = false\n"
        "busy_timeout_ms = 5000\n"
        "startup_check = true\n"
        "\n"
        "[auth]\n"
        "enabled = true\n"
        "issue_tokens = true\n"
        "username = admin\n"
        f"password_file = {REMOTE_ROOT_ABS}/bench-runtime/admin.password\n"
        "token_ttl_seconds = 3600\n"
        "allow_static_tokens = false\n"
        "static_tokens_file =\n"
        "token_revoke_on_restart = true\n"
        "\n"
        "[timeouts]\n"
        "request_timeout_ms = 180000\n"
        "max_sql_timeout_ms = 180000\n"
        "shutdown_grace_ms = 15000\n"
        "\n"
        "[logging]\n"
        "level = INFO\n"
        "format = json\n"
        "access_log = false\n"
        "sql_log = false\n"
        "redact_sql_params = true\n"
        "include_request_id = true\n"
        "\n"
        "[observability]\n"
        "enable_metrics = false\n"
        "metrics_bind_host = 127.0.0.1\n"
        "metrics_port = 9095\n"
        "\n"
        "[cli]\n"
        "default_output = json\n"
        "EOF\n"
        "nohup server/build/liquidstoolap serve --config bench-runtime/liquid-pi.ini "
        "> bench-runtime/liquid-pi.log 2>&1 & echo $! > bench-runtime/liquid-pi.pid",
        timeout=30,
    )
    wait_port(host, port, 60)


def stop_liquid(remote: str) -> None:
    ssh(
        remote,
        f"cd {REMOTE_ROOT} && "
        "if test -f bench-runtime/liquid-pi.pid; then "
        "kill -TERM $(cat bench-runtime/liquid-pi.pid) >/dev/null 2>&1 || true; "
        "fi",
        timeout=20,
    )


def bench_engine(engine: Engine, scale: int, repeats: int) -> dict[str, Any]:
    result: dict[str, Any] = {"engine": engine.name}
    result["tpch_setup"] = setup_tpch(engine, scale)
    result["tpch"] = run_query_set(engine, tpch_queries(engine), repeats)
    result["tpcds_setup"] = setup_tpcds(engine, scale)
    result["tpcds"] = run_query_set(engine, tpcds_queries(engine), repeats)
    return result


def read_liquid_log_tail(remote: str) -> str:
    try:
        return ssh(remote, f"cd {REMOTE_ROOT} && tail -n 80 bench-runtime/liquid-pi.log", timeout=20)
    except Exception as exc:
        return f"<failed to read liquid log: {exc}>"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="raspberry-pi-test-host")
    parser.add_argument("--remote", default="pi@raspberry-pi-test-host")
    parser.add_argument("--sudo-password", default=os.environ.get("PI_SUDO_PASSWORD", ""))
    parser.add_argument("--scale", type=int, default=1)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--remote-data-dir", default="/home/pi/liquidstoolap-bench/dbdata")
    parser.add_argument("--firebird-db", default="/var/lib/firebird/3.0/data/liquid_pi_bench.fdb")
    parser.add_argument("--password", default=os.environ.get("PI_DB_PASSWORD", ""))
    parser.add_argument("--out", type=Path, default=ROOT / "benchmarks" / "pi_tpc_results_scale1.json")
    args = parser.parse_args()
    if not args.sudo_password:
        raise SystemExit("set --sudo-password or PI_SUDO_PASSWORD")
    if not args.password:
        raise SystemExit("set --password or PI_DB_PASSWORD")

    results: dict[str, Any] = {
        "official_tpc_result": False,
        "note": "TPC-H/TPC-DS inspired analytical workloads over TCP; TPC-C intentionally omitted for this Pi run.",
        "host": args.host,
        "remote": args.remote,
        "remote_data_dir": args.remote_data_dir,
        "scale": args.scale,
        "repeats": args.repeats,
        "engines": [],
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }

    sudo_ssh(
        args.remote,
        args.sudo_password,
        f"mkdir -p {args.remote_data_dir}/liquid /var/lib/firebird/3.0/data && "
        f"chown -R pi:pi {args.remote_data_dir} && "
        "chown -R firebird:firebird /var/lib/firebird/3.0/data || true",
        timeout=120,
    )
    results["data_filesystems"] = ssh(
        args.remote,
        f"df -P {args.remote_data_dir} {args.remote_data_dir}/liquid /var/lib/postgresql /var/lib/mysql /var/lib/firebird/3.0/data 2>/dev/null || true",
        timeout=20,
    )
    results["omitted"] = {"tpcc": "Omitted: transaction-mix result is not comparable for the current Liquid HTTP adapter."}

    try:
        stop_liquid(args.remote)
        start_liquid(args.remote, args.host, 8321, args.remote_data_dir)
        liquid = LiquidEngine(f"http://{args.host}:8321", "secret")
        try:
            results["engines"].append(bench_engine(liquid, args.scale, args.repeats))
        except Exception as exc:
            results["engines"].append({"engine": "liquid-stoolap", "error": str(exc), "log_tail": read_liquid_log_tail(args.remote)})
        finally:
            stop_liquid(args.remote)

        fb = FirebirdEngine(args.host, 3050, args.firebird_db, args.password)
        try:
            results["engines"].append(bench_engine(fb, args.scale, args.repeats))
        finally:
            fb.close()

        mysql = PiMySqlEngine(args.host, 3306, "bench", args.password)
        try:
            results["engines"].append(bench_engine(mysql, args.scale, args.repeats))
        finally:
            mysql.close()

        pg = PiPostgresEngine(args.host, 5432, "bench", args.password)
        try:
            results["engines"].append(bench_engine(pg, args.scale, args.repeats))
        finally:
            pg.close()
    finally:
        stop_liquid(args.remote)

    results["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
