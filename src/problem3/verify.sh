#!/usr/bin/env bash
# Reproduces the DB-outage failure and asserts the API survives + recovers.
# Run from src/problem3 with the stack up. Override BASE if needed:
#   BASE=http://localhost:18080 ./verify.sh
set -euo pipefail

BASE="${BASE:-http://localhost:8080}"
COMPOSE=(docker compose)

echo "==> 1. Warm the pool (10 parallel requests, expect all 200)"
codes=""
for _ in $(seq 1 10); do
  codes="$codes $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/api/users" || echo 000)"
done
echo "codes:$codes"
if echo "$codes" | grep -q "000\|500\|502\|504"; then
  echo "FAIL: warm-up requests did not all return 200"
  exit 1
fi

echo "==> 2. Terminate all API database backends (simulates Postgres restart)"
"${COMPOSE[@]}" exec -T postgres psql -U postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE client_addr IS NOT NULL;" >/dev/null

sleep 2

echo "==> 3. API process must still be running"
if ! "${COMPOSE[@]}" ps api --format '{{.Status}}' | grep -q "Up"; then
  echo "FAIL: API container is not running after DB backends were terminated"
  "${COMPOSE[@]}" logs --tail 5 api 2>/dev/null | grep -v "level=warning" || true
  exit 1
fi

echo "==> 4. Recovery: 15 requests, no hangs, last 5 must all be 200"
first_codes=""
last_codes=""
for i in $(seq 1 15); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/api/users" || echo 000)
  if [ "$i" -le 10 ]; then first_codes="$first_codes $code"; else last_codes="$last_codes $code"; fi
done
echo "first 10: $first_codes"
echo "last 5:   $last_codes"
if echo "$first_codes" | grep -q "000"; then
  echo "FAIL: some requests hung (curl timeout)"
  exit 1
fi
if echo "$last_codes" | grep -qv "200"; then
  echo "FAIL: API did not recover to 200s within the window"
  exit 1
fi

echo "PASS: API survived a database outage and recovered"
