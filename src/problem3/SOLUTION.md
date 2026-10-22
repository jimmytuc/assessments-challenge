# Problem 3: Debugging issues within system


## 1. Problems found

| # | Severity | Problem | Root cause |
|---|---|---|---|
| 1 | Critical | `/api/users` returned **502** immediately; the API was completely unreachable through the load balancer | `nginx/conf.d/default.conf` proxies to `api:3001`, but the API listens on **3000** (connection refused at the upstream) |
| 2 | Critical | The API **crashed** (process exit) and then returned 502s until manually restarted; requests **hung** during database restarts | No `error` handler on the pg `Pool`, plus DB clients released only on the success path. On a Postgres restart (`FATAL 57P01`), the error was re-emitted on the pool (`pg-pool` `idleListener`) with no listener → unhandled `'error'` event → Node process crash. Checked-out clients on the error path were also never released → leaked connections |
| 3 | Medium | `postgres/init.sql` (`ALTER SYSTEM SET max_connections = 20`) was dead code: the file is never mounted into the container, so `max_connections` remained 100 | Missing volume mount in `docker-compose.yml`; even if mounted, `max_connections` only takes effect after a restart |
| 4 | Medium | Startup race: `depends_on` only waited for containers to *start*, not to be *ready* | No healthchecks; API could hit an unready Postgres/Redis at boot |
| 5 | Medium | Long requests could tie up nginx workers indefinitely; no health endpoint exposed through the LB | Missing `proxy_read_timeout`/`proxy_connect_timeout`; nginx had no `/status` route |
| 6 | Low | No restart policy on any service — one crash = permanent outage until manual intervention | Missing `restart` in compose |
| 7 | Low | Empty `.env` file, unused | Dead file |
| 8 | Low | No graceful shutdown handling in the API | No SIGTERM handler |

## 2. Diagnosis method

- **Baseline reproduction:** `docker compose up --build`, then
  `curl localhost:8080/` → 200, `curl localhost:8080/api/users` → **502**.
- **Boundary isolation (bug 1):** nginx logs showed
  `connect() failed (111: Connection refused) while connecting to upstream ... "http://172.18.0.4:3001/api/users"`,
  while the API logs showed `API running on 3000` and `netstat` inside the
  API container confirmed `:::3000`. Calling the API directly returned 200 —
  the failure was exactly at the nginx→API boundary.
- **Crash forensics (bug 2):** filled the pool with 10 parallel requests,
  then killed the database backends with
  `SELECT pg_terminate_backend(...)`. Observed: requests hung (curl
  timeouts), then the API container exited(1). The log showed
  `throw er; // Unhandled 'error' event ... Emitted 'error' event on BoundPool instance at: Client.idleListener (pg-pool/index.js:62)`
  with `FATAL 57P01 terminating connection due to administrator command`.
  Post-crash requests got 502 until manual restart.
- **Config audit (bugs 3-7):** `SHOW max_connections` returned 100 despite
  the init.sql; `docker compose config` showed no healthchecks/restart
  policy; static read of the compose/nginx files.

A reproduction script (`verify.sh`) now encodes the outage scenario and
fails on the old behavior — it failed (RED) against the original code and
passes after the fixes.

## 3. Fixes applied

| File | Change |
|---|---|
| `nginx/conf.d/default.conf` | `proxy_pass http://api:3000` (was 3001); added `location = /status` proxy; added `proxy_connect_timeout 5s`, `proxy_read_timeout 30s`, `proxy_set_header Host` |
| `api/src/index.js` | `pool.on('error', ...)` handler (prevents crash); explicit pool limits (`max: 10`, `connectionTimeoutMillis: 5000`, `idleTimeoutMillis: 30000`); `try/finally` client release (fixes leak); SIGTERM handler for graceful shutdown |
| `docker-compose.yml` | Healthchecks on all four services (postgres `pg_isready`, redis `redis-cli ping`, api HTTP `/status`, nginx TCP `/status`); `depends_on: condition: service_healthy`; `restart: unless-stopped` everywhere; postgres started with `-c max_connections=20` |
| `postgres/init.sql` | Deleted — dead file replaced by the explicit server flag |
| `.env` | Deleted — empty and unused |

## 4. Verification

- `verify.sh` (DB-outage survival): **PASS** — API stays up and recovers to 200s.
- Load: 500 sequential + 500 parallel requests — all **200**.
- `docker compose ps`: all four services **healthy**.
- `SHOW max_connections` → **20**.
- `docker stop` (SIGTERM): graceful shutdown, exit **0**, "SIGTERM received" logged.

## 5. Monitoring and alerting to add

- **Container metrics:** Prometheus + cAdvisor (or Docker Desktop metrics) → alert on container restart count, exit code ≠ 0, crash loops.
- **App metrics:** `/metrics` endpoint (prom-client) exposing request rate, error rate, p95 latency, pg pool size/idle/error counts → alert on pool exhaustion (waiting clients) and 5xx rate.
- **Postgres:** connection count vs `max_connections` (>80% = warn), replication/lag alerts.
- **Uptime checks:** external probe on `/status` (e.g. CloudWatch Synthetics) every 1 minute.
- **Log-based:** nginx 5xx rate and `upstream timed out` messages; API fatal error logs (FATAL 57P01 class) → page.

## 6. Prevention in production

- Healthchecks + readiness gating (now in compose) — never start a consumer before its dependency is ready.
- CI smoke test that runs `verify.sh` (or an equivalent chaos test) on every change to the stack.
- Pin image tags (`nginx:1.25` → digest or patch version) and `npm ci` with a lockfile.
- Enforce the pattern: **never** hand out pooled connections without `try/finally` release; add a lint rule / code review checklist.
- Wrap every connection-pool library with an `error` handler — an unhandled pool error is a process kill.
- Ship logs (Fluent Bit) so `FATAL`/unhandled-error signals are visible before users report them.
- Bake failure drills into the deploy pipeline: periodic DB restart chaos test against staging.
