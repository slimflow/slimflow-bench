# Slimflow — Benchmark Suite

Reproducible benchmarks comparing Slimflow against NGINX under two realistic
failure scenarios. No configuration required on Slimflow's side.

## Scenarios

### Scenario 1 — Hard failure (node returns 503)

1 gateway + 3 backends, 200 RPS, 90 seconds.  
At T+10s one backend is forced to reject all requests (simulates connection pool exhaustion, OOM kill, deploy restart).  
At T+40s it recovers.

**Results:**

| | Slimflow | NGINX round-robin | NGINX tuned¹ |
|---|---|---|---|
| Failures | **0** | **2,001** | 0 (hidden by retries) |
| Error rate | **0.0%** | **11.1%** | 0.0% |
| P99 latency | 14.1ms | 23.5ms | 13.0ms |

**Zero client-visible errors.** Slimflow's gateway retries valve bounces
transparently — and unlike NGINX, those retries are safe for **any** HTTP
method, including POST (see [Safe retries](#safe-retries--a-guarantee-nginx-cannot-offer)).

¹ NGINX tuned = `least_conn` + `max_fails=1 fail_timeout=1s` + `proxy_next_upstream http_503` —
the best open-source NGINX configuration for resilience.

---

### Scenario 2 — Latency degradation (node gets slow, still returns 200)

Same setup. At T+10s one backend degrades to 500ms response time but keeps
returning HTTP 200 (simulates GC pressure, database slowdown, CPU saturation).  
At T+40s it recovers.

NGINX cannot detect this — the node looks healthy. Slimflow detects the
degradation automatically and stops routing to the slow node within seconds.

**Results:**

| | Slimflow | NGINX tuned¹ |
|---|---|---|
| P50 | **11.8ms** | 11.5ms |
| P95 | **12.6ms** | 13.1ms |
| P99 | **13.4ms** | **502.1ms** |

**37x better P99. Zero configuration.**

---

## Prerequisites

- Docker + Docker Compose
- `curl` and `bash`

## Run the benchmarks

```bash
git clone https://github.com/slimflow/slimflow-bench
cd slimflow-bench
chmod +x scripts/*.sh
```

**Scenario 1 — Hard failure:**
```bash
./scripts/bench.sh              # Slimflow
./scripts/bench_nginx.sh        # NGINX tuned
```

**Scenario 2 — Latency degradation:**
```bash
./scripts/bench_latency.sh      # Slimflow
./scripts/bench_nginx_latency.sh # NGINX tuned
```

Custom parameters: `./scripts/bench.sh <rps> <fail_at> <recover_at> <duration>`

## What you will see

The load generator prints a rolling report every second. With Slimflow, the
error column stays at zero even while one node is fully saturated — bounces
are absorbed by transparent retries inside the gateway:

```
rps=200   total=2000    ok=2000    503=0
rps=200   total=4000    ok=4000    503=0    ← node2 saturated here; client sees nothing
rps=200   total=6000    ok=6000    503=0
```

At the end:

```
╔══════════════════════════════╗
║      slimflow loadgen report    ║
╠══════════════════════════════╣
║ duration  90.0s               ║
║ total     17997               ║
║ success   17997 (100.0%)      ║
║ bounced   0 (0.0%)            ║
║ p50       11.8ms              ║
║ p95       13.0ms              ║
║ p99       14.1ms              ║
╚══════════════════════════════╝
percentiles computed over successful requests only
```

## How it works

Slimflow routes traffic adaptively — no central state, no configuration.
Each node protects itself with an instant, zero-side-effect rejection when
saturated, and the gateway continuously adapts where traffic flows based on
the signals it observes from live traffic. Saturated or degraded nodes are
avoided automatically; recovered nodes are rediscovered automatically.

The result: Slimflow handles both hard failures (503) and soft degradation
(latency) without any operator intervention. The routing algorithm itself is
patent-pending — details will be published with the source.

### Safe retries — a guarantee NGINX cannot offer

When a valve bounce occurs, the gateway transparently retries the request on
another channel before the client ever sees an error.

The key property: a valve bounce is a rejection issued **before the node does
any work** — a structural guarantee of zero side effects. That makes the retry
safe for **any** HTTP method, including POST.

Compare with retry-based setups (`proxy_next_upstream` in NGINX): when an
upstream fails mid-request, the proxy cannot know whether the backend already
processed it. That's why NGINX refuses to retry non-idempotent methods by
default — retrying a POST after a timeout might charge a customer twice.
Slimflow distinguishes clean valve bounces (marked with the
`X-Slimflow-Backpressure` header, always safe to retry) from app-level 503s
and connection errors (never retried).

One more thing about retries: they are cheap only when failure is cheap. In
this benchmark the saturated node rejects in ~1ms, which makes NGINX's retries
look free. In production, failures are usually timeouts — and every retry
costs the client that timeout before being rerouted. Slimflow shifts traffic
*away* from degrading nodes proactively, so retries are the rare case, not the
steady state.

## Why the source is not included

Slimflow's routing algorithm is pending provisional patent (USPTO). Source will be
available under Apache 2.0 after filing. Happy to do a code walkthrough under NDA.

Contact: seff73@gmail.com
