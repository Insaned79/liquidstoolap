#!/usr/bin/env python3
"""Network DB benchmark suite for Liquid, Firebird, MySQL, and PostgreSQL.

The suite runs from the local machine and connects to every database over TCP.
The workloads are TPC-C/TPC-H/TPC-DS inspired, not official TPC results.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from statistics import mean, median
from typing import Any

import pymysql
import psycopg2
from firebird.driver import connect as fb_connect
from firebird.driver import create_database as fb_create_database


ROOT = Path(__file__).resolve().parents[1]
REMOTE_ROOT = "~/liquidstoolap-bench/LiquidStoolap"


def pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round((len(ordered) - 1) * p))]


def run(cmd: list[str], *, input_text: str | None = None, timeout: int = 120) -> str:
    proc = subprocess.run(cmd, input=input_text, text=True, capture_output=True, timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(cmd)}\nstdout={proc.stdout}\nstderr={proc.stderr}")
    return proc.stdout


def ssh(host: str, command: str, *, timeout: int = 120) -> str:
    return run(["ssh", host, command], timeout=timeout)


def sudo_ssh(host: str, password: str, command: str, *, timeout: int = 300) -> str:
    wrapped = f"sudo -S -p '' bash -lc {json.dumps(command)}"
    return run(["ssh", "-tt", host, wrapped], input_text=password + "\n", timeout=timeout)


def wait_port(host: str, port: int, timeout_s: float = 60.0) -> None:
    deadline = time.time() + timeout_s
    last_error: Exception | None = None
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=2):
                return
        except OSError as exc:
            last_error = exc
            time.sleep(0.5)
    raise RuntimeError(f"{host}:{port} not reachable: {last_error}")


def http_post_json(url: str, body: dict[str, Any], token: str | None = None, timeout: float = 180.0) -> dict[str, Any]:
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        payload = exc.read().decode()
        raise RuntimeError(f"HTTP {exc.code}: {payload}") from exc


def sql_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


class Engine:
    name: str
    supports_tx = True

    def execute(self, sql: str) -> None:
        raise NotImplementedError

    def query(self, sql: str) -> list[tuple[Any, ...]]:
        raise NotImplementedError

    def begin(self) -> None:
        pass

    def commit(self) -> None:
        pass

    def rollback(self) -> None:
        pass

    def close(self) -> None:
        pass

    def limit10(self) -> str:
        return "LIMIT 10"

    def ddl(self, sql: str) -> str:
        return sql

    def insert_values(self, table: str, values: list[str]) -> None:
        self.execute(f"INSERT INTO {table} VALUES " + ",".join(values))


class LiquidEngine(Engine):
    name = "liquid-stoolap"
    supports_tx = False

    def __init__(self, base_url: str, password: str) -> None:
        token = http_post_json(f"{base_url}/auth/token", {"username": "admin", "password": password}, timeout=10)
        self.base_url = base_url
        self.token = token["token"]["access_token"]

    def _sql(self, statement: str) -> dict[str, Any]:
        return http_post_json(f"{self.base_url}/sql", {"sql": statement, "timeout_ms": 180_000}, self.token, timeout=190)

    def execute(self, sql: str) -> None:
        self._sql(sql)

    def query(self, sql: str) -> list[tuple[Any, ...]]:
        response = self._sql(sql)
        rows = response["result"].get("rows", [])
        return [tuple(row["values"]) for row in rows]

    def ddl(self, sql: str) -> str:
        return re.sub(r"VARCHAR\(\d+\)", "TEXT", sql)


class MySqlEngine(Engine):
    name = "mysql"

    def __init__(self, host: str, port: int, password: str) -> None:
        self.con = pymysql.connect(host=host, port=port, user="root", password=password, database="bench", autocommit=False)

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


class PostgresEngine(Engine):
    name = "postgres"

    def __init__(self, host: str, port: int, password: str) -> None:
        self.con = psycopg2.connect(host=host, port=port, user="postgres", password=password, dbname="bench")
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


class FirebirdEngine(Engine):
    name = "firebird"

    def __init__(self, host: str, port: int, db_path: str, password: str) -> None:
        dsn = f"{host}/{port}:{db_path}"
        self.con = fb_create_database(
            dsn,
            user="SYSDBA",
            password=password,
            charset="UTF8",
            overwrite=True,
            auth_plugin_list="Srp256,Srp,Legacy_Auth",
        )
        self.in_tx = False

    def execute(self, sql: str) -> None:
        cur = self.con.cursor()
        cur.execute(sql)
        if not self.in_tx:
            self.con.commit()

    def query(self, sql: str) -> list[tuple[Any, ...]]:
        cur = self.con.cursor()
        cur.execute(sql)
        return list(cur.fetchall())

    def begin(self) -> None:
        self.in_tx = True

    def commit(self) -> None:
        try:
            self.con.commit()
        except AssertionError:
            pass
        self.in_tx = False

    def rollback(self) -> None:
        try:
            self.con.rollback()
        except AssertionError:
            pass
        self.in_tx = False

    def close(self) -> None:
        self.con.close()

    def limit10(self) -> str:
        return "ROWS 10"

    def insert_values(self, table: str, values: list[str]) -> None:
        for start in range(0, len(values), 200):
            selects = []
            for raw in values[start:start + 200]:
                row = raw.strip()
                if row.startswith("(") and row.endswith(")"):
                    row = row[1:-1]
                selects.append(f"SELECT {row} FROM RDB$DATABASE")
            self.execute(f"INSERT INTO {table} " + " UNION ALL ".join(selects))


def timed(label: str, fn) -> dict[str, Any]:
    start = time.perf_counter()
    result = fn()
    return {"step": label, "duration_ms": (time.perf_counter() - start) * 1000, "result": result}


def setup_tpch(engine: Engine, scale: int) -> list[dict[str, Any]]:
    c = 2_000 * scale
    o = 12_000 * scale
    l = 48_000 * scale
    stmts = [
        "CREATE TABLE nation (n_nationkey INTEGER PRIMARY KEY, n_name VARCHAR(32), n_regionkey INTEGER)",
        "CREATE TABLE customer (c_custkey INTEGER PRIMARY KEY, c_nationkey INTEGER, c_mktsegment VARCHAR(32))",
        "CREATE TABLE orders_t (o_orderkey INTEGER PRIMARY KEY, o_custkey INTEGER, o_orderdate VARCHAR(16), o_totalprice FLOAT)",
        "CREATE TABLE lineitem (l_orderkey INTEGER, l_partkey INTEGER, l_quantity INTEGER, l_extendedprice FLOAT, l_discount FLOAT, l_shipdate VARCHAR(16), l_returnflag VARCHAR(1), l_linestatus VARCHAR(1))",
    ]
    setup = []
    for stmt in stmts:
        setup.append(timed(stmt.split()[1], lambda s=stmt: engine.execute(engine.ddl(s))))
    if isinstance(engine, LiquidEngine):
        inserts = [
            "INSERT INTO nation SELECT value, CASE WHEN value % 5 = 0 THEN 'AMERICA' WHEN value % 5 = 1 THEN 'EUROPE' WHEN value % 5 = 2 THEN 'ASIA' WHEN value % 5 = 3 THEN 'AFRICA' ELSE 'MIDDLE EAST' END, value % 5 FROM generate_series(0, 24) AS g(value)",
            f"INSERT INTO customer SELECT value, value % 25, CASE WHEN value % 5 = 0 THEN 'BUILDING' WHEN value % 5 = 1 THEN 'AUTOMOBILE' WHEN value % 5 = 2 THEN 'MACHINERY' WHEN value % 5 = 3 THEN 'HOUSEHOLD' ELSE 'FURNITURE' END FROM generate_series(1, {c}) AS g(value)",
            f"INSERT INTO orders_t SELECT value, (value % {c}) + 1, CASE WHEN value % 3 = 0 THEN '1995-03-15' WHEN value % 3 = 1 THEN '1994-11-20' ELSE '1996-07-01' END, value * 1.37 FROM generate_series(1, {o}) AS g(value)",
            f"INSERT INTO lineitem SELECT (value % {o}) + 1, value % 20000, (value % 50) + 1, value * 0.91, (value % 10) / 100.0, CASE WHEN value % 3 = 0 THEN '1998-08-01' WHEN value % 3 = 1 THEN '1995-03-10' ELSE '1994-01-15' END, CASE WHEN value % 2 = 0 THEN 'R' ELSE 'N' END, CASE WHEN value % 2 = 0 THEN 'O' ELSE 'F' END FROM generate_series(1, {l}) AS g(value)",
        ]
        for stmt in inserts:
            setup.append(timed("insert", lambda s=stmt: engine.execute(s)))
    else:
        setup.append(timed("insert nation", lambda: [engine.execute(f"INSERT INTO nation VALUES ({i}, {sql_quote(['AMERICA','EUROPE','ASIA','AFRICA','MIDDLE EAST'][i % 5])}, {i % 5})") for i in range(25)]))
        for start in range(1, c + 1, 1000):
            values = []
            for i in range(start, min(c + 1, start + 1000)):
                seg = ["BUILDING", "AUTOMOBILE", "MACHINERY", "HOUSEHOLD", "FURNITURE"][i % 5]
                values.append(f"({i},{i % 25},{sql_quote(seg)})")
            setup.append(timed("insert customer", lambda v=values: engine.insert_values("customer", v)))
        for start in range(1, o + 1, 1000):
            values = []
            for i in range(start, min(o + 1, start + 1000)):
                dt = ["1995-03-15", "1994-11-20", "1996-07-01"][i % 3]
                values.append(f"({i},{(i % c) + 1},{sql_quote(dt)},{i * 1.37})")
            setup.append(timed("insert orders", lambda v=values: engine.insert_values("orders_t", v)))
        for start in range(1, l + 1, 1000):
            values = []
            for i in range(start, min(l + 1, start + 1000)):
                dt = ["1998-08-01", "1995-03-10", "1994-01-15"][i % 3]
                rf = "R" if i % 2 == 0 else "N"
                ls = "O" if i % 2 == 0 else "F"
                values.append(f"({(i % o) + 1},{i % 20000},{(i % 50) + 1},{i * 0.91},{(i % 10) / 100.0},{sql_quote(dt)},{sql_quote(rf)},{sql_quote(ls)})")
            setup.append(timed("insert lineitem", lambda v=values: engine.insert_values("lineitem", v)))
    for stmt in [
        "CREATE INDEX idx_customer_nation ON customer(c_nationkey)",
        "CREATE INDEX idx_orders_cust ON orders_t(o_custkey)",
        "CREATE INDEX idx_lineitem_order ON lineitem(l_orderkey)",
        "CREATE INDEX idx_lineitem_shipdate ON lineitem(l_shipdate)",
    ]:
        setup.append(timed("index", lambda s=stmt: engine.execute(s)))
    return setup


def tpch_queries(engine: Engine) -> dict[str, str]:
    return {
        "H-Q1": "SELECT l_returnflag, l_linestatus, SUM(l_quantity), SUM(l_extendedprice), AVG(l_discount), COUNT(*) FROM lineitem WHERE l_shipdate <= '1998-09-02' GROUP BY l_returnflag, l_linestatus",
        "H-Q3": f"SELECT o.o_orderkey, SUM(l.l_extendedprice * (1 - l.l_discount)) AS revenue FROM customer c JOIN orders_t o ON c.c_custkey = o.o_custkey JOIN lineitem l ON l.l_orderkey = o.o_orderkey WHERE c.c_mktsegment = 'BUILDING' AND o.o_orderdate < '1995-03-15' AND l.l_shipdate > '1995-03-15' GROUP BY o.o_orderkey ORDER BY revenue DESC {engine.limit10()}",
        "H-Q5": "SELECT n.n_name, SUM(l.l_extendedprice * (1 - l.l_discount)) AS revenue FROM customer c JOIN orders_t o ON c.c_custkey = o.o_custkey JOIN lineitem l ON l.l_orderkey = o.o_orderkey JOIN nation n ON c.c_nationkey = n.n_nationkey WHERE o.o_orderdate >= '1994-01-01' AND o.o_orderdate < '1996-01-01' GROUP BY n.n_name ORDER BY revenue DESC",
        "H-Q6": "SELECT SUM(l_extendedprice * l_discount) AS revenue FROM lineitem WHERE l_shipdate >= '1994-01-01' AND l_shipdate < '1995-01-01' AND l_discount >= 0.05 AND l_discount <= 0.07 AND l_quantity < 24",
    }


def setup_tpcds(engine: Engine, scale: int) -> list[dict[str, Any]]:
    sales = 50_000 * scale
    stmts = [
        "CREATE TABLE date_dim (d_date_sk INTEGER PRIMARY KEY, d_year INTEGER, d_moy INTEGER)",
        "CREATE TABLE item (i_item_sk INTEGER PRIMARY KEY, i_category VARCHAR(32), i_class VARCHAR(32))",
        "CREATE TABLE customer_address (ca_address_sk INTEGER PRIMARY KEY, ca_state VARCHAR(8))",
        "CREATE TABLE customer_ds (c_customer_sk INTEGER PRIMARY KEY, c_current_addr_sk INTEGER)",
        "CREATE TABLE store_sales (ss_sold_date_sk INTEGER, ss_item_sk INTEGER, ss_customer_sk INTEGER, ss_quantity INTEGER, ss_sales_price FLOAT, ss_net_profit FLOAT)",
    ]
    setup = []
    for stmt in stmts:
        setup.append(timed(stmt.split()[1], lambda s=stmt: engine.execute(engine.ddl(s))))
    if isinstance(engine, LiquidEngine):
        inserts = [
            "INSERT INTO date_dim SELECT value, 1998 + (value % 5), (value % 12) + 1 FROM generate_series(1, 1825) AS g(value)",
            "INSERT INTO item SELECT value, CASE WHEN value % 4 = 0 THEN 'Books' WHEN value % 4 = 1 THEN 'Electronics' WHEN value % 4 = 2 THEN 'Home' ELSE 'Sports' END, CASE WHEN value % 3 = 0 THEN 'A' WHEN value % 3 = 1 THEN 'B' ELSE 'C' END FROM generate_series(1, 5000) AS g(value)",
            "INSERT INTO customer_address SELECT value, CASE WHEN value % 5 = 0 THEN 'CA' WHEN value % 5 = 1 THEN 'NY' WHEN value % 5 = 2 THEN 'TX' WHEN value % 5 = 3 THEN 'WA' ELSE 'FL' END FROM generate_series(1, 10000) AS g(value)",
            "INSERT INTO customer_ds SELECT value, value FROM generate_series(1, 10000) AS g(value)",
            f"INSERT INTO store_sales SELECT (value % 1825) + 1, (value % 5000) + 1, (value % 10000) + 1, (value % 20) + 1, value * 0.73, value * 0.11 FROM generate_series(1, {sales}) AS g(value)",
        ]
        for stmt in inserts:
            setup.append(timed("insert", lambda s=stmt: engine.execute(s)))
    else:
        def insert_rows(table: str, rows: list[str]) -> None:
            for start in range(0, len(rows), 1000):
                engine.insert_values(table, rows[start:start + 1000])
        setup.append(timed("insert date", lambda: insert_rows("date_dim", [f"({i},{1998 + (i % 5)},{(i % 12) + 1})" for i in range(1, 1826)])))
        setup.append(timed("insert item", lambda: insert_rows("item", [f"({i},{sql_quote(['Books','Electronics','Home','Sports'][i % 4])},{sql_quote(['A','B','C'][i % 3])})" for i in range(1, 5001)])))
        setup.append(timed("insert address", lambda: insert_rows("customer_address", [f"({i},{sql_quote(['CA','NY','TX','WA','FL'][i % 5])})" for i in range(1, 10001)])))
        setup.append(timed("insert customer", lambda: insert_rows("customer_ds", [f"({i},{i})" for i in range(1, 10001)])))
        setup.append(timed("insert sales", lambda: insert_rows("store_sales", [f"({(i % 1825) + 1},{(i % 5000) + 1},{(i % 10000) + 1},{(i % 20) + 1},{i * 0.73},{i * 0.11})" for i in range(1, sales + 1)])))
    for stmt in [
        "CREATE INDEX idx_ss_date ON store_sales(ss_sold_date_sk)",
        "CREATE INDEX idx_ss_item ON store_sales(ss_item_sk)",
        "CREATE INDEX idx_ss_customer ON store_sales(ss_customer_sk)",
    ]:
        setup.append(timed("index", lambda s=stmt: engine.execute(s)))
    return setup


def tpcds_queries(_engine: Engine) -> dict[str, str]:
    return {
        "DS-Q3": "SELECT i.i_category, d.d_year, d.d_moy, SUM(ss.ss_sales_price) FROM store_sales ss JOIN item i ON ss.ss_item_sk = i.i_item_sk JOIN date_dim d ON ss.ss_sold_date_sk = d.d_date_sk WHERE d.d_year = 2000 GROUP BY i.i_category, d.d_year, d.d_moy ORDER BY i.i_category, d.d_moy",
        "DS-Q7": "SELECT i.i_category, i.i_class, AVG(ss.ss_quantity), AVG(ss.ss_sales_price), AVG(ss.ss_net_profit) FROM store_sales ss JOIN item i ON ss.ss_item_sk = i.i_item_sk GROUP BY i.i_category, i.i_class",
        "DS-Q19": "SELECT ca.ca_state, SUM(ss.ss_sales_price), COUNT(*) FROM store_sales ss JOIN customer_ds c ON ss.ss_customer_sk = c.c_customer_sk JOIN customer_address ca ON c.c_current_addr_sk = ca.ca_address_sk GROUP BY ca.ca_state ORDER BY ca.ca_state",
    }


def setup_tpcc(engine: Engine, scale: int) -> list[dict[str, Any]]:
    districts = 5 * scale
    customers = 1000 * scale
    items = 2000 * scale
    stmts = [
        "CREATE TABLE warehouse (w_id INTEGER PRIMARY KEY, w_ytd FLOAT)",
        "CREATE TABLE district (d_w_id INTEGER, d_id INTEGER, d_ytd FLOAT, d_next_o_id INTEGER)",
        "CREATE TABLE customer_c (c_w_id INTEGER, c_d_id INTEGER, c_id INTEGER, c_balance FLOAT, c_ytd_payment FLOAT, c_delivery_cnt INTEGER)",
        "CREATE TABLE item_c (i_id INTEGER PRIMARY KEY, i_price FLOAT)",
        "CREATE TABLE stock (s_w_id INTEGER, s_i_id INTEGER, s_quantity INTEGER, s_ytd INTEGER)",
        "CREATE TABLE oorder (o_w_id INTEGER, o_d_id INTEGER, o_id INTEGER, o_c_id INTEGER, o_entry_d VARCHAR(24))",
        "CREATE TABLE new_order (no_w_id INTEGER, no_d_id INTEGER, no_o_id INTEGER)",
        "CREATE TABLE order_line (ol_w_id INTEGER, ol_d_id INTEGER, ol_o_id INTEGER, ol_i_id INTEGER, ol_quantity INTEGER, ol_amount FLOAT)",
    ]
    setup = []
    for stmt in stmts:
        setup.append(timed(stmt.split()[1], lambda s=stmt: engine.execute(engine.ddl(s))))
    if isinstance(engine, LiquidEngine):
        inserts = [
            "INSERT INTO warehouse VALUES (1, 0.0)",
            f"INSERT INTO district SELECT 1, value, 0.0, 1 FROM generate_series(1, {districts}) AS g(value)",
            f"INSERT INTO customer_c SELECT 1, ((value - 1) % {districts}) + 1, value, 0.0, 0.0, 0 FROM generate_series(1, {customers}) AS g(value)",
            f"INSERT INTO item_c SELECT value, (value % 100) + 1 FROM generate_series(1, {items}) AS g(value)",
            f"INSERT INTO stock SELECT 1, value, 100, 0 FROM generate_series(1, {items}) AS g(value)",
        ]
        for stmt in inserts:
            setup.append(timed("insert", lambda s=stmt: engine.execute(s)))
    else:
        setup.append(timed("insert warehouse", lambda: engine.execute("INSERT INTO warehouse VALUES (1,0.0)")))
        setup.append(timed("insert district", lambda: engine.insert_values("district", [f"(1,{i},0.0,1)" for i in range(1, districts + 1)])))
        setup.append(timed("insert customer", lambda: engine.insert_values("customer_c", [f"(1,{((i - 1) % districts) + 1},{i},0.0,0.0,0)" for i in range(1, customers + 1)])))
        setup.append(timed("insert item", lambda: engine.insert_values("item_c", [f"({i},{(i % 100) + 1})" for i in range(1, items + 1)])))
        for start in range(1, items + 1, 1000):
            vals = [f"(1,{i},100,0)" for i in range(start, min(items + 1, start + 1000))]
            setup.append(timed("insert stock", lambda v=vals: engine.insert_values("stock", v)))
    for stmt in [
        "CREATE INDEX idx_district ON district(d_w_id, d_id)",
        "CREATE INDEX idx_customer_c ON customer_c(c_w_id, c_d_id, c_id)",
        "CREATE INDEX idx_stock ON stock(s_w_id, s_i_id)",
    ]:
        setup.append(timed("index", lambda s=stmt: engine.execute(s)))
    return setup


def run_tpcc(engine: Engine, scale: int, tx_count: int) -> dict[str, Any]:
    rng = random.Random(42)
    districts = 5 * scale
    customers = 1000 * scale
    items = 2000 * scale
    latencies = []
    new_order_count = 0
    payment_count = 0
    start_all = time.perf_counter()
    for tx_id in range(1, tx_count + 1):
        start = time.perf_counter()
        try:
            engine.begin()
            d_id = rng.randint(1, districts)
            c_id = rng.randint(1, customers)
            if rng.random() < 0.6:
                new_order_count += 1
                rows = engine.query(f"SELECT d_next_o_id FROM district WHERE d_w_id = 1 AND d_id = {d_id}")
                next_id = int(rows[0][0]) if rows else tx_id
                engine.execute(f"UPDATE district SET d_next_o_id = {next_id + 1} WHERE d_w_id = 1 AND d_id = {d_id}")
                engine.execute(f"INSERT INTO oorder VALUES (1,{d_id},{next_id},{c_id},'2026-07-11')")
                engine.execute(f"INSERT INTO new_order VALUES (1,{d_id},{next_id})")
                for _ in range(5):
                    item_id = rng.randint(1, items)
                    qty = rng.randint(1, 5)
                    price = float(engine.query(f"SELECT i_price FROM item_c WHERE i_id = {item_id}")[0][0])
                    engine.execute(f"UPDATE stock SET s_quantity = s_quantity - {qty}, s_ytd = s_ytd + {qty} WHERE s_w_id = 1 AND s_i_id = {item_id}")
                    engine.execute(f"INSERT INTO order_line VALUES (1,{d_id},{next_id},{item_id},{qty},{price * qty})")
            else:
                payment_count += 1
                amount = rng.randint(1, 5000) / 100.0
                engine.execute(f"UPDATE warehouse SET w_ytd = w_ytd + {amount} WHERE w_id = 1")
                engine.execute(f"UPDATE district SET d_ytd = d_ytd + {amount} WHERE d_w_id = 1 AND d_id = {d_id}")
                engine.execute(f"UPDATE customer_c SET c_balance = c_balance - {amount}, c_ytd_payment = c_ytd_payment + {amount} WHERE c_w_id = 1 AND c_d_id = {d_id} AND c_id = {c_id}")
            engine.commit()
        except Exception:
            engine.rollback()
            raise
        latencies.append((time.perf_counter() - start) * 1000)
    total = time.perf_counter() - start_all
    return {
        "tx_count": tx_count,
        "new_order": new_order_count,
        "payment": payment_count,
        "supports_server_tx": engine.supports_tx,
        "tps": tx_count / total,
        "avg_ms": mean(latencies),
        "median_ms": median(latencies),
        "p95_ms": pct(latencies, 0.95),
        "min_ms": min(latencies),
        "max_ms": max(latencies),
    }


def run_query_set(engine: Engine, queries: dict[str, str], repeats: int) -> list[dict[str, Any]]:
    out = []
    for name, statement in queries.items():
        engine.query(statement)
        samples = []
        rows = 0
        for _ in range(repeats):
            start = time.perf_counter()
            result = engine.query(statement)
            samples.append((time.perf_counter() - start) * 1000)
            rows = len(result)
        out.append({"query": name, "rows": rows, "avg_ms": mean(samples), "median_ms": median(samples), "p95_ms": pct(samples, 0.95), "min_ms": min(samples), "max_ms": max(samples)})
    return out


def start_liquid(remote: str, host: str, port: int, remote_data_dir: str) -> None:
    ssh(remote, f"cd {REMOTE_ROOT} && rm -rf {remote_data_dir}/liquid && mkdir -p bench-runtime {remote_data_dir}/liquid && printf 'secret\\n' > bench-runtime/admin.password && cat > bench-runtime/liquid.ini <<'EOF'\n[server]\nhost = 0.0.0.0\nport = {port}\nbase_path = /\nrequest_body_limit_bytes = 1048576\nmax_concurrent_requests = 32\ncors_enabled = false\ncors_allow_origin = *\nhealth_requires_auth = false\n\n[stoolap]\nlibrary_path = /home/ilya/liquidstoolap-bench/LiquidStoolap/.cargo-target/release/libstoolap.so\ndatabase_path = {remote_data_dir}/liquid/stoolap.db\nread_only = false\nbusy_timeout_ms = 5000\nstartup_check = true\n\n[auth]\nenabled = true\nissue_tokens = true\nusername = admin\npassword_file = /home/ilya/liquidstoolap-bench/LiquidStoolap/bench-runtime/admin.password\ntoken_ttl_seconds = 3600\nallow_static_tokens = false\nstatic_tokens_file =\ntoken_revoke_on_restart = true\n\n[timeouts]\nrequest_timeout_ms = 180000\nmax_sql_timeout_ms = 180000\nshutdown_grace_ms = 15000\n\n[logging]\nlevel = INFO\nformat = json\naccess_log = false\nsql_log = false\nredact_sql_params = true\ninclude_request_id = true\n\n[observability]\nenable_metrics = false\nmetrics_bind_host = 127.0.0.1\nmetrics_port = 9095\n\n[cli]\ndefault_output = json\nEOF\nnohup server/build/liquidstoolap serve --config bench-runtime/liquid.ini > bench-runtime/liquid.log 2>&1 & echo $! > bench-runtime/liquid.pid")
    wait_port(host, port, 30)


def stop_liquid(remote: str) -> None:
    ssh(remote, f"cd {REMOTE_ROOT} && if test -f bench-runtime/liquid.pid; then kill -TERM $(cat bench-runtime/liquid.pid) >/dev/null 2>&1 || true; fi", timeout=20)


def start_container(remote: str, sudo_password: str, name: str, image: str, args: str, port: int, host: str) -> None:
    sudo_ssh(remote, sudo_password, f"docker rm -f {name} >/dev/null 2>&1 || true; docker run -d --name {name} {args} {image}", timeout=600)
    wait_port(host, port, 120)


def stop_container(remote: str, sudo_password: str, name: str) -> None:
    sudo_ssh(remote, sudo_password, f"docker rm -f {name} >/dev/null 2>&1 || true", timeout=120)


def prepare_remote_data(remote: str, sudo_password: str, remote_data_dir: str) -> str:
    allowed_prefix = "/home/ilya/liquidstoolap-bench/dbdata"
    if not remote_data_dir.startswith(allowed_prefix):
        raise ValueError(f"remote_data_dir must be inside {allowed_prefix}")
    sudo_ssh(
        remote,
        sudo_password,
        f"rm -rf {remote_data_dir}/liquid {remote_data_dir}/firebird {remote_data_dir}/mysql {remote_data_dir}/postgres && "
        f"mkdir -p {remote_data_dir}/liquid {remote_data_dir}/firebird {remote_data_dir}/mysql {remote_data_dir}/postgres && "
        f"chown -R ilya:ilya {remote_data_dir}",
        timeout=120,
    )
    return ssh(remote, f"df -P {remote_data_dir} {remote_data_dir}/liquid {remote_data_dir}/firebird {remote_data_dir}/mysql {remote_data_dir}/postgres", timeout=20)


def bench_engine(engine: Engine, scale: int, repeats: int, tx_count: int) -> dict[str, Any]:
    result: dict[str, Any] = {"engine": engine.name}
    result["tpch_setup"] = setup_tpch(engine, scale)
    result["tpch"] = run_query_set(engine, tpch_queries(engine), repeats)
    result["tpcds_setup"] = setup_tpcds(engine, scale)
    result["tpcds"] = run_query_set(engine, tpcds_queries(engine), repeats)
    result["tpcc_setup"] = setup_tpcc(engine, scale)
    result["tpcc"] = run_tpcc(engine, scale, tx_count)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="x86-test-host")
    parser.add_argument("--remote", default="user@x86-test-host")
    parser.add_argument("--sudo-password", default=os.environ.get("REMOTE_SUDO_PASSWORD", ""))
    parser.add_argument("--db-password", default=os.environ.get("BENCH_DB_PASSWORD", "benchpass"))
    parser.add_argument("--scale", type=int, default=1)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--tx-count", type=int, default=50)
    parser.add_argument("--remote-data-dir", default="/home/ilya/liquidstoolap-bench/dbdata")
    parser.add_argument("--out", type=Path, default=ROOT / "benchmarks" / "network_tpc_results.json")
    args = parser.parse_args()
    if not args.sudo_password:
        raise SystemExit("set --sudo-password or REMOTE_SUDO_PASSWORD")

    results: dict[str, Any] = {
        "official_tpc_result": False,
        "note": "TPC-C/TPC-H/TPC-DS inspired workloads over network TCP connections.",
        "host": args.host,
        "remote_data_dir": args.remote_data_dir,
        "scale": args.scale,
        "repeats": args.repeats,
        "tpcc_tx_count": args.tx_count,
        "engines": [],
    }
    results["data_filesystems"] = prepare_remote_data(args.remote, args.sudo_password, args.remote_data_dir)

    try:
        stop_liquid(args.remote)
        start_liquid(args.remote, args.host, 8321, args.remote_data_dir)
        liquid = LiquidEngine(f"http://{args.host}:8321", "secret")
        results["engines"].append(bench_engine(liquid, args.scale, args.repeats, args.tx_count))
    finally:
        stop_liquid(args.remote)

    start_container(
        args.remote,
        args.sudo_password,
        "liquid-bench-firebird",
        "ghcr.io/fdcastel/firebird:5.0.4-noble",
        f"-e FIREBIRD_ROOT_PASSWORD={args.db_password} -e FIREBIRD_PASSWORD={args.db_password} -e FIREBIRD_CONF_AuthServer=Srp256,Srp,Legacy_Auth -e FIREBIRD_CONF_USE_LEGACY_AUTH=True -e FIREBIRD_DATABASE_DEFAULT_CHARSET=UTF8 -p 3051:3050 -v {args.remote_data_dir}/firebird:/var/lib/firebird/data",
        3051,
        args.host,
    )
    try:
        fb = FirebirdEngine(args.host, 3051, "/var/lib/firebird/data/liquid_bench_network.fdb", args.db_password)
        try:
            results["engines"].append(bench_engine(fb, args.scale, args.repeats, args.tx_count))
        finally:
            fb.close()
    finally:
        stop_container(args.remote, args.sudo_password, "liquid-bench-firebird")

    start_container(args.remote, args.sudo_password, "liquid-bench-mysql", "mysql:8.4", f"-e MYSQL_ROOT_PASSWORD={args.db_password} -e MYSQL_DATABASE=bench -p 3307:3306 -v {args.remote_data_dir}/mysql:/var/lib/mysql", 3307, args.host)
    try:
        mysql = MySqlEngine(args.host, 3307, args.db_password)
        try:
            results["engines"].append(bench_engine(mysql, args.scale, args.repeats, args.tx_count))
        finally:
            mysql.close()
    finally:
        stop_container(args.remote, args.sudo_password, "liquid-bench-mysql")

    start_container(args.remote, args.sudo_password, "liquid-bench-postgres", "postgres:16", f"-e POSTGRES_PASSWORD={args.db_password} -e POSTGRES_DB=bench -p 5433:5432 -v {args.remote_data_dir}/postgres:/var/lib/postgresql/data", 5433, args.host)
    try:
        pg = PostgresEngine(args.host, 5433, args.db_password)
        try:
            results["engines"].append(bench_engine(pg, args.scale, args.repeats, args.tx_count))
        finally:
            pg.close()
    finally:
        stop_container(args.remote, args.sudo_password, "liquid-bench-postgres")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
