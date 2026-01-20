# {project name}
✏️TODO: Add project description
_Template repository to back up and document local OpenFn deployments_

## About Your OpenFn Install
✏️ On [X Date], we installed version [YYYY]. 

Key components include: 
- Docker/Kubernetes ??✏️
- Monitoring: Prometheus & Grafana ??✏️
- Database: Postgres v???✏️ (note if you used OpenFn DB, or existing DB setup)

### Server Requirements
See this document for your server specifications and completed deployment questionnaire: 
✏️ [ADD LINK]

## Managing Your Installation
✏️ TODO: Edit these commands below, depending on Docker/Kubernetes and the client's setup

### Docker
**Setting up for the first time**

```sh
docker compose up -d postgres
docker compose run lightning /app/bin/lightning eval Lightning.Release.migrate
docker compose up -d
```

**Updating**

Run `./update_check` and confirm if you want the script to change the compose file

```sh
./update_check
Tags matching the 'latest' digest:

  openfn/lightning:latest -> v2.10.6
  docker-compose.yml      -> v2.10.5
  ⚠️ Update available

  openfn/ws-worker:latest -> v1.8.6
  docker-compose.yml      -> v1.8.5
  ⚠️ Update available
Do you want to update openfn/lightning to v2.10.6? (y/N) y
Updated openfn/lightning to tag v2.10.6 in docker-compose.yml
Backup created at docker-compose.yml.bak
Do you want to update openfn/ws-worker to v1.8.6? (y/N) y
Updated openfn/ws-worker to tag v1.8.6 in docker-compose.yml
Backup created at docker-compose.yml.bak
```

Then run `docker compose up -d` to restart/recreate the containers.

**Copying across files to a server**

```sh
rsync -azv --exclude-from=.gitignore . $SERVER_IP:~/docker
```

**Self-signed certs**

```sh
# Generate a private key
openssl genrsa -out selfsigned.key 2048

# Create a self-signed certificate
openssl req -new -x509 \
  -key selfsigned.key -out selfsigned.crt -days 365 \
  -subj "/C=LC/L=Castries/O=St. Lucia/CN=$SERVER_IP"
```

### Kubernetes
✏️ TODO: Specify steps & commands for managing Kubernetes-based deployments

## Load Testing
✏️TODO: Add link below
See [XYZ] folder for the load testing K6 results. 

## Troubleshooting Tips
✏️TODO: EDIT -> Here detail common errors & troubleshooting guidance. (Link to OpenFn docs if public guide is available.)

## Get Help
✏️Add any support guidance if specific support contacts or escalation paths are decided. 
See below links for helpful resources, or get in touch with `support@openfn.org` for any private queries. 
- [Deployment Guide](https://openfn.github.io/lightning/deployment.html)
- [OpenFn Docs](https://docs.openfn.org/documentation/deploy/options)
- [Community Forum](https://community.openfn.org/)
