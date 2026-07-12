#!/usr/bin/env sh
set -eu

: "${TOKEN:?TOKEN is required}"

curl -sS \
  -X POST http://127.0.0.1:8321/sql \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT :id","params":{"id":42}}'
