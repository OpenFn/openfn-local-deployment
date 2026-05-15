/**
 * k6 Load Test Script for OpenFn Lightning Webhooks
 *
 * Tests webhook endpoint performance under load with multiple test scenarios.
 *
 * Usage:
 *   k6 run -e WEBHOOK_URL=https://your-domain/i/your-webhook-id script.js
 *
 * Environment Variables:
 *   WEBHOOK_URL     - Required. The webhook URL to test
 *   SCENARIO        - Optional. Test scenario (see below). Default: uses RATE/DURATION
 *   PAYLOAD_SIZE_KB - Optional. Payload size in KB (default: 2)
 *   DURATION        - Optional. Test duration (default: "1m")
 *   RATE            - Optional. Requests per second (default: 10)
 *   THRESHOLD_ERROR_RATE   - Optional. Max error rate % (default: 1)
 *   THRESHOLD_P95_DURATION - Optional. Max P95 response time in ms (default: 500)
 *
 * Scenarios:
 *   smoke     - 1 req/s for 30s (sanity check)
 *   baseline  - 5 req/s for 2m (establish baseline metrics)
 *   stress    - 2x RATE for 5m (find degradation point)
 *   spike     - ramp to 5x RATE over 30s, hold 1m, ramp down
 *   soak      - RATE for 30m (detect memory leaks, connection exhaustion)
 *
 * The "production" and "payload" scenarios are run via run-load-test.sh,
 * which sets the appropriate RATE/DURATION/PAYLOAD_SIZE_KB values based
 * on client requirements.
 *
 * Examples:
 *   # Smoke test
 *   k6 run -e WEBHOOK_URL=... -e SCENARIO=smoke script.js
 *
 *   # Baseline test
 *   k6 run -e WEBHOOK_URL=... -e SCENARIO=baseline script.js
 *
 *   # Stress test (2x the given rate)
 *   k6 run -e WEBHOOK_URL=... -e RATE=20 -e SCENARIO=stress script.js
 *
 *   # Custom rate and duration (no scenario)
 *   k6 run -e WEBHOOK_URL=... -e RATE=50 -e DURATION=5m script.js
 *
 *   # Save results to CSV
 *   k6 run -e WEBHOOK_URL=... --out csv=results.csv script.js
 */

import http from 'k6/http';
import { check } from 'k6';

// ── Configuration ──────────────────────────────────────────────────

const webhookURL = __ENV.WEBHOOK_URL;
const scenario = (__ENV.SCENARIO || '').toLowerCase();
const payloadSizeKB = parseInt(__ENV.PAYLOAD_SIZE_KB || '2', 10);
const baseDuration = __ENV.DURATION || '1m';
const baseRate = parseInt(__ENV.RATE || '10', 10);
const thresholdErrorRate = parseFloat(__ENV.THRESHOLD_ERROR_RATE || '1') / 100;
const thresholdP95Duration = parseInt(__ENV.THRESHOLD_P95_DURATION || '500', 10);

if (!webhookURL) {
  throw new Error('WEBHOOK_URL environment variable is required');
}

// ── Scenario Configurations ────────────────────────────────────────

function buildScenarios() {
  switch (scenario) {
    case 'smoke':
      return {
        scenarios: {
          smoke: {
            executor: 'constant-arrival-rate',
            rate: 1,
            timeUnit: '1s',
            duration: '30s',
            preAllocatedVUs: 10,
          },
        },
      };

    case 'baseline':
      return {
        scenarios: {
          baseline: {
            executor: 'constant-arrival-rate',
            rate: 5,
            timeUnit: '1s',
            duration: '2m',
            preAllocatedVUs: 20,
          },
        },
      };

    case 'stress':
      return {
        scenarios: {
          stress: {
            executor: 'constant-arrival-rate',
            rate: baseRate * 2,
            timeUnit: '1s',
            duration: '5m',
            preAllocatedVUs: Math.max(baseRate * 4, 50),
          },
        },
      };

    case 'spike':
      return {
        scenarios: {
          spike: {
            executor: 'ramping-arrival-rate',
            startRate: baseRate,
            timeUnit: '1s',
            preAllocatedVUs: Math.max(baseRate * 10, 100),
            stages: [
              { duration: '30s', target: baseRate * 5 }, // ramp up to 5x
              { duration: '1m', target: baseRate * 5 },  // hold at 5x
              { duration: '30s', target: baseRate },      // ramp back down
            ],
          },
        },
      };

    case 'soak':
      return {
        scenarios: {
          soak: {
            executor: 'constant-arrival-rate',
            rate: baseRate,
            timeUnit: '1s',
            duration: '30m',
            preAllocatedVUs: Math.max(baseRate * 2, 50),
          },
        },
      };

    default:
      // No scenario specified or unrecognized — use RATE/DURATION directly
      return {
        scenarios: {
          webhook_load: {
            executor: 'constant-arrival-rate',
            rate: baseRate,
            timeUnit: '1s',
            duration: baseDuration,
            preAllocatedVUs: Math.max(baseRate * 2, 50),
          },
        },
      };
  }
}

// ── Thresholds ─────────────────────────────────────────────────────

// Derived thresholds from the two main configurable values
const thresholdP95Waiting = Math.round(thresholdP95Duration * 0.8);
const thresholdP99Waiting = Math.round(thresholdP95Duration * 1.6);

const thresholds = {
  http_req_failed: [`rate<${thresholdErrorRate}`],
  http_req_duration: [`p(95)<${thresholdP95Duration}`],
  http_req_waiting: [
    `p(95)<${thresholdP95Waiting}`,
    `p(99)<${thresholdP99Waiting}`,
  ],
};

// Soak test has relaxed P99 (long tests may have occasional outliers)
if (scenario === 'soak') {
  thresholds.http_req_waiting = [
    `p(95)<${thresholdP95Waiting}`,
    `p(99)<${thresholdP95Duration * 4}`,
  ];
}

// Spike test has relaxed thresholds during burst
if (scenario === 'spike') {
  thresholds.http_req_duration = [`p(95)<${thresholdP95Duration * 4}`];
  thresholds.http_req_waiting = [
    `p(95)<${thresholdP95Duration * 3}`,
    `p(99)<${thresholdP95Duration * 6}`,
  ];
}

// ── Export Options ──────────────────────────────────────────────────

const scenarioConfig = buildScenarios();

export const options = {
  ...scenarioConfig,
  thresholds,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

// ── Setup ──────────────────────────────────────────────────────────

export function setup() {
  const scenarioName = scenario || 'custom';
  const activeScenario = scenarioConfig.scenarios[Object.keys(scenarioConfig.scenarios)[0]];
  const effectiveRate = activeScenario.rate || activeScenario.startRate || baseRate;
  const effectiveDuration = activeScenario.duration || baseDuration;

  console.log(`\nScenario: ${scenarioName}`);
  console.log(`Target:   ${webhookURL}`);
  console.log(`Rate:     ${effectiveRate} req/s`);
  console.log(`Duration: ${effectiveDuration}`);
  console.log(`Payload:  ${payloadSizeKB} KB\n`);

  // Verify endpoint is reachable before starting load test
  const testPayload = JSON.stringify({ test: true });
  const response = http.post(webhookURL, testPayload, {
    headers: { 'Content-Type': 'application/json' },
  });

  if (response.status !== 200 && response.status !== 202) {
    throw new Error(
      `Webhook not reachable: ${response.status} ${response.status_text}`
    );
  }

  console.log(`Preflight: ✓ Webhook responded with ${response.status}\n`);

  return {
    basePayload: {
      timestamp: new Date().toISOString(),
      source: 'k6-load-test',
      scenario: scenarioName,
      data: 'x'.repeat(payloadSizeKB * 1000),
    },
  };
}

// ── Main Test Function ─────────────────────────────────────────────

export default function (data) {
  const payload = JSON.stringify({
    ...data.basePayload,
    iteration: __ITER,
    vu: __VU,
  });

  const response = http.post(webhookURL, payload, {
    headers: { 'Content-Type': 'application/json' },
  });

  check(response, {
    'status is 2xx': (r) => r.status >= 200 && r.status < 300,
  });
}

// ── Summary Handler ────────────────────────────────────────────────

export function handleSummary(data) {
  const metrics = data.metrics;
  const scenarioName = scenario || 'custom';

  const errorRate = metrics.http_req_failed.values.rate || 0;
  const p95Duration = metrics.http_req_duration.values['p(95)'] || 0;
  const p99Duration = metrics.http_req_duration.values['p(99)'] || 0;
  const avgDuration = metrics.http_req_duration.values.avg || 0;
  const p95Waiting = metrics.http_req_waiting.values['p(95)'] || 0;
  const p99Waiting = metrics.http_req_waiting.values['p(99)'] || 0;
  const totalReqs = metrics.http_reqs.values.count || 0;
  const reqsPerSec = metrics.http_reqs.values.rate || 0;

  // Evaluate thresholds based on scenario
  let passed;
  if (scenario === 'spike') {
    passed = errorRate < thresholdErrorRate && p95Duration < thresholdP95Duration * 4 && p95Waiting < thresholdP95Duration * 3;
  } else if (scenario === 'soak') {
    passed = errorRate < thresholdErrorRate && p95Duration < thresholdP95Duration && p99Waiting < thresholdP95Duration * 4;
  } else {
    passed = errorRate < thresholdErrorRate && p95Duration < thresholdP95Duration && p95Waiting < thresholdP95Waiting && p99Waiting < thresholdP99Waiting;
  }

  const w = 52; // box width
  const pad = (label, value) => {
    const content = `  ${label}${value}`;
    return `║${content.padEnd(w)}║`;
  };

  console.log('');
  console.log(`╔${'═'.repeat(w)}╗`);
  console.log(`║${'LOAD TEST RESULTS'.padStart(Math.floor((w + 17) / 2)).padEnd(w)}║`);
  console.log(`╠${'═'.repeat(w)}╣`);
  console.log(pad('Scenario:       ', scenarioName));
  console.log(pad('Total Requests: ', `${totalReqs}`));
  console.log(pad('Throughput:     ', `${reqsPerSec.toFixed(1)} req/s`));
  console.log(pad('Failed:         ', `${(errorRate * 100).toFixed(2)}%`));
  console.log(`╠${'═'.repeat(w)}╣`);
  console.log(pad('Avg Duration:   ', `${avgDuration.toFixed(0)} ms`));
  console.log(pad('P95 Duration:   ', `${p95Duration.toFixed(0)} ms`));
  console.log(pad('P99 Duration:   ', `${p99Duration.toFixed(0)} ms`));
  console.log(pad('P95 Waiting:    ', `${p95Waiting.toFixed(0)} ms`));
  console.log(pad('P99 Waiting:    ', `${p99Waiting.toFixed(0)} ms`));
  console.log(`╠${'═'.repeat(w)}╣`);

  // Per-threshold breakdown
  const errorThresholdPct = (thresholdErrorRate * 100).toFixed(0);
  const checks = [
    [`Error rate < ${errorThresholdPct}%`, errorRate < thresholdErrorRate],
    [`P95 duration < ${thresholdP95Duration}ms`, p95Duration < thresholdP95Duration],
    [`P95 waiting < ${thresholdP95Waiting}ms`, p95Waiting < thresholdP95Waiting],
    [`P99 waiting < ${thresholdP99Waiting}ms`, p99Waiting < thresholdP99Waiting],
  ];

  if (scenario === 'spike') {
    checks[1] = [`P95 duration < ${thresholdP95Duration * 4}ms`, p95Duration < thresholdP95Duration * 4];
    checks[2] = [`P95 waiting < ${thresholdP95Duration * 3}ms`, p95Waiting < thresholdP95Duration * 3];
    checks[3] = [`P99 waiting < ${thresholdP95Duration * 6}ms`, p99Waiting < thresholdP95Duration * 6];
  } else if (scenario === 'soak') {
    checks[3] = [`P99 waiting < ${thresholdP95Duration * 4}ms`, p99Waiting < thresholdP95Duration * 4];
  }

  for (const [label, ok] of checks) {
    console.log(pad(`${ok ? '✓' : '✗'} ${label}`, ''));
  }

  console.log(`╠${'═'.repeat(w)}╣`);
  console.log(pad('Result:         ', passed ? '✓ PASSED' : '✗ FAILED'));
  console.log(`╚${'═'.repeat(w)}╝`);
  console.log('');

  // Build JSON summary for programmatic consumption
  const summary = {
    scenario: scenarioName,
    timestamp: new Date().toISOString(),
    passed,
    metrics: {
      total_requests: totalReqs,
      throughput_rps: parseFloat(reqsPerSec.toFixed(1)),
      error_rate: parseFloat((errorRate * 100).toFixed(2)),
      avg_duration_ms: parseFloat(avgDuration.toFixed(0)),
      p95_duration_ms: parseFloat(p95Duration.toFixed(0)),
      p99_duration_ms: parseFloat(p99Duration.toFixed(0)),
      p95_waiting_ms: parseFloat(p95Waiting.toFixed(0)),
      p99_waiting_ms: parseFloat(p99Waiting.toFixed(0)),
    },
    thresholds: Object.fromEntries(checks.map(([label, ok]) => [label, ok ? 'pass' : 'fail'])),
  };

  const result = {};

  // Always output JSON summary to stdout for k6's default summary
  result['stdout'] = JSON.stringify(summary, null, 2) + '\n';

  // If K6_SUMMARY_FILE is set, also write to that file
  if (__ENV.K6_SUMMARY_FILE) {
    result[__ENV.K6_SUMMARY_FILE] = JSON.stringify(summary, null, 2);
  }

  return result;
}
