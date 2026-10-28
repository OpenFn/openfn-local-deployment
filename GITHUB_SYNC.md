# GitHub Sync Configuration

> ✏️ **Template.** Replace every `example.org`, every `10.0.0.x`, and every
> `COUNTRY-openfn-deployment` before this goes to a client. Delete anything
> that does not apply to this deployment rather than leaving it unanswered.
GitHub Sync connects Lightning projects to GitHub repositories for version control.

Before you start: the deployment tooling does not know about GitHub Sync. The variables below go
into `/opt/openfn/.env`, which a managed run regenerates from the inventory, so **tell OpenFn when
you enable this** and we will carry the values into the inventory. Until then, keep a copy of the six
lines somewhere safe and re-add them after any managed run.

## 1. Create a GitHub App

Go to <https://github.com/settings/apps/new> (or for organizations:
`https://github.com/organizations/YOUR_ORG/settings/apps/new`)

**Basic Settings:**

- **App name:** `lightning-COUNTRY`
- **Homepage URL:** `https://openfn.example.org`
- **Callback URL:** `https://openfn.example.org/oauth/github/callback`
- **Webhook URL:** `https://openfn.example.org/api/github/webhook`
- **Webhook secret:** Generate with `openssl rand -hex 32`

**Repository Permissions (Required):**

| Permission | Level          | Purpose                      |
| ---------- | -------------- | ---------------------------- |
| Contents   | Read and write | Read/write project files     |
| Metadata   | Read-only      | Required by GitHub           |
| Secrets    | Read and write | Store deployment credentials |
| Workflows  | Read and write | Sync workflow files          |
| Actions    | Read and write | Trigger GitHub Actions       |

**Events (Required):**

| Event | Purpose                         |
| ----- | ------------------------------- |
| Push  | Detect commits to synced branch |

**Where can this app be installed:** Only on this account (for single-deployment apps)

## 2. Generate Credentials

After creating the app:

1. Note the **App ID** and **Client ID** from the settings page
2. Generate a **Client Secret**
3. Generate a **Private Key** (downloads as .pem file)

## 3. Configure Lightning, on both application servers

Add these lines to `/opt/openfn/.env` on **`app-vm-01` and `app-vm-02`**, with identical values.
The two servers are one cluster, and a request can land on either.

```ini
GITHUB_APP_ID=your_app_id
GITHUB_APP_NAME=your-app-name
GITHUB_APP_CLIENT_ID=your_client_id
GITHUB_APP_CLIENT_SECRET=your_client_secret
GITHUB_CERT=base64_encoded_private_key
REPO_CONNECTION_SIGNING_SECRET=generate_with_openssl_rand_base64_32
```

To base64 encode the private key:

```sh
base64 -w0 your-app.private-key.pem
```

To generate the signing secret:

```sh
openssl rand -base64 32
```

## 4. Apply Configuration

`docker compose restart` does not reload `.env`. Recreate Lightning on each server, `app-vm-02`
first, then `app-vm-01`, waiting for each to report healthy:

```sh
sudo /opt/openfn/bin/openfn-restart
```

## 5. Install the App

1. Go to your GitHub App's settings page
2. Click **Install App**
3. Select the account/organization and choose which repositories to enable

## 6. Connect a Project

1. In Lightning, go to **Project Settings** > **Version Control**
2. Click **Authorize with GitHub**
3. Select the repository and branch
4. Click **Connect branch and initiate sync**

## Troubleshooting

**"Version Control is not configured":** one of the six variables is missing on the server that
served the request. Check both servers, then recreate Lightning (step 4).

**"Resource not accessible by integration":** the GitHub App lacks permission on the repository.
Check Contents and Secrets are "Read and write" at
`https://github.com/settings/apps/YOUR_APP/permissions`, and that the app is installed on the
repository. To clear stale authorisations, ask OpenFn; it needs a write against the client's database.

**"redirect_uri is not associated with this application":** the callback URL in the GitHub App must
match `https://openfn.example.org/oauth/github/callback`.
