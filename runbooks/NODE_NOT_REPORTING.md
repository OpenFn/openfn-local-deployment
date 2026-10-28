# Node Not Reporting / Lightning Not Serving

> ✏️ **Template.** Replace every `example.org`, every `10.0.0.x`, and every
> `COUNTRY-openfn-deployment` before this goes to a client. Delete anything
> that does not apply to this deployment rather than leaving it unanswered.
This runbook is linked from three alerts: `Node not reporting: <node>`,
`Lightning not serving: <node>`, and `cAdvisor not reporting: <node>` (the
warning-level, container-metrics-only cousin of the first).

## Which alert are you holding?

Losing an app node has three shapes and each has its own rule. They are easy
to confuse, and the one you are holding tells you where to start.

| Alert | What is true | Where to start |
|---|---|---|
| **Node not reporting: `<node>`** | no measurement is arriving from that host at all. The node is down or unreachable, or its monitoring agents have stopped. Lightning may be perfectly healthy. | step 1 |
| **Lightning not serving: `<node>`** | the node is up and pushing metrics, and Lightning on it is not answering. The host is fine; the application is not. | step 2 |
| **Service not serving** | no app node anywhere is healthy. Users are down. | `SERVICE_NOT_SERVING.md`, not this page |

The difference between the first two is what the monitoring can see. A
Prometheus agent on each host scrapes Lightning and pushes the result. If the
host or that agent is gone, nothing arrives and the absence is the signal. If
the agent is alive and its scrape of Lightning fails, something very much does
arrive: a sample saying the scrape failed. Those are different facts, and
only the second one tells you the node is up and the application is not.

Both are critical on an app node. `Lightning not serving` fires after 2
minutes, and is suppressed if the node then stops reporting altogether, so a
node that dies raises one alert and not two.

## Diagnosis

"Node not reporting" means no push has arrived from the node named in the
alert for longer than that alert's configured window. App nodes use a shorter
window than the monitoring node and the database host, which have no Lightning
scrape and so are judged on cadvisor alone. The rule's own `for:` duration in
Grafana is the authoritative value; do not rely on a number quoted here.
That has three different causes, and only some of them mean users are
affected:

- The node itself is down or unreachable.
- The node is up but its monitoring agents (`prometheus-agent`, `cadvisor`,
  `alloy`, `docker-socket-proxy`, the separate `openfn-agents` compose project
  in `/opt/openfn-agents`) have stopped. Lightning is still serving users and
  nothing is wrong with the deployment; you have just gone blind to it.
- The node is up but everything on it is down, agents included.

If Lightning is down while the node is up and reporting, you will be holding
`Lightning not serving: <node>` instead, and the answer is under "Lightning
down, node up" in Resolution.

Severity tells you which kind of host it is. An app node's "Node not
reporting" is critical. What it costs depends on the shape of the deployment,
which you can read off the inventory (`lightning_cluster_enabled`) or the
Fleet dashboard's Cluster row:

- **Active-active** (clustered, the Cluster row has data). Every app node
  serves users all the time, so a lost node is lost *capacity*: the remaining
  nodes carry the whole load, and whether that is fine or a second incident
  depends on how much headroom they had. The load balancer drops an unhealthy
  origin on its own health check. There is nothing to fail over to and nothing
  to promote.
- **Active-standby** (not clustered, the Cluster row is empty). One node serves and
  the other stands by, so a lost node is either the outage itself or the loss
  of the standby, depending which one it was. The paragraphs marked
  *active-standby only* below apply.

The alert's `node_rank` label says primary or secondary. On an active-active deployment
that label only decides which node runs database migrations; it does not mean
that node is the one serving traffic, because they all are.

The monitoring node's and the
database host's are warnings, because losing the monitoring node means going
blind, not going down; if the database host stops reporting and Lightning is
still serving, the database itself is still up and only its agents are gone.
On the monitoring node the alert cannot be seen in email if SMTP is down with
it, so check Grafana when you get here from another signal.

Work through these in order. Refer to the node named in the alert throughout;
its `node` label names the host.

1. Check a port on the node named in the alert. Do not use `ping`: ICMP is
   filtered on plenty of networks, so a dropped ping proves nothing. Test
   something the node actually serves.

   Every node answers on 22:

   ```bash
   timeout 3 bash -c ": < /dev/tcp/<node>/22" && echo open || echo closed
   ```

   On the monitoring node, also Prometheus and Grafana; on the database host,
   Postgres:

   ```bash
   timeout 3 bash -c ": < /dev/tcp/<mon>/9090" && echo open || echo closed
   timeout 3 bash -c ": < /dev/tcp/<mon>/3000" && echo open || echo closed
   timeout 3 bash -c ": < /dev/tcp/<db_host>/<db_port>" && echo open || echo closed
   ```

   An app node has nothing else to test from another machine. Caddy listens on
   loopback under `edge_mode: tunnel`, and `validate.yaml` asserts 4000, 8080
   and the HTTP port are closed on the host address, so 22 is the only port
   there by design.

   If the port is open but `ssh` itself fails, that is an authentication,
   key or SSH-config problem and says nothing about whether the node is
   serving. Do not treat it as an outage.

   If the port is closed, the node is unreachable **from where you are
   testing**, which is not the same as down: the network path between you and
   it is equally likely. Confirm from a second location if you can, then skip
   to Resolution.

2. If you can reach it, check what it runs. On an app node or the database
   host:

   ```bash
   /opt/openfn/bin/openfn-status
   ```

   On the monitoring node: `/opt/openfn-monitoring/bin/openfn-status`.

   If this shows the `lightning` container down, crash-looping, or its
   health check failing, Lightning is down even though the node is up. Go
   to Resolution.

3. If `openfn-status` shows Lightning healthy, the node and the
   application are both fine, so this is a monitoring-only gap. Confirm:

   ```bash
   docker compose -f /opt/openfn-agents/docker-compose.yml ps
   ```

   A stopped `prometheus-agent`, `cadvisor`, or `alloy` explains the
   missing metrics with no impact on users. This is exactly what
   `cAdvisor not reporting` narrows down to on its own, and why it is a
   warning rather than critical.

## Resolution

**Node down.** This is outside the compose stack (VM, network, or provider
outage), not something to fix from inside a container. Get the host back; on
an active-active deployment there is nothing else to do for the service, and
nothing to switch: the load balancer stopped sending it users the moment its
health check failed, and the remaining nodes are carrying everything. Check
`Requests/s by node` on the Fleet dashboard to see that the survivors picked
the traffic up, and the app node panels for whether they have the headroom.
When the node comes back, check the Cluster row: it should re-join by itself,
and `CLUSTER_SPLIT.md` covers it if it does not.

Both servers serve traffic at the same time, so losing one needs no promotion
and no failover. The load balancer stops sending traffic to the server that is
down. `node_rank` only decides which server runs database migrations during an
update, so if the server holding that role is lost for good, tell OpenFn and
the deployment inventory is corrected. Nothing is broken in the meantime,
because migrations only run during an update.

**Lightning down, node up.** Restart it:

```bash
/opt/openfn/bin/openfn-restart
```

Check logs first if you want the cause before restarting:

```bash
/opt/openfn/bin/openfn-logs lightning
```

If it will not come back, the deployment is running on its remaining nodes.
Active-active: that is reduced capacity and no further action on the healthy
nodes; keep diagnosing this one. *Active-standby only*: if this is the node the pool
points at, switch the pool to the other node while you keep diagnosing.

**Agents down, Lightning fine.** Bring the monitoring compose project back
up on that node:

```bash
docker compose -f /opt/openfn-agents/docker-compose.yml up -d
```

No user impact, and no failover needed.

## Escalation

Escalate to OpenFn if the node is reachable, Lightning will not come back
after a restart, and the logs do not show an obvious cause (bad config,
disk full, the same crash repeating). Include `openfn-status` and
`openfn-logs lightning` output from the affected node, and whether traffic
has already been moved to the other node.
