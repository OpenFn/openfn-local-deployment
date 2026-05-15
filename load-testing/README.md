# Load Testing Toolkit

This directory contains the load testing toolkit for OpenFn deployments. It uses
[k6](https://k6.io/) to test Lightning webhook performance under load.

It is designed to be reusable across
all country deployments without modification.

## Prerequisites

Install k6:

```sh
# macOS
brew install k6

# Ubuntu/Debian
sudo gpg -k
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update
sudo apt-get install k6
```

For server monitoring, install `sysstat` (provides `iostat`):

```sh
sudo apt-get install sysstat
```

## Quick Start

1. Create a webhook trigger in Lightning and copy its URL
2. Run a smoke test:

```sh
cd benchmarking
k6 run -e WEBHOOK_URL=https://your-domain/i/webhook-id -e SCENARIO=smoke script.js
```

Or with Docker (no installation required):

```sh
cd benchmarking
docker run --rm -i \
  -e WEBHOOK_URL=https://your-domain/i/webhook-id \
  -e SCENARIO=smoke \
  grafana/k6 run - <script.js
```

## Files

| File                    | Purpose                                                         |
| ----------------------- | --------------------------------------------------------------- |
| `script.js`             | k6 load test script with multiple scenario modes                |
| `REPORT_TEMPLATE.md`    | Template for the final load test report                         |

## Workflow

Load testing happens in two phases:

- **Phase 1 — Infrastructure validation:** Tests the ingestion pipeline and
  server capacity using simple no-op workflows. This can be done without client
  involvement and answers the question: "Can the server handle the load?"

- **Phase 2 — Realistic validation:** Tests with the client's actual workflows
  (or close replicas) to measure real-world throughput. This requires client
  involvement and answers the question: "Can the system process the client's
  workload fast enough?"

### Phase 1: Infrastructure Validation

**1. Create a no-op test workflow** on the OpenFn/Lightning instance
  - Create a simple workflow with a webhook trigger
  - The job should be a no-op or minimal transform — the goal is to test the
    ingestion pipeline, not job logic
  - Copy the webhook URL for use in all subsequent steps

**2. Run server baseline assessment**

  ```sh
  bash server-baseline.sh
  ```

  Save the output — it goes into the final report. Review for red flags: high
  idle CPU, low free memory, disk near capacity.

**3. Run smoke test**

  ```sh
  bash run-load-test.sh --webhook-url <URL> --scenario smoke
  ```

  Confirms the pipeline works end-to-end (1 req/s, 30s). Fix any issues before
  proceeding.

**4. Run baseline test**

  ```sh
  bash run-load-test.sh --webhook-url <URL> --scenario baseline
  ```

  Establishes baseline performance metrics (5 req/s, 2m).

**5. Review results against playbook criteria**
  - Error rate under 1%
  - P95 response time under 500ms
  - Sustained for 10+ minutes without degradation

**6. Run remaining tests** with default rates

  Don't wait for client input — run all scenarios now with sensible defaults.

  ```sh
  bash run-load-test.sh --webhook-url <URL> --scenario stress --rate 10
  bash run-load-test.sh --webhook-url <URL> --scenario spike --rate 10
  bash run-load-test.sh --webhook-url <URL> --scenario payload
  bash run-load-test.sh --webhook-url <URL> --scenario soak --rate 10
  ```

**7. Review deployment configuration** and note tuning recommendations

  Inspect the current configuration and compare against load test results:

  ```sh
  # Worker config
  cat worker.env        # Check WORKER_CAPACITY, memory limits

  # PostgreSQL tuning
  docker compose exec postgres psql -U lightning -c "SHOW shared_buffers;"
  docker compose exec postgres psql -U lightning -c "SHOW work_mem;"
  docker compose exec postgres psql -U lightning -c "SHOW effective_cache_size;"

  # Current resource usage
  docker stats --no-stream
  ```

  Common findings:
  - `WORKER_CAPACITY` too low for available memory (check worker memory usage
    vs limit — if usage is under 50% of the limit, capacity can likely increase)
  - PostgreSQL `shared_buffers` at default 128 MB (should be ~25% of server RAM
    on dedicated servers, or 1-2 GB on shared servers)
  - `work_mem` at default 4 MB (16 MB is better for most deployments)

**8. Fill in REPORT_TEMPLATE.md**
  - Copy `REPORT_TEMPLATE.md` to `REPORT.md` (or similar)
  - Fill in results from each scenario, server baseline, and recommendations
  - Fill in the Configuration Tuning section with current vs recommended values

**9. Send report and client questionnaire**
  - Copy the client questionnaire Google Doc template and fill in the country
    name
  - Send the report and questionnaire to the client
  - The report shows the system works; the questionnaire calibrates production
    load and gathers workflow details for Phase 2

### Phase 2: Realistic Validation

**10. Set up realistic test workflows** (after client responds)

  Phase 1 tests the ingestion layer with no-op workflows. To measure real
  end-to-end throughput, you need workflows that resemble what will run in
  production.

  Ask the client to:
  - Create a **test project** in Lightning with copies of their production
    workflows (or describe them so you can build representative ones)
  - Point any external API calls to **sandbox/test endpoints** (e.g., DHIS2
    test instance) — never hit production systems with test data
  - If workflows aren't built yet, ask for a description: how many steps, what
    adaptors, do they call external APIs, how large are the payloads?

  Use these realistic workflows for Phase 2 testing. The webhook URLs from the
  test project replace the no-op URL used in Phase 1.

**11. Re-run with client parameters**
  - Set `--rate` based on the client's expected production load
  - Use the realistic test workflow webhook URLs
  - Run baseline, stress, and soak scenarios
  - Measure actual job processing throughput (not just ingestion)
  - Update the report with Phase 2 results

**12. Apply configuration tuning**
  - Apply any configuration changes recommended in the report
  - Re-run a smoke + baseline test to confirm improvements

**13. Archive results in the country repo**
  - Commit the completed report and raw result files

### Running tests with Docker (no local k6 needed)

```sh
bash run-load-test.sh --webhook-url <URL> --use-docker
```

### Running analysis manually

Post-test analysis runs automatically after each scenario. To run it manually:

```sh
bash analyze.sh                                  # All-time stats
bash analyze.sh --since "2024-01-15 10:00:00"    # Since a specific time
```

## Test Scenarios

### Smoke Test

- **Rate:** 1 req/s | **Duration:** 30s | **Payload:** 2 KB
- **Goal:** Confirm the pipeline works end-to-end
- **When to use:** First test on a new deployment, after config changes

### Baseline

- **Rate:** 5 req/s | **Duration:** 2m | **Payload:** 2 KB
- **Goal:** Establish baseline performance metrics under light sustained load

### Stress Test

- **Rate:** 2x the base rate | **Duration:** 5m
- **Goal:** Find where things start to degrade, identify the ceiling
- Set `--rate` to your expected production rate; the stress test doubles it

### Spike Test

- **Pattern:** Ramp from base rate to 5x over 30s, hold 1m, ramp back down
- **Goal:** Test burst handling (e.g., mass data push from DHIS2)
- Uses the `ramping-arrival-rate` k6 executor

### Payload Size Test

- **Sizes:** 10 KB, 50 KB, 100 KB, 1 MB at the base rate
- **Goal:** Find the payload size threshold where performance degrades
- Relevant since `MAX_DATACLIP_SIZE_MB=10` and `WORKER_MAX_PAYLOAD_MB=10`
- **Note:** If the 1 MB test fails with 413 errors, check your reverse proxy's
  body size limit (Nginx defaults to 1 MB) before investigating Lightning

### Soak Test

- **Rate:** Base rate | **Duration:** 30 minutes
- **Goal:** Detect memory leaks, connection pool exhaustion, disk fill
- **When to use:** After all other tests pass, before production go-live

## Configuration

| Variable                 | Default    | Description                                                   |
| ------------------------ | ---------- | ------------------------------------------------------------- |
| `WEBHOOK_URL`            | (required) | The webhook URL to test                                       |
| `SCENARIO`               | (none)     | Test scenario: `smoke`, `baseline`, `stress`, `spike`, `soak` |
| `RATE`                   | `10`       | Base requests per second                                      |
| `DURATION`               | `1m`       | Test duration (used when no SCENARIO is set)                  |
| `PAYLOAD_SIZE_KB`        | `2`        | Payload size in kilobytes                                     |
| `THRESHOLD_ERROR_RATE`   | `1`        | Max error rate percentage                                     |
| `THRESHOLD_P95_DURATION` | `500`      | Max P95 response time in ms                                   |

## Thresholds

Thresholds can be customized per deployment with `THRESHOLD_ERROR_RATE` and
`THRESHOLD_P95_DURATION` (or `--threshold-error-rate` / `--threshold-p95` via
`run-load-test.sh`). The values below are the defaults.

### Default Thresholds (smoke, baseline, stress, custom)

| Metric             | Threshold |
| ------------------ | --------- |
| Error rate         | < 1%      |
| P95 duration       | < 500 ms  |
| P95 waiting (TTFB) | < 400 ms  |
| P99 waiting (TTFB) | < 800 ms  |

### Spike Test Thresholds (relaxed for bursts)

| Metric       | Threshold |
| ------------ | --------- |
| Error rate   | < 1%      |
| P95 duration | < 2000 ms |
| P95 waiting  | < 1500 ms |
| P99 waiting  | < 3000 ms |

### Soak Test Thresholds (relaxed P99 for long duration)

| Metric       | Threshold |
| ------------ | --------- |
| Error rate   | < 1%      |
| P95 duration | < 500 ms  |
| P95 waiting  | < 400 ms  |
| P99 waiting  | < 2000 ms |

### Operational Thresholds (monitored, not in k6)

| Metric               | Warning Level          |
| -------------------- | ---------------------- |
| CPU (any container)  | > 80% sustained        |
| Memory (worker)      | > 1.5 GB of 2 GB limit |
| Postgres connections | > 80% of max           |
| Disk usage           | > 80%                  |
| Job queue depth      | Growing > 10/min       |

## Understanding Results

After each scenario, the k6 script prints a summary:

```text
╔════════════════════════════════════════════════════════╗
║                LOAD TEST RESULTS                       ║
╠════════════════════════════════════════════════════════╣
║  Scenario:       smoke                                 ║
║  Total Requests: 30                                    ║
║  Throughput:     1.0 req/s                             ║
║  Failed:         0.00%                                 ║
╠════════════════════════════════════════════════════════╣
║  Avg Duration:   45 ms                                 ║
║  P95 Duration:   89 ms                                 ║
║  P99 Duration:   112 ms                                ║
║  P95 Waiting:    82 ms                                 ║
║  P99 Waiting:    98 ms                                 ║
╠════════════════════════════════════════════════════════╣
║  ✓ Error rate < 1%                                     ║
║  ✓ P95 duration < 500ms                                ║
║  ✓ P95 waiting < 400ms                                 ║
║  ✓ P99 waiting < 800ms                                 ║
╠════════════════════════════════════════════════════════╣
║  Result:         ✓ PASSED                              ║
╚════════════════════════════════════════════════════════╝
```

A JSON summary is also written to stdout (and optionally to a file via
`K6_SUMMARY_FILE`) for programmatic consumption.

When run via `run-load-test.sh`, an **end-to-end verification** step runs after
each scenario: it waits for the job queue to drain, then compares the number of
HTTP requests sent with the number of work orders and completed runs in the
database, flagging any data loss or job failures.

## Monitoring During Tests

To monitor the server in a separate SSH session while tests run:

```sh
bash monitor.sh                            # Print to terminal
bash monitor.sh --log monitor.log          # Also save to file
bash monitor.sh --interval 10              # Sample every 10s (default: 5)
```

The monitor captures: Docker container CPU/memory, system load, disk I/O,
and PostgreSQL connection and lock statistics.

## Tips

1. **Run from an external machine** for accurate network latency measurements
2. **Start with smoke**, then baseline, then stress — stop and investigate if any test fails before moving on
3. **Monitor the server** in a second SSH session during tests
4. **Understand worker capacity** — `WORKER_CAPACITY` in `worker.env` limits concurrent
   job execution (typically 2). Under load, jobs will queue — this is normal. A stress
   test at 20 req/s with capacity 2 will build a large queue; that's testing the queue,
   not indicating a failure. Check the end-to-end verification to confirm all jobs
   eventually complete.
5. **Check reverse proxy body size limits** — Nginx defaults `client_max_body_size` to
   1 MB; Caddy has no default limit. If the payload test fails at 1 MB with 413 errors,
   fix the proxy config before investigating Lightning. The limit should match
   `MAX_DATACLIP_SIZE_MB` (typically 10 MB).
6. **Send client questionnaire** after Phase 1 results are available, to calibrate Phase 2 testing and gather workflow details
7. **Clean up between test rounds** — test data (work orders, runs) accumulates in
   PostgreSQL across test runs. If running multiple rounds, consider the growing table
   size. The `analyze.sh --since` flag filters results but doesn't remove old data.

## Adding to a New Deployment

This toolkit is designed to be reused across all country deployments. To add
load testing to a new deployment:

1. Copy `script.js` and `REPORT_TEMPLATE.md` into the country repo's
   `benchmarking/` directory
2. Copy the client questionnaire Google Doc template for this country
3. Walk through the [Workflow](#workflow) section above
4. Fill in `REPORT_TEMPLATE.md` with results — replace the `[COUNTRY]`,
   `[LIGHTNING_VERSION]`, and `[WORKER_VERSION]` placeholders
5. Commit the completed report, `script.js`, and raw result files to the
   country repo

The orchestration scripts (`run-load-test.sh`, `server-baseline.sh`,
`monitor.sh`, `analyze.sh`) stay in this repo — only `script.js` and the
completed report go into country repos.

## Reference

- [k6 Documentation](https://k6.io/docs/)
- [k6 Executors](https://grafana.com/docs/k6/latest/using-k6/scenarios/executors/)
- [OpenFn Benchmarking](https://github.com/OpenFn/lightning/tree/main/benchmarking)
