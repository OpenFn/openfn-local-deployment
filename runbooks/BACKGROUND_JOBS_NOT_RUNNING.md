# Background Jobs Not Running

> Shape: **clustered** (`v0.ansible`). On a standalone deployment delete this
> runbook; its alerts come from Grafana, which that shape does not run.

> ✏️ **Template.** Replace every `example.org`, every `10.0.0.x`, and every
> `COUNTRY-openfn-deployment` before this goes to a client. Delete anything
> that does not apply to this deployment rather than leaving it unanswered.
This runbook is linked from the `Background jobs not running` and
`Oban producer errors: <node>` alerts in Grafana.

## Diagnosis

Lightning runs everything that is not an HTTP request through Oban, a job
queue that lives in the database: cron-triggered workflows, the run
scheduler, the pruner, the search indexers. Lightning's own cron enqueues
work every minute on whichever app node holds the Oban leader lock, so a
healthy deployment completes jobs continuously.

`Background jobs not running` fires when no job has completed on any app
node for ten minutes. `Oban producer errors: <node>` fires when Oban on
that node is raising while it fetches work, which is one node's half of the
same failure.

On a brand-new deployment this alert can fire once in the first quarter of an
hour, before Oban has completed anything at all, and resolves on its own as
soon as the first jobs run; check the deployment's age before working through
the rest of this page.

The important part: **Lightning keeps serving while this is true**. The web
UI answers, `/health_check` returns 200, and every HTTP alert stays green.
Nothing runs on a schedule, runs queue up, and the only visible symptom is
that scheduled workflows stopped firing. Do not read the green dashboard as
evidence that this alert is wrong.

1. On an app node, look at what Oban is saying:

   ```bash
   /opt/openfn/bin/openfn-logs lightning | grep -i oban
   ```

   Repeated errors every couple of seconds mean the producers are crashing
   on every fetch. `cache lookup failed for type <oid>` is the signature of
   a database that was rebuilt or restored under a running Lightning (see
   Resolution). A connection error names the database instead.

2. Ask the database what the queue looks like. Only where OpenFn runs the
   database, on the database host:

   ```bash
   cd /opt/openfn && docker compose exec -T postgres \
     psql -U lightning -d lightning \
     -c "select state, count(*) from oban_jobs group by 1" \
     -c "select * from oban_peers"
   ```

   Where the customer owns the database there is no such container, so ask
   it through Lightning instead, from any app node. The Lightning image
   ships no `psql`, and `-e ERL_AFLAGS=` is needed for the same reason as
   the cluster probe: without it the pinned distribution port clashes with
   the running node.

   ```bash
   cd /opt/openfn && docker compose exec -T -e ERL_AFLAGS= lightning \
     /app/bin/lightning rpc 'Lightning.Repo.query!("select state, count(*) from oban_jobs group by 1").rows
       |> Enum.each(fn [s, c] -> IO.puts("#{s} #{c}") end)'
   ```

   For the peers, change the query to `select * from oban_peers`.

   - A large and growing `available` count with nothing `executing` is the
     confirmation: work is being enqueued and nothing is taking it.
   - `oban_peers` should hold exactly one row, the current leader. No rows
     at all means no node is running Oban.

   For a provider-owned database, run the same queries through whatever
   psql access the provider gives you.

3. Check which nodes are affected. One `Oban producer errors` alert means
   one node; both, plus the fleet alert, means every node.

## Causes

**The database is unreachable.** Work `DATABASE_UNREACHABLE.md` first;
nothing here is fixable while the database is down. Expect
`Database unreachable` to be firing alongside.

**The database was rebuilt or restored.** This is the one that fires with
a perfectly healthy database. Lightning's Postgrex connections cache the
database's internal type identifiers at connect time; a rebuilt or restored
cluster issues new ones, and every query on an old connection then fails
with `cache lookup failed for type <oid>`. Lightning does not recover on
its own, and it does not go unhealthy either. **Restart Lightning on every
app node**, one at a time, waiting for each to come back healthy before
starting the next (on an active-active deployment every node is serving users,
so restarting them together is an outage; on active-standby, take the secondary node
first, then the primary one):

```bash
/opt/openfn/bin/openfn-restart
```

The alerts clear within a few minutes of the last node coming back, and the
`available` backlog drains on its own.

**Every app node is down.** Then `Service not serving` and both
`Node not reporting` alerts are firing too. Work `SERVICE_NOT_SERVING.md`;
this alert is a consequence, not the cause.

**One node only.** The fleet alert stays green because the other node is
still completing jobs, so this is degraded rather than down. Restart
Lightning on the affected node with `openfn-restart` and watch whether the
producer errors come back.

## Resolution

4. Fix the cause above, then confirm recovery rather than assuming it:

   ```bash
   cd /opt/openfn && docker compose exec -T -e ERL_AFLAGS= lightning \
     /app/bin/lightning rpc 'Lightning.Repo.query!("select state, count(*) from oban_jobs group by 1").rows
       |> Enum.each(fn [s, c] -> IO.puts("#{s} #{c}") end)'
   ```

   The `available` count should fall and `completed` should appear. In
   Grafana, "Oban jobs completed/s" on the Fleet dashboard should leave
   zero and "Oban producer errors/s" should return to it.

5. If jobs are draining but the backlog is large, leave it: Oban works
   through it at its configured concurrency. Nothing needs to be deleted
   from `oban_jobs` by hand.

## Escalation

Escalate to OpenFn if:

- Producer errors continue after a restart of Lightning on every node and
  the database is confirmed reachable and healthy.
- `oban_peers` stays empty after the restarts: no node is taking the
  leader lock, which is an application-level problem.
- The backlog is not draining even though jobs are completing, which
  suggests the enqueue rate exceeds what the deployment can run.
- The database was restored from a backup and you need to know what the
  queued jobs will do when they finally run.

Include: the `openfn-logs lightning | grep -i oban` lines from each app
node, the `oban_jobs` counts by state and the `oban_peers` rows, and
whether a database rebuild, restore or recreate happened recently.
