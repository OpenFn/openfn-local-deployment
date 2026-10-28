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

## Clustering

✏️ Delete this section on a single-server deployment.

The application servers are joined as one Erlang cluster, so an event raised on
one is seen by the others. Discovery runs through the shared database; the
connection between them is plain TCP.

That needs **TCP 4369 and the distribution port open between every pair of
application servers, in both directions**. Discovery does not remove the rule:
with the ports shut, each server finds its peers, silently never reaches them,
and keeps answering its health check.

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
