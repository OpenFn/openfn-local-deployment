# Automating Change Management & Config Migration for OpenFn Deployments

These scripts can be reused and adapted for other countries to streamline change management and ongoing operations of on-premise OpenFn deployments.  

A single base project (`app/main-project.yaml`) is used as the source of truth, and `update-site-projects.sh` generates and deploys a per-facility project spec for each site.

## Prerequisites

The scripts require the [OpenFn CLI](https://docs.openfn.org/documentation/cli) version **1.31.0 or higher**. Both scripts check this on startup and will exit with an error if the requirement is not met.

To install or upgrade:

```bash
npm i -g @openfn/cli
# or
pnpm i -g @openfn/cli
```

Verify your version with:

```bash
openfn version
```

## Structure

Each directory in the repo root should represent one [OpenFn/lightning](https://github.com/OpenFn/lightning) **deployment** (a single Lightning instance). Inside it, each `*-config.json` file represents one facility project on that instance.

For example: 
```
cloud-sandbox/
  main-project.yaml           # Base project spec (source of truth)
  main-state.json
  app-config.json             # Deploy config for the base project

local-site-1/                 # Local OpenFn deployment
  adhc1-config.json
  adhc1-project.yaml
  adhc1-state.json
  ...

update-site-projects.sh       # Generates and deploys site specs from the base cloud sandbox
pull-site-projects.sh         # Pulls current project specs from each site (sync only)
```

The directory name is used to resolve which API key to use (see below).

## Environment variables

All API keys should be placed in a `.env` file in the root directory, or set as environment variables / repository secrets for CI.

### API keys

Each deployment directory maps to a `<DESTDIR>_API_KEY` variable:

| Variable | Instance |
|---|---|
| `APP_API_KEY` | Base project (e.g., `cdi-sandbox`) on OpenFn Cloud at app.openfn.org |
| `SITE1_API_KEY` | `site1` local OpenFn deployment #1 |


## Adding a new site to an existing deployment

To add a new facility (`newsite`) to an existing hub (e.g. `hub`):

1. Create the config file in the hub directory:

```json
// hub/newsite-config.json
{
  "specPath": "hub/newsite-project.yaml",
  "statePath": "hub/newsite-state.json",
  "endpoint": "https://openfn.example.com"
}
```

2. Pull the initial project spec from Lightning — this populates `hub/newsite-project.yaml` and `hub/newsite-state.json`, which the update script uses to preserve existing credentials and workflow keys:

```bash
OPENFN_API_KEY=$HUB_API_KEY openfn pull <project-uuid> -c hub/newsite-config.json
```

3. Run the update script — it picks up the new config automatically:

```bash
bash update-site-projects.sh --deployment hub
```

For example, here is a recording showing how `telecloud` was added as a new deployment: https://www.loom.com/share/d6b35dab890c41be93a89cd8fd2d1a1e

## Adding a new Hub deployment

A "hub deployment" is a new OpenFn instance that hosts one or more facilities. 

1. **Create a directory** in the repo root named after the hub (e.g. `newhub/`).

2. **Add the API key** to your `.env` file — the variable name must match the directory name in uppercase:

```
NEWHUB_API_KEY=your-key-here
```

3. **Create a config file for each facility** on that hub. Each file goes inside the new directory:

```json
// newhub/facility1-config.json
{
  "specPath": "newhub/facility1-project.yaml",
  "statePath": "newhub/facility1-state.json",
  "endpoint": "https://openfn.newhub.example.com"
}
```

4. **Pull the initial spec** for each facility from the Lightning instance:

```bash
OPENFN_API_KEY=$NEWHUB_API_KEY openfn pull <project-uuid> -c newhub/facility1-config.json
```

   Repeat for each facility on the hub.

5. **Run the update script** — it will process all configs in the new directory:

```bash
bash update-site-projects.sh --deployment newhub
```

## GitHub Actions

### Pull project from app.openfn (`pull-app-project.yml`)

This workflow pulls the latest base project spec from app.openfn and commits it back to the repo. It is triggered manually via **Actions → Pull Project From app.openfn → Run workflow**, where you will be prompted to enter your API key.

The following must be configured in the repository's **Settings → Secrets and variables → Actions**:

| Name | Type | Value |
|---|---|---|
| `APP_PROJECT_ID` | Variable | `{PROJECT-ID-XYZ}` |
| `APP_CONFIG_PATH` | Variable | Path to the app config file — `app-config.json` |

The API key for app.openfn.org is entered at runtime when triggering the workflow — it is not stored as a secret.

**If you see a 401 error in the action logs:**

```
[CLI] ✘ Command failed!
[CLI] ✘ DEPLOY_ERROR: Failed to authorize request with endpoint https://app.openfn.org, got 401 Unauthorized.
```

Your `APP_API_KEY` is invalid. Request a new API key from app.openfn.org and update the secret.

## Running the scripts

### Run the update script

Pulls the latest state from each site, applies the base project template, and deploys.

```bash
# All deployments
bash update-site-projects.sh

# A specific deployment only
bash update-site-projects.sh --deployment hub
bash update-site-projects.sh --deployment adhc1

# With debug output — saves the generated YAML as {project}.debug if deploy fails
bash update-site-projects.sh --deployment hub --debug
```

After a successful run, the project YAML and state files on disk will be updated. **Always commit and push these changes** so the repo stays in sync with what's on the servers:

```bash
git add .
git commit -m "Update site project specs"
git push
```

### Pull without deploying

To sync local specs from all sites without deploying:

```bash
bash pull-site-projects.sh

# Or for a specific deployment
bash pull-site-projects.sh --deployment hub
```

## How the update script works

For each config file found in `{deployment}/*-config.json`:

1. Verifies the required API key env var is set — skips with a clear message if not.
2. Resolves the project ID by name (`{facility}-et-emr`) from the site's API — skips if not found.
3. **Pulls** the latest project spec from the site, so the script always works from the current server state.
4. Creates a **backup** of the pulled spec.
5. Applies transformations from the base project:
   - Prefixes collection keys with the facility name (e.g. `local-cache` → `site1-local-cache`)
   - Renames credentials to `{Facility} {Credential Name}` and rewrites their keys to match the site's existing credentials
   - Remaps workflow and job keys using fuzzy matching — if a workflow or job is renamed in the base, the script finds the closest match on the site and reuses its existing key, preserving the UUID
   - **Passes through any workflows that exist on the site but not in the base** — these are kept intact and appended as-is (see FAQ below)
   - Updates all `credential:` references in workflow jobs to match the remapped keys
6. **Deploys** to the site's Lightning instance via `openfn deploy`.
   - On success: pulls again to sync server-assigned IDs back to disk.
   - On failure: restores the backup. If `--debug` is set, saves the attempted YAML as `{project}.debug` for inspection.
7. Prints a summary: `Done — deployed: N, failed: N, skipped: N` (counts are per project/config file, not per workflow).

## Frequently asked questions

### Does the update script change webhook URLs?

**No.** Webhook URLs are assigned by the Lightning server and are not stored anywhere in the project YAML. The `pull` step only captures the webhook trigger's `type` and `enabled` state — never the URL itself. The URL on the server is never touched.

### Does the update script remove API key authentication on webhooks?

**No.** Webhook authentication settings (API key auth, basic auth, allowlists, etc.) are configured server-side and are not part of the project YAML spec. They are never included in `openfn pull` output and therefore never seen or modified by `openfn deploy`. Any auth configuration you set manually on a trigger will always be preserved.

### What happens if a workflow exists on the local server but not in the base project?

It stays intact. The script calls these "orphan workflows" — workflows present on the site that have no counterpart in `app/main-project.yaml`. After applying all base project changes, the script reads the site's pulled YAML and appends any workflows it did not already emit. These are passed through byte-for-byte with no modifications.

This means site-specific workflows (custom integrations, local automations, etc.) are safe to add directly on the Lightning instance and will survive update script runs.

### What if a workflow or job is renamed in the base project?

The script uses Jaro-Winkler fuzzy matching to find the closest-named workflow or job on the site and reuses its existing key. This preserves server-assigned IDs even across renames. The console will print a line like:

```
[update] workflow "Old Name" key: "old-key" -> "matched-key"
```

if a key was remapped.
