# Architecture

> ✏️ **Template.** Replace every `example.org` and every `10.0.0.x`. Delete the
> shape that does not apply. A diagram that describes a different deployment is
> worse than no diagram.

✏️ One paragraph: what this deployment does, who uses it, and what stops working
if it is down.

**Versions deployed:** ✏️ Lightning `vX.Y.Z`, worker `vA.B.C`.

## The servers

| Server | Address | Role |
|---|---|---|
| app-vm-01 | 10.0.0.11 | Lightning, the worker, the reverse proxy. Runs database migrations |
| app-vm-02 | 10.0.0.12 | the same, except migrations |
| mon-vm-03 | 10.0.0.13 | Prometheus, Grafana, Loki |
| database | 10.0.0.14 | PostgreSQL ✏️, provided and managed by the client |

✏️ For a single-server deployment, delete app-vm-02 and every mention of
clustering, the load balancer and draining below.

✏️ **Standalone shape** (two independent stacks behind a failover proxy),
replace the table above with this one and delete the clustering material:

| Server | Address | Role |
|---|---|---|
| app-vm-01 | 10.0.0.11 | primary stack: Lightning, the worker and its own PostgreSQL. Serves. |
| app-vm-02 | 10.0.0.12 | backup stack: the same, Lightning and the worker parked until a failover |
| proxy-vm-03 | 10.0.0.13 | the failover proxy (Nginx) and Uptime Kuma. The one address everything sends to. Must stay up. |

Nothing is shared between the two stacks at run time and nothing is
replicated. They carry the same secret set, so a database dumped from one
restores on the other, and the same project (same workflow and trigger ids, so
the same webhook URLs) is deployed to both by GitHub sync.

## How traffic reaches Lightning

✏️ Replace this with the real path, naming who operates each hop. Keep
`images/system-design.png` in step with it or delete the image.

![System design](images/system-design.png)

```
users ──► https://openfn.example.org
              │
        ✏️ load balancer, CDN or DNS
              │
        ✏️ tunnel agent, or direct
              │
        reverse proxy, loopback only
              │
        lightning:4000
              │
        PostgreSQL 10.0.0.14:5432
```

✏️ State where TLS terminates and who holds the certificate.

✏️ **Standalone shape**, the path is:

```
users and source systems ──► https://openfn.example.org  (DNS points at proxy-vm-03)
                                   │
                        Nginx on proxy-vm-03, terminates TLS
                        one upstream line decides which stack:
                                   │
                 10.0.0.11:4000  (primary)   or   10.0.0.12:4000  (backup)
                                   │
                        lightning ──► postgres, inside that stack only
```

Nginx stores nothing. The only file that changes at a failover is the upstream
file, and only `openfn-switch` edits it. Lightning is published on each
application server's private address, port 4000, plain HTTP, for the proxy
only; the preflight refuses a public address there.

**Webhook paths begin with `/i/`.** That prefix must stay excluded from bot
protection, rate limiting and any login requirement, or inbound integrations stop
working.

## What runs on each application server

| Service | What it does | Listens on |
|---|---|---|
| `lightning` | the web application and the API | 4000, inside Docker only |
| `worker` | runs the workflow steps | 2222, inside Docker only |
| `caddy` | reverse proxy in front of Lightning | 127.0.0.1:80 |
| `migrate` | one-shot, applies database migrations. Primary node only | nothing |

✏️ If nothing is published to the internet from the servers themselves, say so
here. It answers the first question any security reviewer asks.

✏️ **Standalone shape**, each application server runs instead:

| Service | What it does | Listens on |
|---|---|---|
| `postgres` | this stack's database | inside Docker only |
| `lightning` | the web application and the API | 10.0.0.1x:4000, private address, for the proxy |
| `worker` | runs the workflow steps | inside Docker only |
| `migrate` | one-shot, applies database migrations on this stack. Every stack migrates its own | nothing |

and the proxy server runs `nginx` (80 and 443) and Uptime Kuma (`kuma`, port
3001 on the private address or behind Nginx on its own name).

Two files on each application server record its state, and the scripts act on
them: `/opt/openfn/ROLE` (`primary` or `secondary`, never changes) and
`/opt/openfn/SERVING` (`yes` or `no`, changed by `openfn-activate` and
`openfn-standby`). Only the serving stack runs Lightning and the worker: two
running stacks, each with its own database, would each run every scheduled
workflow.

## Clustering

✏️ Delete this section on a single-server deployment.

The application servers are joined as one Erlang cluster, so an event raised on
one is seen by the others. Discovery runs through the shared database; the
connection between them is plain TCP.

That needs **TCP 4369 and the distribution port open between every pair of
application servers, in both directions**. Discovery does not remove the rule:
with the ports shut, each server finds its peers, silently never reaches them,
and keeps answering its health check.

## Failover

✏️ Standalone shape only; delete on a clustered deployment.

Three commands, in this order. The proxy's README (`/opt/openfn-proxy/README.md`)
and each stack's README repeat them.

1. On the stack that will take over: `openfn-activate`. Starts Lightning and the
   worker, waits until healthy, marks the stack serving.
2. On the proxy: `openfn-switch backup` (or `primary`). Refuses a target that does
   not answer `/health_check`; rewrites the upstream line, tests, reloads. Logged
   with time and user in `/var/log/openfn-proxy/switch.log`.
3. On the stack that handed over: `openfn-standby`. Stops Lightning and the
   worker; PostgreSQL keeps running.

Failback is the same three the other way. Requests that reached the proxy while
no stack answered were not stored by anything; whether a source system re-sends
them is that system's behaviour.

## Who operates what

| The client | OpenFn |
|---|---|
| ✏️ | ✏️ |

## Accepted risks

✏️ Anything agreed as a deliberate trade-off, with who accepted it and when. If
there are none, delete the section rather than leaving it empty.

| Risk | Accepted by | Date |
|---|---|---|
| | | |
