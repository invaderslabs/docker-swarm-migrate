# docker-swarm-migrate

One command to migrate a full Docker Swarm environment from an old VPS to a new one.

Backs up all volumes, images, and stacks — then restores everything on the new server automatically. Reusable for any client or infrastructure.

---

## What it does

- Auto-detects SSH keys and guides you through setup if none exist
- Backs up all Docker volumes, images, stack YAML files, and `.env` variables
- Transfers everything to the new VPS over SSH (no intermediate storage needed)
- Restores volumes, loads images, and deploys all stacks in the correct order
- Handles private registries (ghcr.io, Docker Hub) with `--with-registry-auth`
- Builds a Portainer stack name map so Portainer-managed stacks are redeployed with correct names
- Verifies every service reaches `replicas desired` after deploy
- Optionally archives the full backup to a local disk and/or a third server

---

## Requirements

**Old VPS (where you run the script)**
- Bash 4+
- Docker with Swarm mode active
- `ssh`, `scp`, `gzip` available
- Root access

**New VPS**
- SSH accessible from old VPS
- Docker will be installed automatically if not present

---

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/invaderslabs/docker-swarm-migrate/main/migrate.sh -o migrate.sh
chmod +x migrate.sh
bash migrate.sh
```

Run as **root on the old VPS**. The script asks questions once, then handles everything automatically.

---

## How it works

### Phase 1 — Configuration

The script scans `~/.ssh/` for private key files and presents them as options.

| Keys found | Behaviour |
|---|---|
| 0 | Offers to generate a new `ed25519` key, prints the public key, pauses for you to add it to the new VPS |
| 1 | Offers it as the default, shows the public key for verification |
| 2+ | Lists all keys numbered, you pick one |

Then asks for:
- New VPS IP and SSH user
- Path to stack YAML files (default `/root`)
- Path to `.env` file (default `/root/.env`)
- Private registry credentials (optional)
- Remote backup directory on new VPS (default `/backups/docker`)

---

### Phase 2 — Auto Discovery

Discovers everything on the old VPS automatically:

- All Docker volumes (`docker volume ls`)
- All running stacks (`docker stack ls`)
- All Docker images
- All `.yaml` / `.yml` files in the YAML directory
- Portainer-managed stacks: scans `/var/lib/docker/volumes/portainer_data/_data/compose/` and builds a `folder → stack name` map by cross-referencing service names against `docker service ls`

Loads the `.env` file so stack variables are available throughout the script.

---

### Phase 3 — Backup

Stops all running stacks, then:

1. **Volumes** — streams each volume through `alpine tar` and `gzip` directly to the new VPS via SSH (no temporary files on disk)
2. **Images** — saves all images with `docker save`, streams to new VPS
3. **YAML files + `.env`** — copied via `scp`
4. **Metadata** — stack list, volume list, service list, and Portainer stack map saved to `$REMOTE_DIR/meta/`

Failed volumes are skipped and reported, not abort the entire backup.

---

### Phase 4 — Restore on New VPS

Runs a script remotely on the new VPS via SSH:

1. Installs Docker if not present
2. Initialises Docker Swarm
3. Creates `network_public` overlay network and `volume_swarm_shared`
4. Creates all volumes and restores their data
5. Loads Docker images
6. Sources the `.env` file
7. Logs in to private registry (if configured)
8. Deploys stacks in the correct order:

```
traefik  →  postgres / mysql / redis  →  all other stacks  →  portainer-managed stacks  →  portainer
```

Each stack is checked with `docker stack ls` before deploying to avoid duplicates.

---

### Phase 5 — Verify

Checks every service on the new VPS:

```
──────────────────────────────────────────────────────
  ✓ traefik_traefik (1/1)
  ✓ postgres_db (1/1)
  ✓ n8n_editor (1/1)
  ✗ myapp_worker (0/1)   ← FAILED
──────────────────────────────────────────────────────
  Passed: 17   Failed: 1

Troubleshoot failed services:
  docker service ps --no-trunc myapp_worker
  docker service update --force --with-registry-auth myapp_worker
```

---

### Phase 6 — Archive Backup

After a successful migration, optionally save a complete archive of the backup:

**Archive name format:**
```
migration-backup-<old-hostname>-<YYYY-MM-DD-HHMM>.tar.gz
```

**Options:**

1. **Download to old VPS local disk** — useful if the old server has attached/external storage (e.g. `/mnt/backup`)
2. **Push to a third server** — asks for IP, SSH user, key, and remote path, then pushes from the old VPS using its existing SSH key

Both options are independent — you can use one, both, or neither.

The temp archive is cleaned up from the new VPS after transfer.

---

## Deploy Order

Stacks are deployed in a fixed order to respect dependencies:

```
1. traefik          — reverse proxy, must be up first
2. postgres         — primary database
3. mysql            — if present
4. redis            — cache/queue
5. all other stacks — anything else in the YAML directory
6. portainer stacks — stacks managed by Portainer (from its compose directory)
7. portainer        — deployed last so its DB is fully restored before it starts
```

Already-deployed stacks are skipped automatically.

---

## Private Registries

When prompted for a registry, enter the registry hostname:

```
ghcr.io        GitHub Container Registry
registry-1.docker.io   Docker Hub
your.registry.com      Self-hosted
```

The script logs in with your credentials and passes `--with-registry-auth` to every `docker stack deploy` call so Swarm workers can pull private images.

---

## Troubleshooting

**SSH connection fails**

The script prints the public key and the exact command to add it:
```bash
echo 'ssh-ed25519 AAAA...' >> ~/.ssh/authorized_keys
```

**A service stays at `0/1`**

```bash
# See why it won't start
docker service ps --no-trunc <service_name>

# Force re-pull and restart
docker service update --force --with-registry-auth <service_name>
```

**A Portainer-managed stack deploys with wrong name**

The stack name map is built by matching service names to running stacks. If a stack was stopped at discovery time, the mapping falls back to `portainer_stack_<folder_id>`. Rename it after deploy:
```bash
docker stack rm portainer_stack_14
docker stack deploy --with-registry-auth -c /var/lib/docker/volumes/portainer_data/_data/compose/14/docker-compose.yml correct_name
```

**Volume restore fails for an empty volume**

Alpine `tar` returns non-zero on empty volumes. These are skipped with a warning and do not abort the migration.

**`.env` variables not resolving in stacks**

Confirm your `.env` is at the path you specified, and that variable names match what the YAML files reference. You can check what was loaded:
```bash
docker stack deploy --resolve-image always -c yourstack.yaml yourstack
```

---

## License

MIT
