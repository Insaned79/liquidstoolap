#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PORT=8322
PASSWORD_FILE="$ROOT_DIR/build/smoke.password"
CONFIG_FILE="$ROOT_DIR/build/smoke.ini"
LOG_FILE="$ROOT_DIR/build/smoke.log"
STATIC_TOKEN_FILE="$ROOT_DIR/build/static.tokens"

printf 'secret\n' > "$PASSWORD_FILE"
printf 'lst_static_smoke\n' > "$STATIC_TOKEN_FILE"
sed \
  -e "s#port = 8321#port = $PORT#" \
  -e "s#password_file =#password_file = $PASSWORD_FILE#" \
  -e "s#database_path = ./data/stoolap.db#database_path = memory://#" \
  ../config/config.example.ini > "$CONFIG_FILE"

./build/liquidstoolap check-config --config "$CONFIG_FILE" >/dev/null

./build/liquidstoolap serve --config "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
SERVER_PID=$!
cleanup() {
  kill "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

health="$(curl -fsS "http://127.0.0.1:$PORT/health")"
grep -q '"ready" : true' <<<"$health"

cli_health="$(./build/liquidstoolap health --url "http://127.0.0.1:$PORT")"
grep -q '"ready" : true' <<<"$cli_health"

unauth_status="$(curl -sS -o /tmp/liquidstoolap-unauth.json -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PORT/sql" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT 1"}')"
test "$unauth_status" = "401"
grep -q '"code" : "invalid_token"' /tmp/liquidstoolap-unauth.json

token_response="$(curl -fsS \
  -X POST "http://127.0.0.1:$PORT/auth/token" \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"secret"}')"
token="$(sed -n 's/.*"access_token" : "\([^"]*\)".*/\1/p' <<<"$token_response")"
test -n "$token"

cli_token_response="$(./build/liquidstoolap token --url "http://127.0.0.1:$PORT" --username admin --password-file "$PASSWORD_FILE")"
cli_token="$(sed -n 's/.*"access_token" : "\([^"]*\)".*/\1/p' <<<"$cli_token_response")"
test -n "$cli_token"

select_response="$(curl -fsS \
  -X POST "http://127.0.0.1:$PORT/sql" \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT :id","params":{"id":42}}')"
grep -q '"kind" : "result_set"' <<<"$select_response"
grep -q '"values" : \[42\]' <<<"$select_response"

cli_select_response="$(./build/liquidstoolap sql --url "http://127.0.0.1:$PORT" --token "$cli_token" --sql "SELECT :id" --param id=43)"
grep -q '"values" : \[43\]' <<<"$cli_select_response"

command_response="$(curl -fsS \
  -X POST "http://127.0.0.1:$PORT/sql" \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"CREATE TABLE smoke_t (id INTEGER)"}')"
grep -q '"kind" : "command"' <<<"$command_response"

python3 - <<PY
import json
import urllib.request

base = "http://127.0.0.1:$PORT"
token = "$token"

def post(payload):
    req = urllib.request.Request(
        base + "/sql",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + token},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))

post({"sql": "CREATE TABLE unicode_t (name TEXT)"})
post({"sql": "INSERT INTO unicode_t VALUES ('Детская')"})
post({"sql": "INSERT INTO unicode_t VALUES (:name)", "params": {"name": "Спальня"}})
rows = post({"sql": "SELECT name FROM unicode_t"})["result"]["rows"]
values = [row["values"][0] for row in rows]
assert values == ["Детская", "Спальня"], values
PY

multi_status="$(curl -sS -o /tmp/liquidstoolap-multi.json -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PORT/sql" \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT 1; SELECT 2"}')"
test "$multi_status" = "422"
grep -q '"code" : "multi_statement_not_allowed"' /tmp/liquidstoolap-multi.json

invalid_json_status="$(curl -sS -o /tmp/liquidstoolap-invalid-json.json -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PORT/sql" \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -d '{"sql":')"
test "$invalid_json_status" = "400"
grep -q '"code" : "invalid_json"' /tmp/liquidstoolap-invalid-json.json

unknown_field_status="$(curl -sS -o /tmp/liquidstoolap-unknown-field.json -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PORT/sql" \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT 1","extra":true}' )"
test "$unknown_field_status" = "400"
grep -q '"message" : "unknown field: extra"' /tmp/liquidstoolap-unknown-field.json

invalid_params_status="$(curl -sS -o /tmp/liquidstoolap-invalid-params.json -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PORT/sql" \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT 1","params":[]}' )"
test "$invalid_params_status" = "400"
grep -q '"message" : "params must be an object"' /tmp/liquidstoolap-invalid-params.json

invalid_param_value_status="$(curl -sS -o /tmp/liquidstoolap-invalid-param-value.json -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PORT/sql" \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT 1","params":{"bad":[]}}' )"
test "$invalid_param_value_status" = "400"
grep -q '"message" : "params.bad must be a scalar value"' /tmp/liquidstoolap-invalid-param-value.json

invalid_timeout_status="$(curl -sS -o /tmp/liquidstoolap-invalid-timeout.json -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PORT/sql" \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT 1","timeout_ms":0}' )"
test "$invalid_timeout_status" = "400"
grep -q '"timeout_ms must be >= 1"' /tmp/liquidstoolap-invalid-timeout.json

float_timeout_status="$(curl -sS -o /tmp/liquidstoolap-float-timeout.json -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PORT/sql" \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT 1","timeout_ms":1.5}' )"
test "$float_timeout_status" = "400"
grep -q '"timeout_ms must be an integer"' /tmp/liquidstoolap-float-timeout.json

backend_timeout_status="$(curl -sS -o /tmp/liquidstoolap-backend-timeout.json -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PORT/sql" \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT SUM(value) FROM generate_series(1, 200000000) AS g(value)","timeout_ms":1}' )"
test "$backend_timeout_status" = "504"
grep -q '"code" : "backend_timeout"' /tmp/liquidstoolap-backend-timeout.json

bad_token_body_status="$(curl -sS -o /tmp/liquidstoolap-bad-token-body.json -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PORT/auth/token" \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"secret","extra":1}' )"
test "$bad_token_body_status" = "400"
grep -q '"message" : "unknown field: extra"' /tmp/liquidstoolap-bad-token-body.json

large_body_status="$(python3 - <<PY
import json
import urllib.error
import urllib.request
body = json.dumps({"sql": "SELECT 1", "pad": "x" * 1100000}).encode()
req = urllib.request.Request(
    "http://127.0.0.1:$PORT/sql",
    data=body,
    headers={"Content-Type": "application/json", "Authorization": "Bearer $token"},
    method="POST",
)
try:
    urllib.request.urlopen(req, timeout=5)
except urllib.error.HTTPError as exc:
    print(exc.code)
PY
)"
test "$large_body_status" = "400"

kill -TERM "$SERVER_PID"
for _ in $(seq 1 50); do
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if kill -0 "$SERVER_PID" >/dev/null 2>&1; then
  echo "server did not exit after SIGTERM" >&2
  exit 1
fi
wait "$SERVER_PID" >/dev/null 2>&1 || true

cleanup
trap - EXIT

STATIC_CONFIG="$ROOT_DIR/build/static.ini"
sed \
  -e "s#port = 8321#port = $PORT#" \
  -e "s#database_path = ./data/stoolap.db#database_path = memory://#" \
  -e "s#health_requires_auth = false#health_requires_auth = true#" \
  -e "s#issue_tokens = true#issue_tokens = false#" \
  -e "s#allow_static_tokens = false#allow_static_tokens = true#" \
  -e "s#static_tokens_file =#static_tokens_file = $STATIC_TOKEN_FILE#" \
  ../config/config.example.ini > "$STATIC_CONFIG"

./build/liquidstoolap check-config --config "$STATIC_CONFIG" >/dev/null
./build/liquidstoolap serve --config "$STATIC_CONFIG" > "$LOG_FILE" 2>&1 &
SERVER_PID=$!
trap cleanup EXIT
sleep 0.3

health_unauth_status="$(curl -sS -o /tmp/liquidstoolap-health-unauth.json -w '%{http_code}' \
  "http://127.0.0.1:$PORT/health")"
test "$health_unauth_status" = "401"

health_static="$(curl -fsS "http://127.0.0.1:$PORT/health" -H 'Authorization: Bearer lst_static_smoke')"
grep -q '"ready" : true' <<<"$health_static"

static_sql="$(curl -fsS \
  -X POST "http://127.0.0.1:$PORT/sql" \
  -H 'Authorization: Bearer lst_static_smoke' \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT 7"}')"
grep -q '"values" : \[7\]' <<<"$static_sql"

cleanup
trap - EXIT

BASEPATH_CONFIG="$ROOT_DIR/build/basepath.ini"
sed \
  -e "s#port = 8321#port = $PORT#" \
  -e "s#base_path = /#base_path = /api/v1#" \
  -e "s#password_file =#password_file = $PASSWORD_FILE#" \
  -e "s#database_path = ./data/stoolap.db#database_path = memory://#" \
  ../config/config.example.ini > "$BASEPATH_CONFIG"

./build/liquidstoolap check-config --config "$BASEPATH_CONFIG" >/dev/null
./build/liquidstoolap serve --config "$BASEPATH_CONFIG" > "$LOG_FILE" 2>&1 &
SERVER_PID=$!
trap cleanup EXIT
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/api/v1/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

root_health_status="$(curl -sS -o /tmp/liquidstoolap-root-health.json -w '%{http_code}' \
  "http://127.0.0.1:$PORT/health")"
test "$root_health_status" = "404"

base_token_response="$(curl -fsS \
  -X POST "http://127.0.0.1:$PORT/api/v1/auth/token" \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"secret"}')"
base_token="$(sed -n 's/.*"access_token" : "\([^"]*\)".*/\1/p' <<<"$base_token_response")"
test -n "$base_token"

base_cli_health="$(./build/liquidstoolap health --url "http://127.0.0.1:$PORT/api/v1")"
grep -q '"ready" : true' <<<"$base_cli_health"

base_sql="$(curl -fsS \
  -X POST "http://127.0.0.1:$PORT/api/v1/sql" \
  -H "Authorization: Bearer $base_token" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT 11"}')"
grep -q '"values" : \[11\]' <<<"$base_sql"

cleanup
trap - EXIT

READONLY_CONFIG="$ROOT_DIR/build/readonly.ini"
sed \
  -e "s#port = 8321#port = $PORT#" \
  -e "s#password_file =#password_file = $PASSWORD_FILE#" \
  -e "s#database_path = ./data/stoolap.db#database_path = memory://#" \
  -e "s#read_only = false#read_only = true#" \
  ../config/config.example.ini > "$READONLY_CONFIG"

./build/liquidstoolap check-config --config "$READONLY_CONFIG" >/dev/null
./build/liquidstoolap serve --config "$READONLY_CONFIG" > "$LOG_FILE" 2>&1 &
SERVER_PID=$!
trap cleanup EXIT
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

readonly_token_response="$(curl -fsS \
  -X POST "http://127.0.0.1:$PORT/auth/token" \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"secret"}')"
readonly_token="$(sed -n 's/.*"access_token" : "\([^"]*\)".*/\1/p' <<<"$readonly_token_response")"
test -n "$readonly_token"

readonly_select="$(curl -fsS \
  -X POST "http://127.0.0.1:$PORT/sql" \
  -H "Authorization: Bearer $readonly_token" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT 13"}')"
grep -q '"values" : \[13\]' <<<"$readonly_select"

readonly_command_status="$(curl -sS -o /tmp/liquidstoolap-readonly-command.json -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PORT/sql" \
  -H "Authorization: Bearer $readonly_token" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"CREATE TABLE readonly_t (id INTEGER)"}')"
test "$readonly_command_status" = "422"
grep -q 'read-only' /tmp/liquidstoolap-readonly-command.json

cleanup
trap - EXIT

BUSY_TIMEOUT_CONFIG="$ROOT_DIR/build/busy-timeout.ini"
sed \
  -e "s#port = 8321#port = $PORT#" \
  -e "s#password_file =#password_file = $PASSWORD_FILE#" \
  -e "s#database_path = ./data/stoolap.db#database_path = memory://#" \
  -e "s#busy_timeout_ms = 5000#busy_timeout_ms = 1#" \
  ../config/config.example.ini > "$BUSY_TIMEOUT_CONFIG"

./build/liquidstoolap check-config --config "$BUSY_TIMEOUT_CONFIG" >/dev/null
./build/liquidstoolap serve --config "$BUSY_TIMEOUT_CONFIG" > "$LOG_FILE" 2>&1 &
SERVER_PID=$!
trap cleanup EXIT
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

busy_token_response="$(curl -fsS \
  -X POST "http://127.0.0.1:$PORT/auth/token" \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"secret"}')"
busy_token="$(sed -n 's/.*"access_token" : "\([^"]*\)".*/\1/p' <<<"$busy_token_response")"
test -n "$busy_token"

busy_timeout_status="$(curl -sS -o /tmp/liquidstoolap-busy-timeout.json -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PORT/sql" \
  -H "Authorization: Bearer $busy_token" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT SUM(value) FROM generate_series(1, 200000000) AS g(value)"}')"
test "$busy_timeout_status" = "504"
grep -q '"code" : "backend_timeout"' /tmp/liquidstoolap-busy-timeout.json

cleanup
trap - EXIT

TTL_CONFIG="$ROOT_DIR/build/ttl.ini"
sed \
  -e "s#port = 8321#port = $PORT#" \
  -e "s#password_file =#password_file = $PASSWORD_FILE#" \
  -e "s#database_path = ./data/stoolap.db#database_path = memory://#" \
  -e "s#token_ttl_seconds = 3600#token_ttl_seconds = 1#" \
  ../config/config.example.ini > "$TTL_CONFIG"

./build/liquidstoolap serve --config "$TTL_CONFIG" > "$LOG_FILE" 2>&1 &
SERVER_PID=$!
trap cleanup EXIT
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

ttl_token_response="$(curl -fsS \
  -X POST "http://127.0.0.1:$PORT/auth/token" \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"secret"}')"
ttl_token="$(sed -n 's/.*"access_token" : "\([^"]*\)".*/\1/p' <<<"$ttl_token_response")"
sleep 2
expired_status="$(curl -sS -o /tmp/liquidstoolap-expired.json -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PORT/sql" \
  -H "Authorization: Bearer $ttl_token" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT 1"}')"
test "$expired_status" = "401"

echo "smoke ok"
