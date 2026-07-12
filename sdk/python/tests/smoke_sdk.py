from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parents[3]
SERVER = ROOT / "server"
PORT = 8323


def wait_for_health() -> None:
    deadline = time.time() + 5
    while time.time() < deadline:
        try:
            response = httpx.get(f"http://127.0.0.1:{PORT}/health", timeout=0.2)
            if response.status_code == 200:
                return
        except httpx.HTTPError:
            pass
        time.sleep(0.1)
    raise RuntimeError("server did not become healthy")


def main() -> None:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

    from liquidstoolap import AuthenticationError, LiquidStoolapClient

    subprocess.run(["make", "build"], cwd=SERVER, check=True)

    build = SERVER / "build"
    password_file = build / "sdk-smoke.password"
    config_file = build / "sdk-smoke.ini"
    password_file.write_text("secret\n", encoding="utf-8")
    config = (ROOT / "config" / "config.example.ini").read_text(encoding="utf-8")
    config = config.replace("port = 8321", f"port = {PORT}")
    config = config.replace("password_file =", f"password_file = {password_file}")
    config = config.replace("database_path = ./data/stoolap.db", "database_path = memory://")
    config_file.write_text(config, encoding="utf-8")

    env = os.environ.copy()
    process = subprocess.Popen(
        [str(build / "liquidstoolap"), "serve", "--config", str(config_file)],
        cwd=SERVER,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
    )
    try:
        wait_for_health()

        with LiquidStoolapClient(f"http://127.0.0.1:{PORT}") as client:
            health = client.health()
            assert health.ready is True
            try:
                client.execute("SELECT 1")
            except AuthenticationError:
                pass
            else:
                raise AssertionError("execute without token should fail")

            token = client.authenticate("admin", "secret")

        with LiquidStoolapClient(f"http://127.0.0.1:{PORT}", token=token.access_token) as authed:
            result = authed.query("SELECT :id", {"id": 42})
            assert result.row_count == 1
            assert result.as_dicts() == [{"column1": 42}]
            assert authed.scalar("SELECT :id", {"id": 43}) == 43

            command = authed.command("CREATE TABLE sdk_smoke (id INTEGER)")
            assert command.kind == "command"

        with LiquidStoolapClient(f"http://127.0.0.1:{PORT}", username="admin", password="secret") as lazy:
            assert lazy.fetch_one("SELECT :id", {"id": 44}) == {"column1": 44}

        print("sdk smoke ok")
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


if __name__ == "__main__":
    main()
