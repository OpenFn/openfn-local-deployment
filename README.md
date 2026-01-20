# {project name}
Template repository to back up and document local OpenFn deployments

## Docker

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
