# Tooling to Support OpenFn Local Deployments

> ✏️ **This is a template.** Clone it per deployment, then work through the
> checklist at the bottom before anything is shared with a client.

This repository holds the documentation and tooling for one OpenFn deployment:
what was installed, how to run it, what to do when it alerts, and the exact
configuration as it stands on the servers.

It is written for the people who will operate the deployment after handover.

1. [ARCHITECTURE.md](ARCHITECTURE.md) — the servers, how traffic reaches Lightning, ports and networks
2. [OPERATIONS.md](OPERATIONS.md) — day-to-day commands, applying a new version, what to do when a server fails, secrets
3. [MONITORING.md](MONITORING.md) — Grafana access, dashboards, the alert rules and which runbook each one points to
4. [GITHUB_SYNC.md](GITHUB_SYNC.md) — connecting projects to GitHub for version control
5. [`runbooks/`](runbooks) — one page per alert, with diagnosis and resolution steps
6. [`deployment/`](deployment) — the inventory this deployment was built from, and the configuration as deployed
7. [`load-testing/`](load-testing) — scripts and results for testing performance
8. [`change-management/`](change-management) — how a change moves from app.openfn.org to this deployment

## About Your OpenFn Install

✏️ On **[DATE]**, we installed `openfn/lightning:[VERSION]` and
`openfn/ws-worker:[VERSION]`.

Users reach it at **https://openfn.example.org**.

✏️ Delete whichever of these does not apply:

- Docker Compose on every server. OpenFn deploys and updates it with Ansible
  (zeus `docker_deployments/v0.ansible` for the clustered shape,
  `docker_deployments/v0.standalone` for the standalone shape), but nothing on
  the servers depends on Ansible at run time: each server carries plain compose
  files, a README written for that server, and helper scripts.
- ✏️ **Clustered shape:** one application server / two application servers,
  both serving at the same time, joined in one Erlang cluster behind a load
  balancer. Database provided and managed by **[the client]** / deployed by
  OpenFn on its own server.
- ✏️ **Standalone shape:** two application servers, each a complete stack with
  its own PostgreSQL, only one serving at a time, behind an Nginx failover proxy
  on a third, always-up server. Moving traffic is a deliberate, manual switch.
- ✏️ Monitoring: Prometheus, Grafana and Loki on a dedicated monitoring server,
  every server pushing its metrics and logs there (clustered shape) / Uptime
  Kuma on the proxy server, probing the public address and both stacks
  (standalone shape).
- Database: ✏️ PostgreSQL [VERSION].

### Server Requirements

✏️ Link the completed pre-deployment questionnaire here, so the specifications
and prerequisites the client agreed to stay findable.

- [Pre-deployment checklist](✏️ ADD LINK)

## Before sharing this with a client

- [ ] Every `example.org`, `10.0.0.x` and `COUNTRY-openfn-deployment` replaced
- [ ] Every ✏️ resolved or deleted
- [ ] Sections that do not apply to this deployment deleted, not left blank
- [ ] The shape that does not apply deleted everywhere: README, ARCHITECTURE,
      OPERATIONS, MONITORING, and the runbooks that belong to the other shape
- [ ] `deployment/as-deployed/` captured from the servers, with secrets removed
- [ ] Secrets checked for in the git **history**, not only the current files
- [ ] Alert table in MONITORING.md matches the rules actually deployed
- [ ] Someone other than the author has read it end to end

> A secret committed once stays in the history after a later commit removes it.
> If one gets in, rotate it rather than deleting the commit.

## Other resources

- [Deploying Lightning](https://openfn.github.io/lightning/deployment.html)
- [OpenFn documentation](https://docs.openfn.org)
- [OpenFn CLI](https://docs.openfn.org/documentation/cli)
- [Lightning on GitHub](https://github.com/OpenFn/lightning)
