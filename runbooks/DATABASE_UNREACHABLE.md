# Database Unreachable

> ✏️ **Template.** Replace every `example.org`, every `10.0.0.x`, and every
> `COUNTRY-openfn-deployment` before this goes to a client. Delete anything
> that does not apply to this deployment rather than leaving it unanswered.
This runbook is linked from the `Database unreachable` alert in Grafana.

## Diagnosis

`postgres-exporter` runs on the monitoring node and reports `pg_up`. This
alert fires when `pg_up` is `0`: the exporter is running and was scraped
successfully, but it could not reach Postgres at the configured host and
port. Lightning cannot do anything without the database, so this is
critical.

This is a different failure from `Database monitoring blind`, which fires
when the `pg_up` series is absent altogether (the exporter itself is down,
or nothing is scraping it). If `Database monitoring blind` is firing
instead of, or alongside, this alert, work that runbook first. You have
no working measurement of the database's health until the exporter is
back.

1. From the monitoring node, test reachability of the database host and
   port from the inventory (`db_host` / `db_port`). `nc` and `pg_isready`
   are not guaranteed to be installed here, so use bash's built-in TCP
   check, which needs nothing extra:

   ```bash
   timeout 3 bash -c ": < /dev/tcp/<db_host>/<db_port>" \
     && echo reachable || echo unreachable
   ```

   Keep the `:`. Postgres waits for the client to send a startup packet
   before it says anything, so `cat <` blocks with the connection already
   open, `timeout` kills it, and the check calls a reachable database
   unreachable. `:` returns as soon as the connection is established, which
   is all we are testing.

2. Run the same check from an app node.

3. Compare the two results:
   - **Only the monitoring node fails, the app node succeeds**: this is
     a network or firewall problem specific to the monitoring node (a
     route, a security group, a rule scoped to the wrong host), not a
     database problem. Lightning itself is very likely still serving.
     Fix the monitoring node's path to the database; do not restart
     Postgres.
   - **Both fail**: the database is actually unreachable. Continue below.

## Resolution

**If both checks fail and this deployment runs its own database** (the
inventory's `database` group has a host, so check with the deployment's
operator or the inventory file if you have it):

4. SSH to the database host and check it:

   ```bash
   /opt/openfn/bin/openfn-status
   ```

5. If `postgres` is down or unhealthy, pull its logs (there is no
   `openfn-logs` helper on the database host, so use compose directly):

   ```bash
   cd /opt/openfn && docker compose logs postgres
   ```

6. Check disk space. Postgres refuses connections and can crash when its
   volume fills:

   ```bash
   df -h
   ```

   If disk is full, free space (old logs, unused images: `docker system
   prune`) before doing anything else; do not restart Postgres onto a full
   disk.

7. If none of the above explains it, restart Postgres:

   ```bash
   cd /opt/openfn && docker compose up -d --force-recreate postgres
   ```

8. If the database was rebuilt or restored rather than just restarted,
   restart Lightning on every app node with `/opt/openfn/bin/openfn-restart`,
   one node at a time: on an active-active deployment every app node is
   serving users, so restarting them together is an outage of its own. Its
   connections cache the old cluster's internal type identifiers and
   every background job fails until they are re-established, while
   `/health_check` stays green. See `BACKGROUND_JOBS_NOT_RUNNING.md`.

**If the database is provider-owned** (the `database` group is empty,
which is the normal case for a customer-managed Postgres), there is no host
here to SSH into. Escalate straight to the provider's DBA with the
specific evidence from steps 1–2: which hosts could and could not reach
`<db_host>:<db_port>`, and when the alert started firing.

## Escalation

Escalate to OpenFn if:

- The database is provider-owned. This is not something we can fix
  directly; gather the reachability evidence above and hand it to the
  provider's DBA, and loop in OpenFn if Lightning stays down while that is
  in progress.
- The database is ours, `postgres` is up and healthy, disk is not full,
  and it is still unreachable from every app node, which points to a
  Docker networking problem worth a second set of eyes.
- A restart of `postgres` does not clear the alert within a few minutes.

Include: the reachability results from steps 1–2, `openfn-status` output
from the database host if applicable, and the relevant `docker compose
logs postgres` lines.
