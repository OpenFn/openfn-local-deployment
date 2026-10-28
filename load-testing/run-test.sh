#!/usr/bin/env bash
# the client load test runner.
#
# Drives the shared script.js with the client's own volume figures, and keeps the
# both-nodes and single-node runs separate so the report can compare them.
#
#   bash run-test.sh --phase both   --tier smoke
#   bash run-test.sh --phase both   --tier upper
#   bash run-test.sh --phase single --tier upper
#
# WHY THIS EXISTS, rather than more scenarios in script.js: script.js is
# shared with every other country deployment and needs no changes for this.
# Testing goes through the load balancer, so the script does not know or care
# how many nodes are behind it. Only the rates and the procedure are the client's.
#
# WHAT THE NUMBERS MEAN. From issue #1, which are estimates off the workflow
# analysis and the solution design, not figures the institutions have
# confirmed:
#
#   go-live (Nov/Dec)   < 0.02 req/s average, < 0.1 req/s peak
#   upper bound         ~0.8 req/s average,   ~2.4-4 req/s peak
#   national target     ~2.8 req/s average,   up to ~14 req/s on a 5x spike
#
# There is no go-live tier below. The smoke run is 1 req/s, which is already
# ten times the go-live peak, so passing smoke covers it.
#
# WHAT THIS DOES NOT TEST. Two things, and the report has to say so:
#
#   1. Lightning answers the webhook as soon as it has written the work
#      order. It does not wait for the run. So every number here is about
#      ingestion, not processing. A fast 200 with a queue backing up behind
#      it still looks like a pass.
#
#   2. The cron workflows. Those pull batches from Punto Solidario and
#      SIUBEN, and the risk there is run duration and memory, not request
#      rate. The design has one upper-bound run handling ~3,000 records as a
#      ~9MB dataclip over ~50 minutes, against WORKER_MAX_RUN_DURATION_SECONDS
#      of 360 and a 10MB dataclip limit. k6 cannot tell you anything about
#      that. It needs stubbed endpoints and a separate run.
#
# THE AFFINITY COOKIE, and why nothing needs changing for it. the client's load
# balancer splits traffic 50/50 with Cloudflare's __cflb session-affinity
# cookie, so a client that stores it gets pinned to one node and a test of two
# nodes quietly measures one. Checked against our own lab behind a Cloudflare
# load balancer setting the same cookie, 80 requests over 4 VUs each time:
#
#   k6 default, jar reset every iteration     43 / 37 across the two origins
#   noCookiesReset, jar kept across them       2 /  2, and 76 with no cookie
#                                              set at all, i.e. pinned
#   a fresh empty jar on every request        43 / 37
#
# k6 resets its cookie jar between iterations by default and script.js makes
# one request per iteration, so the cookie is never reused and the split
# happens by itself. Do not set noCookiesReset, and if anyone adds a second
# request inside one iteration, revisit this: within an iteration the cookie
# does persist.
#
# WHERE TO RUN IT FROM. Latency here includes the trip to Cloudflare's edge
# and on to the client. Run from Addis and the p95 threshold can fail on geography
# alone while the servers are idle. Either run it from a host near the
# Dominican Republic, or read the latency figures as a comparison between the
# two phases rather than against an absolute target, and judge pass or fail on
# error rate and throughput.
set -euo pipefail

PHASE=""
TIER=""
WEBHOOK_URL="${WEBHOOK_URL:-}"
OUT_ROOT="${OUT_ROOT:-./baseline}"
ASSUME_YES=0

usage() {
  sed -n "2,63p" "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "Options:"
  echo "  --phase both|single   both nodes serving, or the second app server stopped (required)"
  echo "  --tier  smoke|upper|national|spike|soak|payload   (required)"
  echo "  --webhook-url URL     or set WEBHOOK_URL"
  echo "  --out DIR             results root (default ./baseline)"
  echo "  --yes                 skip the single-phase confirmation prompt"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="$2"; shift 2 ;;
    --tier) TIER="$2"; shift 2 ;;
    --webhook-url) WEBHOOK_URL="$2"; shift 2 ;;
    --out) OUT_ROOT="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1"; usage ;;
  esac
done

[[ -n "$PHASE" && -n "$TIER" && -n "$WEBHOOK_URL" ]] || usage
[[ "$PHASE" == "both" || "$PHASE" == "single" ]] || { echo "--phase must be both or single"; exit 1; }

# Latency threshold. script.js defaults to p95 duration 500ms and derives
# p95 waiting from it at 0.8x, which assumes the client sits near the server.
# Measured idle floor through the client's Cloudflare tunnel, nothing under load:
#
#   from mon-vm-03 (inside the client)  ttfb 0.062 - 0.067 s, connection reused
#   from a droplet in Amsterdam  ttfb 0.18 - 0.45 s
#   from Addis                   ttfb 0.77 - 0.89 s
#
# From mon-vm-03 the hairpin out to Cloudflare and back through the tunnel
# costs only about 63ms, so the toolkit's standard 500ms criterion is both
# achievable and meaningful there: it leaves roughly 440ms of server budget
# before it flags. Raise it only if you run from further away.
#
# Re-measure the floor if you run from anywhere else. Each run records its own
# floor in context.md so the report can separate distance from server time.
P95_MS="${P95_MS:-500}"

# Rates and durations per tier. RATE is an integer: script.js parseInts it.
case "$TIER" in
  # Payload is 1KB on every tier but the payload one: Francisco put the
  # webhook workflows at ~1 KB, which is below script.js's 2KB default.
  smoke)    ENVS=(-e SCENARIO=smoke        -e PAYLOAD_SIZE_KB=1) ;;        # 1 req/s, 30s
  upper)    ENVS=(-e RATE=4 -e DURATION=10m -e PAYLOAD_SIZE_KB=1) ;;       # upper-bound peak, sustained
  national) ENVS=(-e RATE=3 -e DURATION=10m -e PAYLOAD_SIZE_KB=1) ;;       # national average, sustained
  spike)    ENVS=(-e RATE=3 -e SCENARIO=spike -e PAYLOAD_SIZE_KB=1) ;;     # ramps to 5x = 15 req/s
  soak)     ENVS=(-e RATE=3 -e SCENARIO=soak  -e PAYLOAD_SIZE_KB=1) ;;     # 30m, leaks and queue growth
  payload)  ENVS=(-e RATE=4 -e DURATION=5m -e PAYLOAD_SIZE_KB=4) ;;        # the 3-4KB case-registration record
  *) echo "unknown tier: $TIER"; usage ;;
esac

# Idle network floor, measured the way k6 measures it. One curl over several
# URLs reuses the connection, so only the first sample carries the TLS
# handshake and the rest are comparable to k6 http_req_waiting. Measuring it
# with one curl per request instead overstates the floor badly: from Addis
# that read 1.79s worst while k6 saw 317ms on the same path.
FLOOR_BASE="${WEBHOOK_URL%%/i/*}"
FLOOR_URL="$FLOOR_BASE/health_check"
FLOOR="$(curl -s -o /dev/null --max-time 30 -w '%{time_starttransfer}\n' \
  "$FLOOR_URL" "$FLOOR_URL" "$FLOOR_URL" "$FLOOR_URL" "$FLOOR_URL" \
  "$FLOOR_URL" "$FLOOR_URL" "$FLOOR_URL" "$FLOOR_URL" "$FLOOR_URL" 2>/dev/null \
  | grep -oE '[0-9]+[.][0-9]+' | tail -n +2 | sort -n | awk 'NF{a[++n]=$1} END{ if(n) printf "best %s / median %s / worst %s", a[1], a[int((n+1)/2)], a[n] }')"
[ -z "$FLOOR" ] && FLOOR="not measured"
echo "idle ttfb floor (connection reused): $FLOOR  (threshold p95 ${P95_MS}ms)"

STAMP="$(date -u +%Y%m%d-%H%M%S)"
OUT="${OUT_ROOT}/${STAMP}-${PHASE}-${TIER}"
mkdir -p "$OUT"

echo
echo "phase    ${PHASE}   $([[ $PHASE == single ]] && echo 'the second app server must be STOPPED, not drained' || echo 'both nodes serving')"
echo "tier     ${TIER}"
echo "target   ${WEBHOOK_URL}"
echo "results  ${OUT}"
echo

if [[ "$PHASE" == "single" ]]; then
  cat <<'NOTE'
Reminder on the single-node phase. Taking a node out of the Cloudflare pool
stops webhooks reaching it but does not stop it working: Oban runs on Postgres
and both nodes poll the same run queue, so a drained node keeps processing
runs. To measure what one node can carry, stop it.

  on the second app server:  cd /opt/openfn && docker compose stop lightning worker
  afterwards:    cd /opt/openfn && docker compose start lightning worker

Expect "Lightning not serving: app2" and "Cluster probe not reporting: app2"
to fire while it is down. That is correct behaviour, not a test failure.

NOTE
  if [[ "$ASSUME_YES" == "1" ]]; then
    echo "--yes given: taking it as confirmed that the second app server is stopped"
  else
    read -r -p "the second app server stopped and the site still serving? [y/N] " ok
    [[ "$ok" == "y" || "$ok" == "Y" ]] || { echo "aborted"; exit 1; }
  fi
fi

# Use a local k6 if there is one, otherwise the official image. The image runs
# as its own uid, so pass ours through or it cannot write into the results
# directory, and feed it the script on stdin rather than mounting the tree.
if command -v k6 >/dev/null 2>&1; then
  K6_SUMMARY_FILE="${OUT}/${TIER}-summary.json" \
    k6 run "${ENVS[@]}" \
      -e WEBHOOK_URL="$WEBHOOK_URL" \
      -e THRESHOLD_P95_DURATION="$P95_MS" \
      --tag phase="$PHASE" --tag tier="$TIER" \
      --out "csv=${OUT}/${TIER}-raw.csv" \
      script.js 2>&1 | tee "${OUT}/${TIER}-k6.log"
else
  echo "no local k6, using the grafana/k6 image"
  # the client runs docker with userns-remap, so the container's uid 0 is a high uid
  # on the host and cannot write into a root-owned directory. Open the results
  # directory up for the duration rather than fighting the mapping.
  chmod 777 "$OUT"
  docker run --rm -i --user "$(id -u):$(id -g)" \
    -v "$(cd "$OUT" && pwd):/out" \
    grafana/k6 run "${ENVS[@]}" \
      -e WEBHOOK_URL="$WEBHOOK_URL" \
      -e THRESHOLD_P95_DURATION="$P95_MS" \
      -e K6_SUMMARY_FILE=/out/${TIER}-summary.json \
      --tag phase="$PHASE" --tag tier="$TIER" \
      --out "csv=/out/${TIER}-raw.csv" \
      - < script.js 2>&1 | tee "${OUT}/${TIER}-k6.log"
fi

cat > "${OUT}/context.md" <<EOF
# ${TIER}, ${PHASE} node(s)

- UTC: ${STAMP}
- target: ${WEBHOOK_URL}
- idle ttfb floor: ${FLOOR}
- p95 threshold: ${P95_MS} ms
- phase: ${PHASE}$([[ "$PHASE" == single ]] && echo ' (the second app server stopped)')

Server-side figures for this window come from Grafana on 10.0.0.13,
which keeps 30 days, so this is reviewable later:

- Fleet: per-node request rate. Use it to confirm the load balancer actually
  spread the load in the both-nodes phase.
- Node: memory and CPU per container against each container's own limit.
- Ancillary: the agents, Loki and the database exporter.
- Oban panels: queue depth and run outcomes. This is where you see whether
  runs kept up, which the webhook response time cannot tell you.

Fill in: worker peak memory against its 2512M limit, queue depth at the end
of the run, and whether any run failed or timed out.
EOF

echo
echo "wrote ${OUT}/{${TIER}-summary.json,${TIER}-raw.csv,${TIER}-k6.log,context.md}"
echo "now record the server side from Grafana into context.md while the window is fresh"
