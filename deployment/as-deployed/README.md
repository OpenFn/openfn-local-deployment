# Configuration as deployed

✏️ The actual files from every server, captured on **[DATE]**, with every secret
replaced by `REDACTED`.

They are here so the client can see exactly what is running without logging in,
and so a future change can be compared against a known-good state.

**Nothing deploys from this directory.** It is a dated copy of the servers. The
source of truth is the zeus templates plus the inventory, so editing a file here
changes nothing anywhere.

| Directory | Server | Holds |
|---|---|---|
| ✏️ | | |

## Where each file comes from

Fixing a bug in a file here achieves nothing. The template that generated it
lives in zeus:

| File | Generated from |
|---|---|
| `docker-compose.yml` | `roles/lightning/templates/app-compose.yml.j2` |
| `env.txt` | `roles/lightning/templates/app.env.j2` |
| `worker.env.txt` | `roles/lightning/templates/worker.env.j2` |
| `Caddyfile` | `roles/lightning/templates/Caddyfile.j2` |
| `bin/*` | `roles/lightning/templates/bin/*.j2` |
| `openfn-agents/*` | `roles/monitoring_agents/templates/*` |
| `openfn-monitoring/*` | `roles/monitoring_server/templates/*` |

## Recapturing this

Copy the files from each server, then replace every value whose key contains
PASSWORD, SECRET, TOKEN, COOKIE, KEY or CREDENTIAL, plus the password inside
`DATABASE_URL`, any bcrypt hash, and any standalone secret file.

Check the result before committing. A secret committed once stays in the git
history permanently, even if a later commit removes it.
