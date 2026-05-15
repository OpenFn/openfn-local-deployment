# Load Test Report: [COUNTRY] OpenFn Deployment

**Date:** _YYYY-MM-DD_
**Tester:** _Name_
**Lightning version:** [LIGHTNING_VERSION]
**Worker version:** [WORKER_VERSION]

---

## Executive Summary

_One paragraph: did the system pass or fail? What is the main finding?_

**Overall result:** PASS / FAIL

**Key findings:**
- _Finding 1_
- _Finding 2_
- _Finding 3_

---

## 1. Server Capacity Assessment

### Hardware Specifications

| Component | Specification |
|-----------|--------------|
| CPU | |
| RAM | |
| Disk | |
| OS | |
| Provider/Region | |

### Deployment Configuration

| Parameter | Value |
|-----------|-------|
| Lightning image | openfn/lightning:[LIGHTNING_VERSION] |
| Worker image | openfn/ws-worker:[WORKER_VERSION] |
| Worker replicas | 1 |
| Worker capacity | 2 |
| Worker memory limit | 2 GB |
| Max dataclip size | 10 MB |
| Max payload size | 10 MB |
| PostgreSQL version | 16.6 |

### Idle Resource Usage (baseline)

| Resource | Value |
|----------|-------|
| CPU (total) | |
| Memory (total) | |
| Memory (Lightning) | |
| Memory (Worker) | |
| Memory (Postgres) | |
| Disk used | |
| Database size | |
| Active DB connections | |

---

## 2. Test Results by Scenario

### Scenario 1: Smoke Test

**Configuration:** 1 req/s | 30s | 2 KB payload

| Metric | Value | Threshold | Result |
|--------|-------|-----------|--------|
| Error rate | | < 1% | |
| P95 response time | | < 500 ms | |
| P99 response time | | < 2000 ms | |
| Throughput | | | |

**Server resources during test:**

| Container | CPU | Memory |
|-----------|-----|--------|
| Lightning | | |
| Worker | | |
| Postgres | | |

**Application metrics:**

| Metric | Value |
|--------|-------|
| Work orders created | |
| Runs completed | |
| Runs failed | |
| Avg completion time | |

**Result:** PASS / FAIL

---

### Scenario 2: Baseline

**Configuration:** 5 req/s | 2m | 2 KB payload

| Metric | Value | Threshold | Result |
|--------|-------|-----------|--------|
| Error rate | | < 1% | |
| P95 response time | | < 500 ms | |
| P99 response time | | < 2000 ms | |
| Throughput | | | |

**Server resources during test:**

| Container | CPU | Memory |
|-----------|-----|--------|
| Lightning | | |
| Worker | | |
| Postgres | | |

**Application metrics:**

| Metric | Value |
|--------|-------|
| Work orders created | |
| Runs completed | |
| Runs failed | |
| Avg completion time | |
| P95 completion time | |

**Result:** PASS / FAIL

---

### Scenario 3: Expected Production Load

**Configuration:** _TBD_ req/s | 5m | _TBD_ KB payload

_Requires client input on expected load._

| Metric | Value | Threshold | Result |
|--------|-------|-----------|--------|
| Error rate | | < 1% | |
| P95 response time | | < 500 ms | |
| P99 response time | | < 2000 ms | |
| Throughput | | | |

**Result:** PASS / FAIL

---

### Scenario 4: Stress Test

**Configuration:** _2x production_ req/s | 5m | same payload

| Metric | Value | Threshold | Result |
|--------|-------|-----------|--------|
| Error rate | | < 1% | |
| P95 response time | | < 500 ms | |
| P99 response time | | < 2000 ms | |
| Throughput | | | |

**Degradation observed:**
- _What broke first?_
- _At what load level?_

**Result:** PASS / FAIL

---

### Scenario 5: Spike Test

**Configuration:** ramp from baseline to 5x over 30s, hold 1m, ramp down

| Metric | Value | Threshold | Result |
|--------|-------|-----------|--------|
| Error rate | | < 1% | |
| P95 response time | | < 2000 ms | |
| Recovery time | | | |

**Result:** PASS / FAIL

---

### Scenario 6: Payload Size Test

| Payload Size | Throughput | P95 Duration | Error Rate | Result |
|-------------|------------|-------------|------------|--------|
| 10 KB | | | | |
| 50 KB | | | | |
| 100 KB | | | | |
| 1 MB | | | | |

**Payload size threshold:** _The size at which performance starts degrading._

---

### Scenario 7: Soak Test (if run)

**Configuration:** production rate | 30m+ | realistic payload

| Metric | Start | End | Trend |
|--------|-------|-----|-------|
| Memory (Worker) | | | stable / growing |
| Memory (Postgres) | | | stable / growing |
| DB connections | | | stable / growing |
| Disk usage | | | stable / growing |
| Response time P95 | | | stable / growing |
| Error rate | | | stable / growing |

**Issues detected:**
- _Memory leaks?_
- _Connection pool exhaustion?_
- _Disk filling up?_

**Result:** PASS / FAIL

---

## 3. Threshold Summary

### Tier 1: Hard Requirements

| Metric | Threshold | Best Observed | Worst Observed | Status |
|--------|-----------|---------------|----------------|--------|
| Error rate | < 1% | | | |
| P95 response time | < 500 ms | | | |
| P99 response time | < 2000 ms | | | |

### Tier 2: Operational Health

| Metric | Threshold | Observed | Status |
|--------|-----------|----------|--------|
| CPU (any container) | < 80% sustained | | |
| Memory (worker) | < 1.5 GB / 2 GB | | |
| Postgres connections | < 80% of max | | |
| Disk usage | < 80% | | |

### Tier 3: End-to-End

| Metric | Threshold | Observed | Status |
|--------|-----------|----------|--------|
| Job completion time | TBD (client SLA) | | |
| Data loss | 0% | | |

---

## 4. Bottlenecks Identified

| # | Bottleneck | Severity | Evidence |
|---|-----------|----------|----------|
| 1 | | High/Med/Low | |
| 2 | | High/Med/Low | |
| 3 | | High/Med/Low | |

---

## 5. Recommendations

### Immediate (required for production)

1. _Recommendation 1_
2. _Recommendation 2_

### Short-term (improve performance)

1. _Recommendation 1_
2. _Recommendation 2_

### Long-term (scaling considerations)

1. _Recommendation 1_
2. _Recommendation 2_

### Configuration Tuning

#### Worker (`worker.env`)

| Parameter | Current | Recommended | Rationale |
|-----------|---------|-------------|-----------|
| WORKER_CAPACITY | 2 | | _Compare worker memory usage vs limit. If usage is well under 50% of the limit, capacity can increase._ |
| WORKER_MAX_RUN_MEMORY_MB | 1000 | | |
| WORKER_MAX_RUN_DURATION_SECONDS | 7200 | | |
| Worker memory limit (deploy) | 2 GB | | _May need to increase if WORKER_CAPACITY increases beyond 4._ |
| Worker replicas | 1 | | _Start with increased capacity before adding replicas._ |

#### PostgreSQL (`docker-compose.yml`)

_Check current values with: `docker compose exec postgres psql -U lightning -c "SHOW <param>;"`_

| Parameter | Current | Recommended | Rationale |
|-----------|---------|-------------|-----------|
| shared_buffers | 128 MB (default) | | _Default is too low. Recommend ~25% of RAM on dedicated servers, 1-2 GB on shared servers._ |
| work_mem | 4 MB (default) | | _16 MB reduces disk-based sorts. Safe if connections are low._ |
| maintenance_work_mem | 64 MB (default) | | _256 MB speeds up VACUUM and index operations._ |
| effective_cache_size | 4 GB (default) | | _Should reflect available OS cache. Typically 50-75% of total RAM._ |
| max_connections | 100 (default) | | _Check active connections via analyze.sh or `pg_stat_activity`._ |

To apply PostgreSQL tuning, add to the `postgres` service in `docker-compose.yml`:

```yaml
command: >
  postgres
  -c shared_buffers=2GB
  -c work_mem=16MB
  -c maintenance_work_mem=256MB
  -c effective_cache_size=8GB
```

#### Reverse Proxy

| Parameter | Current | Recommended | Rationale |
|-----------|---------|-------------|-----------|
| Body size limit | | | _Should match MAX_DATACLIP_SIZE_MB (typically 10 MB). Nginx default is 1 MB._ |
| Proxy timeouts | | | |

---

## Appendix

### A. Raw Test Output Files

- `results/<timestamp>/smoke-k6.log`
- `results/<timestamp>/smoke-summary.json`
- `results/<timestamp>/smoke-analysis.log`
- `results/<timestamp>/baseline-k6.log`
- `results/<timestamp>/baseline-summary.json`
- `results/<timestamp>/baseline-analysis.log`
- `results/<timestamp>/monitor.log`

### B. Server Baseline Output

_Paste output from `server-baseline.sh` here._
