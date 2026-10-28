# Cluster Split

> ✏️ **Template.** Replace every `example.org`, every `10.0.0.x`, and every
> `COUNTRY-openfn-deployment` before this goes to a client. Delete anything
> that does not apply to this deployment rather than leaving it unanswered.
This runbook is linked from the `Cluster split: <node>` alert in Grafana, and
from its warning-level cousin `Cluster probe not reporting: <node>`. They are
different problems and the diagnosis below is split accordingly: work
[Diagnosis, Cluster split](#diagnosis-cluster-split) for the first and
[Diagnosis, Cluster probe not reporting](#diagnosis-cluster-probe-not-reporting)
for the second.

It applies to **active-active** deployments only: the ones whose inventory has
`lightning_cluster_enabled: true`, where every app node serves users and the
nodes are joined to each other over Erlang distribution. An active-standby deployment
runs no cluster, no probe and neither of these alerts.

## What it means

The app nodes are clustered so that what happens on one is seen on the others.
When that connection is gone but both nodes are still up, you get the one
failure the clustering exists to prevent:

- Both nodes answer `/health_check` with 200.
- The load balancer keeps sending users to both.
- Both report metrics, and every other panel on the Fleet dashboard is green.
- Events raised on one node are not seen on the other. What a user does on one
  node does not reach a user on the other. Anything that depends on the nodes
  agreeing is now undefined.

Nothing about it is visible from outside, which is why it is alerted on
explicitly. Until it is fixed the deployment is in exactly the state the
clustering was introduced to avoid: two halves serving traffic and not talking.

The alert names the node whose peer count is short. With two app nodes a
healthy node reports one peer; a split node reports zero. One node short and
the other fine usually means a rule or a container on the short node; both
short means the path between them.

`Cluster probe not reporting: <node>` is the other side of the same coin: the
probe that produces the peer count has stopped or is failing, so there is no
measurement. That node may be clustered or split, and `Cluster split` cannot
fire for it while this is true. Treat it as a blind spot, not an outage.

## Diagnosis, Cluster split

Everything in this section is for `Cluster split`. For the other alert, skip to
the next section.

1. Ask each app node who it is connected to. This is the same probe the timer
   runs and the same one `validate.yaml` asserts on:

   ```bash
   cd /opt/openfn && docker compose exec -T -e ERL_AFLAGS= lightning \
     /app/bin/lightning rpc "Enum.each(Node.list(),&IO.puts/1)"
   ```

   One line per peer, as `lightning@<private address>`. No output means this
   node is alone. Run it on **every** app node: a node can see a peer that
   cannot see it back.

   The empty `ERL_AFLAGS=` is required. Without it the short-lived beam this
   command starts tries to bind the distribution port the server already
   holds, and the command fails for a reason that has nothing to do with the
   cluster.

2. Check the two ports are open between the nodes, in both directions. TCP
   4369 (epmd) and TCP 9100 (the pinned distribution port). From each node,
   against the other's private address:

   ```bash
   timeout 3 bash -c ": < /dev/tcp/<other node private ip>/4369" \
     && echo epmd reachable || echo epmd blocked
   timeout 3 bash -c ": < /dev/tcp/<other node private ip>/9100" \
     && echo dist reachable || echo dist blocked
   ```

   Keep the `:`. Both of these ports are servers that wait for the client to
   speak first, so `cat <` blocks with the connection already open, `timeout`
   kills it, and the check reports an open port blocked. `:` returns as soon
   as the connection is established, which is all we are testing.

   Discovery goes through PostgreSQL and the connection does not, so a node
   finds its peers and then silently fails to reach them. Both nodes will look
   healthy while this is true.

3. Confirm the node is actually configured for clustering:

   ```bash
   docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' \
     openfn-lightning-1 | grep -E 'ERLANG_NODE_DISCOVERY|RELEASE_NODE|RELEASE_DISTRIBUTION'
   ```

   `ERLANG_NODE_DISCOVERY_VIA_POSTGRES_ENABLED=true`, `RELEASE_DISTRIBUTION=name`
   and `RELEASE_NODE=lightning@<this node's private address>` must all be
   there. If they are missing on one node, that node was deployed with
   clustering off and never tried to join.

4. Read the peer's logs for what it saw:

   ```bash
   /opt/openfn/bin/openfn-logs lightning | grep -iE 'nodedown|nodeup|libcluster'
   ```

   A `nodedown` with no `nodeup` after it dates the split.

5. From the control node, the full check across every node at once:

   ```bash
   ansible-playbook -i inventory/<name>.yml playbooks/validate.yaml --tags deployed
   ```

   It asserts both ports listen on each node's private address and that every
   node's `Node.list()` holds every other app node in the inventory. Its
   failure message names what is missing from where.

## The usual causes

**A firewall rule was removed or narrowed.** The single most common cause. The
rule is TCP 4369 and 9100 between every pair of app nodes, both directions, on
the private network. A security group edit, a new host-level rule, a subnet
re-segmentation, or a provider default reasserting itself all do this. Step 2
finds it. Nothing on the Lightning side is broken and no restart is needed.

**One node was redeployed with clustering off.** An inventory where
`lightning_cluster_enabled` is false, or a `--limit` run against an inventory
that differs from the one that deployed the other node. That node comes up
with no discovery and never joins. Step 3 finds it: the environment variables
are simply absent. The fix is to redeploy that node from the right inventory.

**A cookie rotation that has not finished.** `rotate.yaml -e secret=erlang_cookie`
restarts the app nodes one at a time, and a node holding the new cookie will
not talk to one that still holds the old one. The deployment is split from the
first restart until the last, by design, and re-forms on its own. If a rotation
is in progress, wait for it. If one failed partway, the nodes are stranded on
different cookies: re-run the rotation to completion.

**A node restarted and has not re-joined.** Expected behaviour is that it
re-joins by itself within seconds. If it has not, it is one of the three
above rather than a fourth thing.

**Not a cause: the peer is down.** Every cause above is a peer that is alive
and unreachable. A peer that is simply gone (its VM or its Lightning stopped)
does not raise this alert at all: `Cluster split` is suppressed for every node
while any app node is not reporting, precisely so a dead node does not also
page its survivors. The alert to follow is whichever of these two is firing:
`Node not reporting: <node>` if the node itself is gone, or `Lightning not
serving: <node>` if the node is up and only Lightning has stopped. Both are
covered by `NODE_NOT_REPORTING.md`, which opens by telling the two apart. The
cluster re-forms by itself when the node comes back.

## Resolution

Fix the cause, then confirm. Nothing here needs a promote and nothing needs
the load balancer touched: both nodes are serving and should keep serving.

- **Firewall**: restore the rule. The nodes re-connect on their own within a
  discovery interval, no restart needed.
- **Redeployed with clustering off**: re-run the deploy for that node from the
  correct inventory.

  ```bash
  ansible-playbook -i inventory/<name>.yml playbooks/site.yaml --limit <node>
  ```

- **Cookie**: let the rotation finish, or re-run it.
- **Nothing else worked**: restart Lightning on the split node. This is a
  restart of a node that is currently serving users, so do it on one node at a
  time and let the other carry the traffic.

  ```bash
  /opt/openfn/bin/openfn-restart
  ```

Confirm with step 1 on every node, or `validate.yaml`. The alert clears within
a few minutes of the peer count coming back: the probe runs every 60 seconds
and the rule waits 2 minutes.

## Should we take a node out of the load balancer?

Usually no. Both halves are serving real users and removing one drops that
half's sessions while halving capacity, which is a bigger, more visible
problem than the split. Do it only when the split has caused visible damage
that is getting worse, and when you are removing the node deliberately, as a
containment step, with OpenFn told.

## Diagnosis, Cluster probe not reporting

This alert means the probe stopped reporting, not that the cluster is broken.
Nothing above applies. Check the timer:

```bash
systemctl status openfn-cluster-metrics.timer
systemctl status openfn-cluster-metrics.service
/opt/openfn/bin/openfn-cluster-metrics && cat /var/lib/openfn-metrics/cluster.prom
```

`lightning_cluster_probe_ok 0` in that file means the probe ran and the rpc
failed, which usually means Lightning itself is unwell on this node: work
`NODE_NOT_REPORTING.md` instead.

## Escalation

Escalate to OpenFn if:

- The ports are open, the environment variables are right on every node, no
  rotation is in progress, and the nodes still will not connect.
- The nodes connect and drop repeatedly (`nodedown` / `nodeup` cycling in the
  logs), which points at the network between them rather than at either node.
- You are not sure whether the split has already caused inconsistent data.

Include: the `Node.list()` output from every app node, the port checks in both
directions, the `docker inspect` environment lines, and when the alert started
firing.
