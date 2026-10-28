# Monitoring

> ✏️ **Template.** Replace every `example.org`, every `10.0.0.x`, and every
> `COUNTRY-openfn-deployment` before this goes to a client. Delete anything
> that does not apply to this deployment rather than leaving it unanswered.
✏️ Two monitoring designs exist. The clustered shape uses Prometheus, Grafana and
Loki, described first. The standalone shape uses Uptime Kuma on the proxy server,
described at the end; on such a deployment delete everything between here and
that section.

## Overview

Three layers, as in every OpenFn deployment: emitters, storage, visualisation. The difference here
is that there are four servers, so the emitters run on every server and **push** to the monitoring
server. The application servers publish nothing but Caddy; the monitoring server never has to reach
into them.

### Emitters, on every server (`/opt/openfn-agents/`)

- `docker-socket-proxy` mediates access to the Docker socket for the two agents below. It is on an
  `internal: true` network and is never published.
- `cadvisor` collects container-level metrics. It has wide access to the host and **must never be
  exposed**.
- `prometheus-agent` scrapes `cadvisor` and, on an application server, Lightning's PromEx endpoint
  (`lightning:4000/metrics`, bearer token) and the Caddy-fronted health check, labels every sample
  with the server's name, and remote-writes to Prometheus on `mon-vm-03` with basic auth.
- `alloy` ships all container logs to Loki on `mon-vm-03`. Also uses `docker-socket-proxy`; **must
  never be exposed**.

On the application servers a small systemd timer (`openfn-cluster-metrics`) also writes the Erlang
cluster peer count to `/var/lib/openfn-metrics/cluster.prom`, which the agent picks up. That is
what the `Cluster split` alert reads.

### Storage, on `mon-vm-03` (`/opt/openfn-monitoring/`)

- `prometheus` runs as a remote-write receiver (basic auth, `web.yml`). It scrapes nothing on the
  application servers.
- `loki` stores the logs. Retention is **30 days** (`loki/config.yml`, compactor every 10 minutes,
  2-hour delete delay). Without it Loki would fill the disk.
- `postgres-exporter` runs here and logs in to the client's database as `mon_ro`, so database metrics work
  even though OpenFn does not own the database server.

### Visualisation

- `grafana` on `mon-vm-03`. Dashboards, datasource, alert rules and the contact point are provisioned
  from files under `/opt/openfn-monitoring/grafana/provisioning/`.

## Accessing Grafana

From a machine on the private network or the VPN: `http://10.0.0.13:3000`.

From elsewhere, over SSH:

```sh
ssh -L 3000:10.0.0.13:3000 <user>@10.0.0.13
# then open http://localhost:3000
```

User `admin`. The password was provided separately at handover. Please change it and create your own
accounts rather than sharing the admin login.

Prometheus is at `http://10.0.0.13:9090`, private network only, basic auth.

## Dashboards

Two folders.

**Overview**, written for a multi-server deployment:

| Dashboard | What it shows |
|---|---|
| Fleet | the home page: every server, whether it is reporting, Lightning health per server, the cluster row, request rate across the fleet |
| Node | one server at a time: CPU, memory, disk, containers, restarts, Lightning health and request rate for that server |
| Database | PostgreSQL through `postgres-exporter`: availability, connections against `max_connections`, size, cache hit ratio, replication lag |
| Monitoring | the monitoring stack itself: Prometheus, Loki, ingestion, targets |

**Lightning internals**, the standard PromEx set, each behind a `node` picker so you can look at one
server or both:

| Dashboard | What it shows |
|---|---|
| `prom_ex_application` | BEAM application metrics |
| `prom_ex_beam` | Erlang VM: memory, processes, schedulers |
| `prom_ex_ecto` | database queries from Lightning's side |
| `prom_ex_oban` | background job processing |
| `prom_ex_phoenix` | HTTP endpoints |
| `prom_ex_phoenix_live_view` | LiveView |

Totals on these dashboards are per server unless you pick both. Two servers each doing 0.1 req/s is
0.2 req/s for the deployment.

### Viewing logs

Via Grafana: **Drilldown → Logs**, filter by `host` and `container`. Every container on every server
is there.

On a server: `sudo /opt/openfn/bin/openfn-logs lightning` (or `worker`, `caddy`), and on the
monitoring server `sudo /opt/openfn-monitoring/bin/openfn-logs grafana`.

### Checking that every server is reporting

On the monitoring server, `sudo /opt/openfn-monitoring/bin/openfn-status` lists every target with
its health. Or ask Prometheus directly which servers pushed in the last minute:

```sh
P=<metrics push password>
curl -s -u "agent:$P" 'http://10.0.0.13:9090/api/v1/query?query=count%20by%20(node)(up)'
```

Three servers should appear: `app1`, `app2`, `mon`.

## Alerting

Alert rules are provisioned as code from
`/opt/openfn-monitoring/grafana/provisioning/alerting/`. The per-server rules are rendered from the
inventory, one copy per server, so a dead server is detected by the **absence** of its metrics,
which is the only signal a push model gives you.

### Rules

| Alert | Severity | Scope | Runbook |
|---|---|---|---|
| Node not reporting: `<server>` | critical on app servers, warning on the monitoring server | no metrics from that server at all | [NODE_NOT_REPORTING](runbooks/NODE_NOT_REPORTING.md) |
| Lightning not serving: `<server>` | critical | server is reporting, Lightning on it is not answering | [NODE_NOT_REPORTING](runbooks/NODE_NOT_REPORTING.md) |
| cAdvisor not reporting: `<server>` | warning | container metrics gone, everything else fine | [NODE_NOT_REPORTING](runbooks/NODE_NOT_REPORTING.md) |
| Service not serving | critical | **no** application server is healthy. Users are down | [SERVICE_NOT_SERVING](runbooks/SERVICE_NOT_SERVING.md) |
| Cluster split: `<server>` | critical | the server sees fewer cluster peers than it should | [CLUSTER_SPLIT](runbooks/CLUSTER_SPLIT.md) |
| Cluster probe not reporting: `<server>` | warning | the peer-count probe stopped writing | [CLUSTER_SPLIT](runbooks/CLUSTER_SPLIT.md) |
| Database unreachable | critical | `postgres-exporter` cannot reach the client's database | [DATABASE_UNREACHABLE](runbooks/DATABASE_UNREACHABLE.md) |
| Database monitoring blind | warning | the exporter itself is down | [DATABASE_UNREACHABLE](runbooks/DATABASE_UNREACHABLE.md) |
| Background jobs not running | critical | Oban has no leader or no producers across the cluster | [BACKGROUND_JOBS_NOT_RUNNING](runbooks/BACKGROUND_JOBS_NOT_RUNNING.md) |
| Oban producer errors: `<server>` | warning | producers on a server are crash-looping, typically after a database event | [BACKGROUND_JOBS_NOT_RUNNING](runbooks/BACKGROUND_JOBS_NOT_RUNNING.md) |
| High HTTP error rate: `<server>` | warning | 5xx above threshold on that server | |
| Disk usage > 85% / > 95%: `<server>` | warning / critical | host disk | |
| Container memory > 90% of host RAM: `<server>` | warning | | |
| Container restarted: `<server>` | warning | | |
| Prometheus Down, Loki Down | critical / warning | the monitoring stack itself | |

Resource alerts for a server are suppressed while that server is not reporting, so a dead server
raises one alert, not five. Time windows (`for:`) are set per rule in Grafana; the rule is the
authoritative value, not any number quoted in a runbook.

### Notifications

Alerts are emailed through `smtp.gmail.com`, sending as `openfn@example.org`, and are also always
visible in Grafana. The contact point and its recipients (`openfn@example.org` and one more address)
are provisioned from files, so to change who is notified, tell OpenFn.

### Customisation

Provisioned alert rules and dashboards are read-only in the Grafana UI, and anything you do manage
to change there is lost when Grafana restarts. To change a threshold, a recipient or a dashboard for good,
tell OpenFn: the files under `provisioning/` are rendered by the tooling, so the change
has to be made at the source or the next managed run puts the old version back.

For a quick experiment, edit the file on the monitoring server and
`sudo /opt/openfn-monitoring/bin/openfn-restart grafana`, knowing it is temporary.

## Uptime Kuma

✏️ Standalone shape only; delete on a clustered deployment.

Uptime Kuma runs in Docker on the proxy server (`/opt/openfn-kuma/`), beside
Nginx, in its own compose project. It probes the public address and each stack
and sends the alert when the serving stack stops answering. It routes no
traffic.

**UI:** ✏️ `https://status.openfn.example.org` / `http://10.0.0.13:3001`
(private network or VPN only). The admin account was created at handover;
change its password and create your own accounts.

### Monitors

| Name | URL | Interval |
|---|---|---|
| OpenFn (public) | `https://openfn.example.org/health_check` | 60 s, the alert that matters |
| Stack primary (app-vm-01) | `http://10.0.0.11:4000/health_check` | 60 s |
| Stack backup (app-vm-02) | `http://10.0.0.12:4000/health_check` | 60 s, shows Down while parked, which is expected; pause it |

### Notifications

Email through ✏️ `smtp.example.org`, to ✏️ `ops@example.org`. Set in Kuma under
Settings, Notifications, applied to every monitor. Alerts are always visible in
the Kuma UI as well.

### What an alert means

| Alert | Likely meaning | Do |
|---|---|---|
| OpenFn (public) Down and the serving stack's monitor Down | that stack has failed | [runbooks/STACK_DOWN.md](runbooks/STACK_DOWN.md) |
| OpenFn (public) Down but the serving stack's monitor Up | Nginx or the proxy's network | [runbooks/PROXY_DOWN.md](runbooks/PROXY_DOWN.md) |
| only the parked stack's monitor Down | expected while it is parked | nothing |

Kuma's own data (monitors, history, accounts) lives in the Docker volume
`openfn-kuma_kuma_data`; a managed run never touches it.
