# How this deployment is built and updated

> ✏️ **Template.** Replace the example values. Nothing here is needed to operate
> the servers day to day; that is [OPERATIONS.md](../OPERATIONS.md).

The servers are deployed from one inventory file by OpenFn's deployment tooling
(`OpenFn/zeus`), run from an engineer's machine. The servers themselves hold only
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

## The secret set

✏️ Name the secrets this deployment uses, without their values, and say where
they are held. One of them cannot be regenerated:

`PRIMARY_ENCRYPTION_KEY` decrypts every credential stored in Lightning. If it is
lost, those credentials are unrecoverable.

## What has been deployed

✏️ One entry per deployment or significant change. Date, what changed, and
anything learned.

**[DATE], first deployment.** ✏️
