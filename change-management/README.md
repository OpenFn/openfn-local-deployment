# Change Management: app.openfn.org → openfn.example.org

> ✏️ **Template.** Replace every `example.org`, every `10.0.0.x`, and every
> `COUNTRY-openfn-deployment` before this goes to a client. Delete anything
> that does not apply to this deployment rather than leaving it unanswered.
Workflows are built and tested in a project on **app.openfn.org**. the client runs them on its own
Lightning at **https://openfn.example.org**. This document describes how a change gets from one to
the other, with a GitHub repository in the middle that records the state of both.

The rules:

1. **app.openfn.org is the source of truth.** Make changes there, not on your deployment.
2. **The repo always has the app.openfn project checked out.** `workflows/` and `openfn.yaml`
   belong to it. Nothing in this flow checks out the the deployment project.
3. **The repo records both sides.** Before and after every deploy, the deployment is fetched and its
   snapshot committed, so git history shows what the deployment looked like and what the deploy changed.

```
 app.openfn.org                 project repo (GitHub)                 openfn.example.org
 ──────────────                 ─────────────────────                 ─────────────────
 edit, Save & Sync  ──────────► workflows/, openfn.yaml
  (GitHub Sync v2)              .projects/main@app.openfn.org.yaml
                                                │
                                                │  1. fetch local, commit snapshot   ◄──── read
                                                │  2. deploy main's snapshot ────────────► write
                                                │  3. fetch local, commit snapshot   ◄──── read
                                                ▼
                                .projects/local@openfn.example.org.yaml
```

Every command here is an `openfn project` command (the CLI's v2 sync). No wrapper scripts are
needed.

## Prerequisites

- **OpenFn CLI 1.43.0 or later.** 1.42.0 added `--no-checkout` and `--credentials` to
  `project deploy`. 1.43.0 moved checkout state out of `openfn.yaml` into an untracked `.openfn/`
  folder and fixed handling of two local copies of the same project, which this flow relies on
  (both snapshots have the same project id).

  ```bash
  npm i -g @openfn/cli@latest
  ```

- **Two API keys** (personal access tokens, created under *User Profile → Personal Access
  Tokens* on each instance):

  | Name | Instance | Who creates it |
  |---|---|---|
  | `OPENFN_<project-uuid>_API_KEY` | app.openfn.org | Created by GitHub Sync when the repo is connected |
  | `DEPLOYMENT_API_KEY` | openfn.example.org | A the client user who is an admin or owner of the project on your deployment |

  Keep them in GitHub repository secrets for CI. For manual runs keep them in a gitignored `.env`.
  This document passes the key to every command with `--api-key` so the two can never be mixed
  up.

## Repo layout

The project repo is the one GitHub Sync connects to (not this deployment-docs repo).

```
openfn.yaml                                # workspace config only (CLI 1.43+), tracked
workflows/                                 # the app.openfn project, expanded. Always checked out
.projects/
  main@app.openfn.org.yaml                 # last known state of the app.openfn project
  local@openfn.example.org.yaml             # last known state of the the deployment project
credential-map.yaml                        # app.openfn credential → local credential
.openfn/                                   # checkout state, local to each machine. Not tracked
.github/workflows/
  openfn-pull.yml                          # written by GitHub Sync
  openfn-<project-uuid>-deploy.yml         # written by GitHub Sync, edited in step 3 below
  deploy-to-local.yml                     # added in step 6 below
```

The CLI names snapshot files `<alias>@<host>.yaml`. This document uses the alias `main` for
app.openfn.org and `local` for local.

## One-time setup

### 1. Connect GitHub Sync on app.openfn.org

In the app.openfn project: **Project Settings → Sync to GitHub**. Pick the repo and branch, open
**Advanced: use new YAML config format** and tick **Use new `openfn.yaml` format** (sync v2), then
**Connect Branch & Initiate First Sync**.

GitHub Sync commits `openfn.yaml`, `workflows/` and `.projects/main@app.openfn.org.yaml`, plus the
two GitHub workflow files and the `OPENFN_<project-uuid>_API_KEY` secret.

### 2. Create the project on your deployment

Create an empty project in the local UI, add its users, and note its UUID (it is in the URL:
`/projects/<uuid>/w`).

If the project already exists on your deployment, skip this. Step 4 pulls its current state before
anything is deployed.

Then create the credentials the workflows need on your deployment, with the real secrets for the client's
systems. Credentials are never copied between instances. Each one needs an owner (the user who
creates it) and a name; you need both in step 5.

### 3. Point the generated deploy workflow at `main`

`.github/workflows/openfn-<project-uuid>-deploy.yml` deploys the repo back to app.openfn.org when
someone pushes to the synced branch. As generated, it uses `openfn/cli-deploy-action`, which deploys with no target. Once
`.projects/` holds two projects, that fails in CI: a fresh clone has no `.openfn/` checkout state,
and with two candidates and no terminal to ask, the CLI aborts with
`No checked out project found`.

Replace that step with `openfn project deploy` and an explicit target:

```yaml
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-node@v6
        with:
          node-version: 24.x
      - run: npm install -g @openfn/cli@latest
      - name: openfn project deploy
        run: openfn project deploy main --api-key "$OPENFN_API_KEY" --no-confirm
        env:
          OPENFN_API_KEY: ${{ secrets.OPENFN_<project_uuid>_API_KEY }}
      - uses: stefanzweifel/git-auto-commit-action@v7
        with:
          commit_message: Changes accepted by Lightning; updated current project state
```

Keep the `on:` and `concurrency:` blocks as generated. Lightning rewrites this file if the repo is
disconnected and connected again, so reapply the change after a reconnect.

### 4. Pull the the deployment project into the repo

Fetch, never `pull`. `openfn project pull` is fetch plus checkout, and checking out `local` would
replace `workflows/` with the the deployment project. `fetch` only writes the snapshot file.

```bash
git pull
openfn project fetch <local-project-uuid> \
  --alias local \
  --endpoint https://openfn.example.org \
  --api-key "$DEPLOYMENT_API_KEY"
git add .projects/local@openfn.example.org.yaml
git commit -m "Track openfn.example.org"
git push
```

From now on the alias is enough. The endpoint and UUID are read from the snapshot:

```bash
openfn project fetch local --api-key "$DEPLOYMENT_API_KEY"
```

If the project already had workflows on your deployment, read the snapshot before the first deploy. A
workflow that exists on both sides with the same id is overwritten by the app.openfn version. A
workflow that only exists on your deployment is left alone.

### 5. Map credentials

Steps on app.openfn.org reference credentials as `owner|name`, for example
`diao@openfn.org|DHIS2 Production`. That credential does not exist on your deployment, so a plain deploy is
rejected with `No credential found with name ...` (HTTP 422). `credential-map.yaml` maps every
app.openfn credential to its local equivalent:

```yaml
# app.openfn owner|name  →  local owner|name
"diao@openfn.org|DHIS2 Production":
  alias: "user@example.org|DHIS2 Production"
"diao@openfn.org|CommCare hq Creds":
  alias: "user@example.org|CommCare"
```

The left-hand keys are listed under `credentials:` in `.projects/main@app.openfn.org.yaml`. The
file holds names and email addresses only, no secrets, so it is committed.

List every credential the workflows use. When `--credentials` points at a file, a credential
that isn't in the file is dropped, and every step that used it is deployed with **no
credential**, which clears whatever was set on your deployment. A key that doesn't match any credential in
the project fails the deploy, which catches typos.

Don't call this file `credentials.yaml`. That name is the CLI's file for real secrets when running
workflows locally, and it is gitignored.

### 6. Add the deploy workflow

`.github/workflows/deploy-to-local.yml`, for when GitHub's runners can reach
`https://openfn.example.org/api`. If they can't, use the
[manual deploy](#b-manual-deploy-from-maps-network) instead and skip this file.

```yaml
name: Deploy to openfn.example.org

on:
  workflow_dispatch:

# Same group as the generated deploy workflow, so the two never run at once
concurrency:
  group: openfn-deployment
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    # Add required reviewers to this environment to put an approval in front of every deploy
    environment: local
    permissions:
      contents: write
    env:
      the client_API_KEY: ${{ secrets.DEPLOYMENT_API_KEY }}
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-node@v6
        with:
          node-version: 24.x
      - run: npm install -g @openfn/cli@latest

      - name: Fetch local before deploying
        run: openfn project fetch local --api-key "$DEPLOYMENT_API_KEY"
      - uses: stefanzweifel/git-auto-commit-action@v7
        with:
          commit_message: "openfn.example.org: state before deploy"
          file_pattern: .projects/

      - name: Deploy the app.openfn project to local
        run: |
          openfn project deploy .projects/main@app.openfn.org.yaml local \
            --no-checkout \
            --credentials credential-map.yaml \
            --api-key "$DEPLOYMENT_API_KEY" \
            --no-confirm

      - name: Fetch local after deploying
        run: openfn project fetch local --api-key "$DEPLOYMENT_API_KEY"
      - uses: stefanzweifel/git-auto-commit-action@v7
        with:
          commit_message: "openfn.example.org: state after deploy"
          file_pattern: .projects/
```

Add `DEPLOYMENT_API_KEY` under **Settings → Secrets and variables → Actions**, and create the `local`
environment under **Settings → Environments**.

The trigger is manual on purpose: a sync to GitHub is not the same as a decision to release. To
deploy on every sync instead, add a `push` trigger filtered to
`paths: ['.projects/main@app.openfn.org.yaml']`.

The commits this workflow makes are pushed with the default `GITHUB_TOKEN`, which by GitHub's
design does not trigger other workflows. They will not set off the app.openfn deploy.

## Day to day

### 1. Make the change on app.openfn.org

Edit and test as usual, then **Save & Sync** in the workflow editor, or **Initiate Sync to
Branch** under Project Settings → Sync to GitHub. Wait for the `openfn-pull` action to finish. It
commits the new `workflows/` and `.projects/main@app.openfn.org.yaml`.

Only what has been synced gets deployed. The deploy reads `.projects/main@app.openfn.org.yaml`,
not the live app.

### 2. Deploy to local

#### A. GitHub Action

**Actions → Deploy to openfn.example.org → Run workflow**, then approve it if the environment
requires reviewers. The run log shows the change list before the upload.

#### B. Manual deploy from the client's network

When local can't be reached from the internet, run the same steps from a machine that can reach
both local and github.com:

```bash
git pull

# 1. What is on your deployment right now. Commit it if it differs from the repo
openfn project fetch local --api-key "$DEPLOYMENT_API_KEY"
git add .projects/ && git commit -m "openfn.example.org: state before deploy"

# 2. Preview, then deploy
openfn project deploy .projects/main@app.openfn.org.yaml local \
  --no-checkout --credentials credential-map.yaml \
  --api-key "$DEPLOYMENT_API_KEY" --dry-run
openfn project deploy .projects/main@app.openfn.org.yaml local \
  --no-checkout --credentials credential-map.yaml \
  --api-key "$DEPLOYMENT_API_KEY"

# 3. What is on your deployment now
openfn project fetch local --api-key "$DEPLOYMENT_API_KEY"
git add .projects/ && git commit -m "openfn.example.org: state after deploy"
git push
```

`git commit` reports *nothing to commit* when a fetch changed nothing. That is fine.

Without `--dry-run` the CLI prints the change list and asks
`Ready to deploy changes to https://openfn.example.org?` before uploading.

### Why the deploy command looks like that

- **`.projects/main@app.openfn.org.yaml local`** deploys a file to a target. Given a file, the
  CLI compares every workflow in it against local. Deploying the checked-out project instead
  (`openfn project deploy local`) only sends workflows edited locally since the last checkout,
  which right after a sync is none of them.
- **`--no-checkout`** stops the CLI writing the the deployment project into `openfn.yaml`, `.openfn/` and
  `.projects/` after the deploy. Without it, the repo would afterwards track local instead of
  app.openfn. The cost is that the local snapshot isn't refreshed, which is why step 3 fetches it.
  `OPENFN_NO_CHECKOUT_AFTER_DEPLOY=true` does the same as the flag.
- **`--credentials credential-map.yaml`** see [Map credentials](#5-map-credentials).

UUIDs on your deployment are kept: workflows, steps and triggers are matched by id and keep their local
UUIDs, so **webhook URLs on your deployment do not change** between deploys.

## What a deploy changes on your deployment

| | Result |
|---|---|
| Workflow on both sides | Replaced by the app.openfn version. Changes made on your deployment are lost, but the pre-deploy snapshot keeps a record of them in git |
| Workflow only on app.openfn | Created on your deployment |
| Workflow only on your deployment | Left alone |
| Workflow deleted on app.openfn | **Left on your deployment.** A file deploy does not delete workflows. Delete it on your deployment by hand |
| Credentials | Step references are rewritten through `credential-map.yaml`. Secrets are never sent |
| Collections | Follow app.openfn. A collection that only exists on your deployment is **deleted, with its data**. Collections created by the deploy start empty |
| Webhook URLs and webhook auth | Unchanged |

## Changes made directly on your deployment

Avoid them. If one is needed, for example an urgent fix during an outage:

1. Make the fix on your deployment.
2. Fetch and commit the snapshot (`openfn project fetch local`, commit, push), so the repo knows.
3. Make the same change on app.openfn.org and sync it. Otherwise the next deploy reverts it.

To see how local differs from app.openfn at any point, fetch and diff the two snapshots, or run
the deploy with `--dry-run`.

## Troubleshooting

**`No checked out project found` in the app.openfn deploy action.** Step 3 wasn't applied, or
Lightning rewrote the file after a reconnect.

**`No credential found with name ...` (422).** A credential used by a step is missing from
`credential-map.yaml`, or the local credential it maps to doesn't exist with exactly that owner
and name.

**`The following credentials were not found in the project`.** A left-hand key in
`credential-map.yaml` doesn't match any credential in `.projects/main@app.openfn.org.yaml`. Check
spelling and the owner's email.

**`Failed to find tracked remote project locally`.** `.projects/local@openfn.example.org.yaml` is
missing. Run the first fetch in [step 4](#4-pull-the-local-project-into-the-repo).

**`A project with a different UUID exists at this location`.** A fetch is trying to write a
different project over an existing snapshot. Check the UUID you passed, and pass `--alias local`
on the first fetch.

**`Nothing to deploy`.** local already matches the synced app.openfn project. If you expected
changes, check that the sync on app.openfn finished and that you ran `git pull`.

**401 Unauthorized.** The token for that instance is wrong or expired. Each command takes the key
for the instance it talks to: the app.openfn key for `main`, `DEPLOYMENT_API_KEY` for `local`.
