# Service Not Serving

> Shape: **clustered** (`v0.ansible`). On a standalone deployment delete this
> runbook; its alerts come from Grafana, which that shape does not run.

> ✏️ **Template.** Replace every `example.org`, every `10.0.0.x`, and every
> `COUNTRY-openfn-deployment` before this goes to a client. Delete anything
> that does not apply to this deployment rather than leaving it unanswered.
This runbook is linked from the `Service not serving` alert in Grafana.

## Which shape is this deployment?

Two shapes exist and the recovery differs. Check the inventory, or the Fleet
dashboard's Cluster row.

- **Active-active** (`lightning_cluster_enabled: true`, the Cluster row has
  data). Every app node serves users all the time. The load balancer health
  checks every origin and takes an unhealthy one out by itself. There is no
  promote, nothing to fail over to, and no node held in reserve. A node lost
  here costs capacity, not redundancy.
- **Active-standby** (`lightning_cluster_enabled: false`, the Cluster row is empty).
  One node serves, the other stands by. The paragraphs marked *active-standby only*
  apply; ignore them otherwise.

The `Migration role` column on the Fleet dashboard says which node runs
database migrations. On an active-active deployment that is all it says: it is
not the node serving traffic, because they both are.

## Diagnosis

The alert fires when no app node in the deployment has reported a healthy
Lightning for three minutes: `count(up{job="lightning"} == 1)` across every
app node is zero. This is the highest-severity alert in the deployment.
Unlike a single "Node not reporting" alert, it means every app node is
either silent or unhealthy at once, so users are down, not just degraded.

1. Check Grafana for which per-node alerts are firing alongside it: one
   "Node not reporting: `<node>`" alert per app node. If all of them are
   firing, every node has gone silent at the same time (a shared network
   problem, or every host down together). If none of them are firing, the
   nodes are reporting fine but Lightning itself is unhealthy on all of
   them.

2. SSH to an app node and check its status:

   ```bash
   /opt/openfn/bin/openfn-status
   ```

   This reports whether the `lightning` and `worker` containers are up and
   whether Lightning answers its health check.

3. Repeat on the other app node(s). If none are reachable at all, treat
   this as an infrastructure-wide event and move straight to escalation
   while you keep investigating.

If the containers are down or crash-looping on the reachable nodes, pull
logs to find a shared cause:

```bash
/opt/openfn/bin/openfn-logs lightning
```

Common shared causes: the database is unreachable (Lightning cannot serve
without it, check `DATABASE_UNREACHABLE.md`), a bad image was rolled out
to every node in the same `openfn-update` run, or a config change from a
recent Ansible run broke every node identically.

## Resolution

4. If the database is the cause, work `DATABASE_UNREACHABLE.md` first.
   Nothing here fixes Lightning while the database is down.

5. If containers are crash-looping with no database problem, restart
   Lightning and the worker on each node. One node at a time, and wait for
   each to come back healthy before starting the next: any node that recovers
   starts serving immediately, so a staggered restart is the difference
   between a partial outage and a total one. (*Active-standby only*: take the secondary
   node first while it is reachable, then the primary one.)

   ```bash
   /opt/openfn/bin/openfn-restart
   ```

   The script waits for the health check and reports success or failure.

6. If a bad image went out to every node, roll back from the control node
   with the previous known-good version:

   ```bash
   ansible-playbook -i inventory/<name>.yml playbooks/update.yaml \
     -e lightning_image=openfn/lightning:<previous-version>
   ```

7. If one node recovers before the others, the alert clears as soon as it
   reports a healthy Lightning: users are being served again, on reduced
   capacity, while you finish with the rest. On an active-active deployment
   the load balancer puts that origin back by itself when its health check
   starts passing; there is nothing to switch. Watch `Requests/s by node` on
   the Fleet dashboard to confirm traffic is actually arriving there, and
   check the Cluster row once a second node is back: two nodes serving and not
   clustered is its own problem, see `CLUSTER_SPLIT.md`.

8. Both servers serve traffic at the same time through the load balancer, so
   there is nothing to promote and nothing to fail over to. `node_rank` only
   decides which server runs database migrations during an update. If the
   server holding that role is lost for good, tell OpenFn so the deployment
   inventory is corrected. Nothing is broken in the meantime, because
   migrations only run during an update.

## The site is down but both servers are healthy

Users see a Cloudflare error page, most often **1033**, while Lightning is
running normally on the servers. This is not an application fault. Check it in
this order, on either application server.

1. Is the application actually serving?

   ```bash
   curl -sS -o /dev/null -w '%{http_code}
' -H 'Host: openfn.example.org'      http://127.0.0.1/health_check
   ```

   `200` means Lightning and Caddy are fine and the problem is in front of them.

2. Can the server reach the internet?

   ```bash
   curl -sS -o /dev/null -m 15 -w '%{http_code}
' https://www.cloudflare.com/cdn-cgi/trace
   ```

3. Is the tunnel agent connected?

   ```bash
   systemctl status cloudflared
   journalctl -u cloudflared -n 20 --no-pager
   ```

**If step 1 returns 200 and step 2 times out**, the servers have lost outbound
internet access. The Cloudflare tunnel agents open a connection *out* to
Cloudflare in order to receive traffic, so when outbound access goes, Cloudflare
has no route in and serves 1033. Nothing is wrong with OpenFn. This is for
the client's network team: the agents need outbound access to Cloudflare on port 7844,
TCP and UDP, and outbound HTTPS on 443. The site recovers by itself within a
minute or two of access being restored, because the agents retry continuously.

Error 1033 means *no tunnel agent is connected*. A 502 or 504 means the opposite:
the tunnel is up and the application behind it is not, which is the rest of this
runbook.

This happened on 2026-10-02. A fibre fault at the client's internet provider took
outbound access away at 02:56 UTC and the site was unreachable until the
provider repaired it. Lightning itself kept running the whole time.

## Escalation

Escalate to OpenFn if:

- The database is confirmed healthy but Lightning will not come up on any
  node after a restart.
- Logs point to an application-level failure (a migration error, a crash
  inside Lightning) rather than infrastructure.
- You are not confident a restart or rollback is safe right now, for
  example mid-migration.

Include: which nodes were checked, the `openfn-status` output from each,
and the relevant lines from `openfn-logs lightning`.
