# How this deployment is built and updated

> ✏️ **Template.** Replace the example values. Nothing here is needed to operate
> the servers day to day; that is [OPERATIONS.md](../OPERATIONS.md).

The servers are deployed from one inventory file by OpenFn's deployment tooling
(`OpenFn/zeus`, ✏️ `docker_deployments/v0.ansible` for the clustered shape or
`docker_deployments/v0.standalone` for the standalone shape), run from an
engineer's machine. The servers themselves hold only
plain Docker Compose projects, so everything in OPERATIONS.md works whether or
not that tooling is ever used again.

## The inventory

[`inventory.example.yml`](inventory.example.yml) is the file this deployment was
built from, with every credential replaced. ✏️ List the settings where the
default was not taken, and why. That table is the fastest way for anyone to see
what is unusual about this deployment.

| Setting | Value | Why |
|---|---|---|
| | | |

✏️ Clustered-shape settings to consider listing: `lightning_cluster_enabled`,
`edge_mode`, `lightning_public_host`, `db_host`, `db_ssl`, `db_monitor_user`,
`email_mode`, `cloudflared_tunnel_token`, `lightning_image`, `worker_image`.
Standalone-shape settings: `lightning_public_host`, `proxy_tls`, `public_scheme`,
`kuma_public_host`, `email_mode`, `lightning_serving` per stack,
`lightning_image`, `worker_image`.

## The secret set

✏️ Name the secrets this deployment uses, without their values, and say where
they are held. One of them cannot be regenerated:

`PRIMARY_ENCRYPTION_KEY` decrypts every credential stored in Lightning. If it is
lost, those credentials are unrecoverable.

## What has been deployed

✏️ One entry per deployment or significant change. Date, what changed, and
anything learned.

**[DATE], first deployment.** ✏️ Versions, what was verified on the day (a
failover drill, a restore test), anything learned.

## Changing the deployment

✏️ Keep the commands for this deployment's driver, delete the other block.

Clustered shape (`v0.ansible`):

```sh
# a new version: pulls on both servers first, migrates once, then restarts one at a time
ansible-playbook -i inventory/<name>.yml playbooks/update.yaml \
  -e lightning_image=openfn/lightning:vX.Y.Z -e worker_image=openfn/ws-worker:vA.B.C

# after any inventory change, re-render one server at a time (localhost stays in the limit:
# the shared-secret step runs there)
ansible-playbook -i inventory/<name>.yml playbooks/app.yaml --limit app2,localhost
ansible-playbook -i inventory/<name>.yml playbooks/app.yaml --limit app1,localhost
ansible-playbook -i inventory/<name>.yml playbooks/monitoring.yaml

# rotate one shared secret everywhere it is held
ansible-playbook -i inventory/<name>.yml playbooks/rotate.yaml -e secret=worker_secret

# check the deployment against what the inventory claims; changes nothing
ansible-playbook -i inventory/<name>.yml playbooks/validate.yaml
```

Standalone shape (`v0.standalone`):

```sh
# a new version: the parked stack first, then the serving one
ansible-playbook -i inventory/<name>.yml playbooks/update.yaml \
  -e lightning_image=openfn/lightning:vX.Y.Z -e worker_image=openfn/ws-worker:vA.B.C

# move traffic: activate the target, point the proxy at it, park the other
ansible-playbook -i inventory/<name>.yml playbooks/switch.yaml -e target=backup

# after any inventory change; never moves traffic, the servers' SERVING and upstream files win
ansible-playbook -i inventory/<name>.yml playbooks/site.yaml

# check the deployment against what the inventory claims; changes nothing
ansible-playbook -i inventory/<name>.yml playbooks/validate.yaml
```

Two things that matter when running these. After an upgrade, put the new
versions in the inventory, or the next run quietly moves the servers back onto
a newer database schema. `validate.yaml` refuses to pass if the inventory
disagrees with the `ROLE` files on the servers (and, standalone, if two stacks
both claim to serve); the fix is the inventory or the scripts, never a hand
edit on a server.

## Still to do

✏️ What OpenFn still owes on this deployment, or "Nothing."
