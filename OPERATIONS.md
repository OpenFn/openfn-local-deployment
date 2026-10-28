# Operations

> ✏️ **Template.** Replace every `example.org`, every `10.0.0.x`, and every
> `COUNTRY-openfn-deployment` before this goes to a client. Delete anything
> that does not apply to this deployment rather than leaving it unanswered.
Day-to-day operation of the OpenFn Lightning deployment for the client. Everything here exists on
the servers: plain Docker Compose, a README written for each server, and small scripts. It can be
run without Ansible and without OpenFn. The Ansible tooling ([deployment/](deployment)) is how the
servers were built and how OpenFn updates them, not how they run.

Commands need `sudo`. Nobody is in the `docker` group by design.

## Day-to-day

On each application server, in `/opt/openfn/bin`:

| Command | Does |
|---|---|
| `openfn-status` | containers on this server, the monitoring agents, a Lightning health check, and this server's role |
| `openfn-logs [service]` | follow logs, for example `openfn-logs lightning` or `openfn-logs worker` |
| `openfn-restart` | recreate Lightning and the worker on this server and wait until both are healthy |
| `openfn-update <version> [worker-version] [--no-restart]` | move this server to a new version (see below) |
| `openfn-lb-drain out\|in\|status` | take this server out of the load balancer pool, or put it back |

`openfn-lb-drain out|in|status` takes this server out of the Cloudflare load balancer pool before a
restart and puts it back once it is healthy again. It does nothing unless `/opt/openfn/cf-lb.env`
exists, which is not configured yet on this deployment.

On the monitoring server, in `/opt/openfn-monitoring/bin`: `openfn-status` (containers and every
Prometheus target with its health), `openfn-logs [service]`, `openfn-restart [service]`.

Run `openfn-status` first whenever something looks wrong.

✏️ **Standalone shape**, the scripts on each application server are instead:

| Command | Does |
|---|---|
| `openfn-status` | containers on this stack, PostgreSQL and Lightning health, this stack's role and whether it serves |
| `openfn-logs [service]` | follow logs: `lightning`, `worker`, `postgres` |
| `openfn-backup [dir]` | timestamped gzipped `pg_dump` of this stack's database (default `/opt/openfn/backups`) |
| `openfn-restart` | recreate Lightning and the worker on this stack (serving stack only) |
| `openfn-update <version> [worker-version] [--no-restart]` | move this stack to a new version: backs up, migrates its own database, restarts if serving |
| `openfn-activate` | start Lightning and the worker here, wait until healthy, mark this stack serving |
| `openfn-standby` | stop Lightning and the worker here (PostgreSQL keeps running), mark this stack not serving |

and on the proxy server, on the PATH: `openfn-switch status`, `openfn-switch
primary`, `openfn-switch backup`.

### Compose directly

The scripts wrap `docker compose`. If you need the raw commands:

```sh
cd /opt/openfn
sudo docker compose ps
sudo docker compose logs -f lightning
sudo docker compose up -d --force-recreate lightning worker   # what openfn-restart does
```

`docker compose restart` does **not** reload `.env` or `worker.env`. After changing either, recreate
the container as above (or run `openfn-restart`).

## Applying a new version

Two rules:

1. Only `app-vm-01` runs the database migration. `openfn-update` reads `/opt/openfn/ROLE` and
   migrates only where it says `primary`.
2. Both servers pull the new images before either one restarts.

So the order is:

```sh
# 1. on BOTH servers, at the same time. Pulls the images; on app-vm-01 also migrates. Nothing restarts.
sudo /opt/openfn/bin/openfn-update v2.X.Y --no-restart

# 2. on app-vm-02. Wait until it reports healthy.
sudo /opt/openfn/bin/openfn-restart

# 3. on app-vm-01, last.
sudo /opt/openfn/bin/openfn-restart
```

To update the worker as well: `openfn-update v2.X.Y v1.A.B --no-restart`.

Why pull first: from the moment one server restarts until the other is healthy, the two run
different versions. If a server still has to download the image inside that window, the window
lasts as long as the download. Why `app-vm-01` goes last: it is the fallback if the new version
misbehaves.

A `Cluster split` alert may appear while a server is restarting. It clears by itself once the
server is back.

**Afterwards, tell OpenFn the new version.** The deployment inventory has to match the servers;
otherwise the next managed run reverts the servers to the inventory's version.

✏️ **Standalone shape**, each stack owns its database, so each runs its own migration and there
is no primary-only rule. The order that keeps users on a stack already running the new version:

```sh
# 1. on the PARKED stack: pulls, backs up, migrates its database, starts nothing
sudo /opt/openfn/bin/openfn-update v2.X.Y
# 2. move traffic to it: openfn-activate there, openfn-switch on the proxy, openfn-standby on the other
# 3. on the now-parked stack: the same update
sudo /opt/openfn/bin/openfn-update v2.X.Y
# 4. switch back if production should sit on its usual stack
```

Updating the serving stack in place also works; it restarts into the new version, which costs a
few minutes while the containers drain.

Known gap: the update does not yet tell Cloudflare to drain a server before it restarts, so a small
number of in-flight requests can fail during step 2 and step 3. This is the brief error seen during
the failover test on 2026-09-22. OpenFn is adding the drain; it needs nothing from the client beyond a
Cloudflare API token scoped to the load balancer pool.

## If a server fails

Nothing needs to be done. Cloudflare's health check stops sending traffic to it and the other
server carries the load. Capacity is reduced until it returns, which is what the `Node not
reporting` alert is telling you. See [runbooks/NODE_NOT_REPORTING.md](runbooks/NODE_NOT_REPORTING.md).

One exception: database migrations are tied to `app-vm-01`. If that is the server lost for good,
tell OpenFn before the next version update.

✏️ **Standalone shape**, nothing moves by itself. Uptime Kuma raises the alert; a person confirms
the serving stack is really down and runs the three commands in
[ARCHITECTURE.md](ARCHITECTURE.md#failover): `openfn-activate` on the other stack, `openfn-switch`
on the proxy, `openfn-standby` on the failed stack once it is reachable. See
[runbooks/STACK_DOWN.md](runbooks/STACK_DOWN.md). If the proxy server itself is down, nothing
reaches OpenFn at either site: see [runbooks/PROXY_DOWN.md](runbooks/PROXY_DOWN.md).

## Docker Hardened Images and the registry login

Every image except Lightning and the worker is pulled from `dhi.io`, which needs an authenticated
Docker Hub login on each server. The login was done at deployment with the client's Docker Hub account and a
**read-only** access token, stored base64-encoded (not encrypted) in root's `~/.docker/config.json`.

If the token is rotated (Docker Hub → Account settings → Personal access tokens), log in again on
all three servers before the next update:

```sh
sudo docker login dhi.io -u <docker hub username>
```

DHI images run as a non-root user (uid 65532). Any file mounted into them has to be readable by that
user. The tooling sets volume ownership on every run.

## Monitoring

See [MONITORING.md](MONITORING.md). Grafana is at `http://10.0.0.13:3000` on the
private network, user `admin`, password provided at handover. Alerts are emailed and are also
visible in Grafana.

## Cloudflare configuration

For reference, and for anyone reviewing the setup later.

- **Health check:** `https://openfn.example.org/health_check`, expecting HTTP 200, with redirects
  not followed, run against **both** endpoints. Pointed at `/` instead, the check gets a redirect,
  not a 200, and a healthy server is taken out of rotation.
- **Pools:** two, one per server. `pool-primary` holds app-vm-01, `pool-secondary` holds app-vm-02, and
  the load balancer splits traffic evenly between them. Each server's `cf-lb.env` names its own
  pool, so `openfn-lb-drain` on one server reports that server only.
- **`/i/*`** must be excluded from bot protection, rate limiting and any login requirement. That is
  where webhooks arrive.

## Failover proxy

✏️ Standalone shape only; delete on a clustered deployment, and delete the Cloudflare section
above on a standalone one.

| What | Where |
|---|---|
| The stack that receives traffic | `/etc/nginx/conf.d/openfn-upstream.conf`, edited only by `openfn-switch` |
| Site configuration | `/etc/nginx/sites-available/openfn` |
| The two stacks' addresses | `/opt/openfn-proxy/stacks.env` |
| Switch history | `/var/log/openfn-proxy/switch.log` |
| Access and error logs | `/var/log/openfn-proxy/` (no request bodies) |
| Certificate | `/etc/letsencrypt/live/openfn.example.org/`, renewed by certbot's timer |

`openfn-switch` refuses a target that does not answer `/health_check` (start it with
`openfn-activate` first); `--force` overrides. The reload keeps Nginx running: new connections go
to the new stack, connections in flight finish. If the new configuration is rejected the old one
is put back and nothing changes.

## Internal firewall

TCP **4369** and **9100** between `10.0.0.11` and `10.0.0.12`, both directions. Details in
[ARCHITECTURE.md](ARCHITECTURE.md). If either closes, the `Cluster split` alert fires; see
[runbooks/CLUSTER_SPLIT.md](runbooks/CLUSTER_SPLIT.md).

## Database

PostgreSQL on `10.0.0.14:5432`, managed by the client. Both application servers connect as
`lightning`; the monitoring server connects as the read-only role `mon_ro` (holds `pg_monitor`, no
write access). Backups, upgrades and access control on that server are the client's.

✏️ **Standalone shape**, each stack has its own PostgreSQL inside its compose project, reached
only inside Docker, plain text on the one host. `openfn-backup` dumps it; copy the files off the
host, the database is the one thing that cannot be regenerated. The same dump restores on the
other stack (same encryption key), which is how a stack is re-seeded after a long time parked:
with Lightning stopped there, drop and recreate the database and `psql` the dump in. Work done
while a stack served stays in that stack's database; `openfn-backup` before parking preserves it.

`DATABASE_URL` in `/opt/openfn/.env` carries the `lightning` password percent-encoded. If the client
rotates that password, tell OpenFn: it is set in the deployment inventory and rendered onto both
servers by a managed run. Changing it by hand on one server and not the other, or pasting it
unencoded, takes Lightning down on the next restart.

The connection runs unencrypted (`db_ssl: disable`), the client's decision, since it stays on the client's
internal network. The server does support TLS 1.3, so if the client ever wants it encrypted it is one
inventory line and a managed restart.

## Secrets

`/opt/openfn/.env` on each application server contains `PRIMARY_ENCRYPTION_KEY`. Both servers hold
the identical key, which is why either can read credentials saved on the other.

**This key decrypts every credential stored in Lightning. If it is lost, that data cannot be
recovered, by the client or by OpenFn.**

The full secret set (encryption key, secret key base, worker keys, Erlang cookie, PromEx token,
metrics push password, Grafana admin password) lives on OpenFn's control node and was provided to
the client separately at handover. Keep an offline copy somewhere your team controls.

Secret rotation is done by OpenFn from the tooling (`playbooks/rotate.yaml`), because a rotated
secret has to land on both servers and the monitoring server in one coordinated step.

## Changing configuration

Every file under `/opt/openfn/`, `/opt/openfn-agents/` and `/opt/openfn-monitoring/` was rendered
from the deployment inventory. You can edit them, but **a managed run regenerates them** and any
hand edit is lost. Coordinate with OpenFn first; the right place for a permanent change is the
inventory. The one exception the tooling knows nothing about is GitHub Sync, see
[GITHUB_SYNC.md](GITHUB_SYNC.md).

## Troubleshooting

Start with the alert you are holding and its runbook:

| Symptom or alert | Runbook |
|---|---|
| `Node not reporting`, `Lightning not serving`, `cAdvisor not reporting` | [runbooks/NODE_NOT_REPORTING.md](runbooks/NODE_NOT_REPORTING.md) |
| `Service not serving` (no server is healthy, users are down) | [runbooks/SERVICE_NOT_SERVING.md](runbooks/SERVICE_NOT_SERVING.md) |
| `Cluster split`, `Cluster probe not reporting` | [runbooks/CLUSTER_SPLIT.md](runbooks/CLUSTER_SPLIT.md) |
| `Database unreachable`, `Database monitoring blind` | [runbooks/DATABASE_UNREACHABLE.md](runbooks/DATABASE_UNREACHABLE.md) |
| `Background jobs not running`, `Oban producer errors` | [runbooks/BACKGROUND_JOBS_NOT_RUNNING.md](runbooks/BACKGROUND_JOBS_NOT_RUNNING.md) |
| ✏️ standalone: Uptime Kuma says the public address is down and the serving stack is down | [runbooks/STACK_DOWN.md](runbooks/STACK_DOWN.md) |
| ✏️ standalone: the public address is down but the serving stack answers on its own address | [runbooks/PROXY_DOWN.md](runbooks/PROXY_DOWN.md) |

Some runbook steps use the Ansible tooling (`validate.yaml`, `site.yaml --limit`); those are the
steps OpenFn runs. Everything up to them can be done on the servers.

Quick checks on an application server:

```sh
sudo /opt/openfn/bin/openfn-status
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/health_check     # expect 200
sudo docker compose -f /opt/openfn/docker-compose.yml exec -T -e ERL_AFLAGS= lightning \
  /app/bin/lightning rpc 'Enum.each(Node.list(), &IO.puts/1)'             # expect the other server's node name
```

`ERL_AFLAGS=` matters on that last one: the variable pins the cluster port for the running node,
and a second BEAM started by `rpc` would otherwise fail to bind it.

## Outstanding items

Nothing is outstanding on OpenFn's side. Load testing has not been run against this deployment
yet, which is noted in the README.

## What OpenFn continues to handle

Secret rotation, failover verification, and any change that has to be coordinated across the
servers at once. For anything else, the README on each server is the first place to look.

## Support

- [OpenFn Deployment Guide](https://openfn.github.io/lightning/deployment.html)
- [OpenFn Documentation](https://docs.openfn.org/documentation/deploy/options)
- [Community Forum](https://community.openfn.org/)
- Email: <support@openfn.org>
