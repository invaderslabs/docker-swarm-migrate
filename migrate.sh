#!/usr/bin/env bash
# migrate.sh — Universal Docker Swarm migration script v2.0
# Run on OLD VPS as root.
set -euo pipefail

# ─── HELPERS ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $1${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}\n"; }

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║    Docker Swarm Migration Script  v2.0       ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ─── PHASE 1: COLLECT INFO ───────────────────────────────────────────────────
header "PHASE 1 — CONFIGURATION"

# SSH key auto-detection
info "Scanning ~/.ssh for private keys..."
FOUND_KEYS=()
for f in "$HOME/.ssh"/*; do
  [ -f "$f" ]                                         || continue
  [[ "$f" == *.pub ]]                                 && continue
  [[ "$f" == *known_hosts* ]]                         && continue
  [[ "$f" == *authorized_keys* ]]                     && continue
  [[ "$f" == *config ]]                               && continue
  head -1 "$f" 2>/dev/null | grep -q "PRIVATE KEY"   || continue
  FOUND_KEYS+=("$f")
done

SSH_KEY=""
if [ "${#FOUND_KEYS[@]}" -eq 0 ]; then
  warn "No SSH private keys found in ~/.ssh/"
  echo ""
  read -p "Generate a new key now? (y/n): " GEN_KEY
  if [ "$GEN_KEY" = "y" ]; then
    ssh-keygen -t ed25519 -f "$HOME/.ssh/backup_key" -N "" -C "migration-key"
    SSH_KEY="$HOME/.ssh/backup_key"
    echo ""
    echo "Public key — add this to the new VPS ~/.ssh/authorized_keys:"
    echo "──────────────────────────────────────────────────────────────"
    cat "${SSH_KEY}.pub"
    echo "──────────────────────────────────────────────────────────────"
    echo ""
    echo "  Run on new VPS:  mkdir -p ~/.ssh && echo '$(cat "${SSH_KEY}.pub")' >> ~/.ssh/authorized_keys"
    echo ""
    read -p "Press ENTER when the key has been added to the new VPS..."
  else
    read -p "Enter path to your SSH private key: " SSH_KEY
  fi

elif [ "${#FOUND_KEYS[@]}" -eq 1 ]; then
  SSH_KEY="${FOUND_KEYS[0]}"
  info "Found key: $SSH_KEY"
  if [ -f "${SSH_KEY}.pub" ]; then
    echo "  Public key: $(cat "${SSH_KEY}.pub")"
  fi
  read -p "Use this key? [y]: " USE_KEY
  if [ "${USE_KEY:-y}" != "y" ]; then
    read -p "Enter path to your SSH private key: " SSH_KEY
  fi

else
  echo "Found ${#FOUND_KEYS[@]} SSH keys:"
  for i in "${!FOUND_KEYS[@]}"; do
    echo "  $((i+1)). ${FOUND_KEYS[$i]}"
  done
  read -p "Which key to use? [1]: " KEY_CHOICE
  SSH_KEY="${FOUND_KEYS[$((${KEY_CHOICE:-1}-1))]}"
  info "Using: $SSH_KEY"
fi

echo ""
read -p "New VPS IP address: " NEW_VPS_IP
read -p "SSH user on new VPS [root]: " SSH_USER;          SSH_USER="${SSH_USER:-root}"
read -p "Stack yaml directory [/root]: " YAML_DIR;        YAML_DIR="${YAML_DIR:-/root}"
read -p ".env file path [/root/.env]: " ENV_FILE;         ENV_FILE="${ENV_FILE:-/root/.env}"
read -p "Private registry? (ghcr.io/dockerhub/none) [none]: " REGISTRY; REGISTRY="${REGISTRY:-none}"

REGISTRY_USER=""; REGISTRY_TOKEN=""
if [ "$REGISTRY" != "none" ]; then
  read -p "Registry username: " REGISTRY_USER
  read -s -p "Registry token/password: " REGISTRY_TOKEN
  echo ""
fi

read -p "Remote backup dir on new VPS [/backups/docker]: " REMOTE_DIR
REMOTE_DIR="${REMOTE_DIR:-/backups/docker}"

SSH_DEST="${SSH_USER}@${NEW_VPS_IP}"
TAG="$(date +%F-%H%M)"
OLD_HOSTNAME="$(hostname)"

# ─── PHASE 2: AUTO DISCOVERY ─────────────────────────────────────────────────
header "PHASE 2 — AUTO DISCOVERY"

# Test SSH
info "Testing SSH connection to $SSH_DEST..."
if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "$SSH_DEST" "echo ok" &>/dev/null; then
  error "Cannot connect to $SSH_DEST using key $SSH_KEY"
  if [ -f "${SSH_KEY}.pub" ]; then
    echo ""
    echo "Add this public key to the new VPS and retry:"
    echo "──────────────────────────────────────────────"
    cat "${SSH_KEY}.pub"
    echo "──────────────────────────────────────────────"
    echo "Run on new VPS: echo '$(cat "${SSH_KEY}.pub")' >> ~/.ssh/authorized_keys"
  fi
  exit 1
fi
success "SSH connection OK"

# Volumes
VOLUMES=()
while IFS= read -r v; do VOLUMES+=("$v"); done < <(docker volume ls -q)
info "Found ${#VOLUMES[@]} volumes: ${VOLUMES[*]:-none}"

# Stacks
STACKS=()
while IFS= read -r s; do STACKS+=("$s"); done < <(docker stack ls --format '{{.Name}}' 2>/dev/null || true)
info "Found ${#STACKS[@]} stacks: ${STACKS[*]:-none}"

# Images
IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | sort -u | tr '\n' ' ')
info "Found images: ${IMAGES:-none}"

# Yaml files
YAML_FILES=()
while IFS= read -r f; do YAML_FILES+=("$f"); done < <(find "$YAML_DIR" -maxdepth 1 \( -name "*.yaml" -o -name "*.yml" \) 2>/dev/null || true)
info "Found ${#YAML_FILES[@]} yaml files in $YAML_DIR"

# Load .env
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
  success ".env loaded from $ENV_FILE"
else
  warn ".env not found at $ENV_FILE"
fi

# Build Portainer stack name map (folder_id:stack_name)
PORTAINER_VOL=$(docker volume ls -q | grep portainer_data | head -1 || echo "portainer_data")
PORTAINER_COMPOSE_DIR="/var/lib/docker/volumes/${PORTAINER_VOL}/_data/compose"
PORTAINER_STACK_MAP=()

if [ -d "$PORTAINER_COMPOSE_DIR" ]; then
  info "Building Portainer stack → folder map..."
  for dir in "$PORTAINER_COMPOSE_DIR"/*/; do
    [ -d "$dir" ] || continue
    folder=$(basename "$dir")
    file="$dir/docker-compose.yml"
    [ -f "$file" ] || continue
    matched=""
    while IFS= read -r svc; do
      svc=$(echo "$svc" | tr -d ' :')
      [ -z "$svc" ] && continue
      stack=$(docker service ls --format '{{.Name}}' 2>/dev/null | grep "_${svc}$" | head -1 | sed 's/_[^_]*$//' || true)
      if [ -n "$stack" ]; then
        matched="$stack"
        break
      fi
    done < <(grep -E "^  [a-zA-Z]" "$file" 2>/dev/null || true)
    if [ -n "$matched" ]; then
      PORTAINER_STACK_MAP+=("${folder}:${matched}")
      info "  Folder $folder → stack '$matched'"
    else
      warn "  Folder $folder → could not map to a running stack (will use 'portainer_stack_${folder}')"
      PORTAINER_STACK_MAP+=("${folder}:portainer_stack_${folder}")
    fi
  done
  info "Mapped ${#PORTAINER_STACK_MAP[@]} Portainer stacks"
fi

# ─── SUMMARY ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║             MIGRATION SUMMARY                ║"
echo "╠══════════════════════════════════════════════╣"
printf "║  %-22s %-21s ║\n" "Old VPS:"           "$OLD_HOSTNAME"
printf "║  %-22s %-21s ║\n" "New VPS:"           "$SSH_DEST"
printf "║  %-22s %-21s ║\n" "Volumes:"           "${#VOLUMES[@]}"
printf "║  %-22s %-21s ║\n" "Stacks:"            "${#STACKS[@]}"
printf "║  %-22s %-21s ║\n" "Yaml files:"        "${#YAML_FILES[@]}"
printf "║  %-22s %-21s ║\n" "Portainer stacks:"  "${#PORTAINER_STACK_MAP[@]}"
printf "║  %-22s %-21s ║\n" "Registry:"          "$REGISTRY"
printf "║  %-22s %-21s ║\n" "Remote backup dir:" "$REMOTE_DIR"
echo "╚══════════════════════════════════════════════╝"
echo ""
warn "This will STOP all stacks on this VPS."
read -p "Ready to start? (y/n): " CONFIRM
[ "$CONFIRM" != "y" ] && echo "Aborted." && exit 0

# ─── PHASE 3: BACKUP ─────────────────────────────────────────────────────────
header "PHASE 3 — BACKUP"

info "Creating remote directories..."
ssh -i "$SSH_KEY" "$SSH_DEST" "mkdir -p $REMOTE_DIR/volumes $REMOTE_DIR/images $REMOTE_DIR/yaml $REMOTE_DIR/meta"
success "Remote directories ready"

# Stop stacks
if [ "${#STACKS[@]}" -gt 0 ]; then
  info "Stopping stacks..."
  for stack in "${STACKS[@]}"; do
    info "  Stopping: $stack"
    docker stack rm "$stack" || true
  done
  info "Waiting 25 seconds for containers to stop..."
  sleep 25
  success "All stacks stopped"
fi

# Backup volumes
info "Backing up ${#VOLUMES[@]} volumes..."
FAILED_VOLS=()
for vol in "${VOLUMES[@]}"; do
  info "  Backing up: $vol"
  if docker run --rm -v "${vol}":/data alpine sh -c "tar -C /data -cf - ." \
      | gzip -c \
      | ssh -i "$SSH_KEY" "$SSH_DEST" "cat > $REMOTE_DIR/volumes/${vol}.tar.gz"; then
    success "  ✓ $vol"
  else
    warn "  ✗ $vol — skipped"
    FAILED_VOLS+=("$vol")
  fi
done
[ "${#FAILED_VOLS[@]}" -gt 0 ] && warn "Skipped volumes: ${FAILED_VOLS[*]}"

# Backup images
if [ -n "$IMAGES" ]; then
  info "Saving Docker images..."
  # shellcheck disable=SC2086
  docker save $IMAGES \
    | gzip -c \
    | ssh -i "$SSH_KEY" "$SSH_DEST" "cat > $REMOTE_DIR/images/all-images.tar.gz"
  success "Images saved"
else
  warn "No images found to save"
fi

# Copy yaml + .env
info "Copying yaml files..."
for f in "${YAML_FILES[@]:-}"; do
  [ -f "$f" ] || continue
  scp -i "$SSH_KEY" "$f" "$SSH_DEST:$REMOTE_DIR/yaml/" && success "  ✓ $(basename "$f")" || warn "  Could not copy $f"
done
[ -f "$ENV_FILE" ] && scp -i "$SSH_KEY" "$ENV_FILE" "$SSH_DEST:$REMOTE_DIR/yaml/.env" && success "  ✓ .env"

# Save metadata
info "Saving metadata..."
docker stack ls   > /tmp/mig_stacks.txt   2>/dev/null && scp -i "$SSH_KEY" /tmp/mig_stacks.txt   "$SSH_DEST:$REMOTE_DIR/meta/stacks.txt"   || true
docker volume ls  > /tmp/mig_volumes.txt  2>/dev/null && scp -i "$SSH_KEY" /tmp/mig_volumes.txt  "$SSH_DEST:$REMOTE_DIR/meta/volumes.txt"  || true
docker service ls > /tmp/mig_services.txt 2>/dev/null && scp -i "$SSH_KEY" /tmp/mig_services.txt "$SSH_DEST:$REMOTE_DIR/meta/services.txt" || true
rm -f /tmp/mig_stacks.txt /tmp/mig_volumes.txt /tmp/mig_services.txt

if [ "${#PORTAINER_STACK_MAP[@]}" -gt 0 ]; then
  printf '%s\n' "${PORTAINER_STACK_MAP[@]}" > /tmp/mig_portainer_map.txt
  scp -i "$SSH_KEY" /tmp/mig_portainer_map.txt "$SSH_DEST:$REMOTE_DIR/meta/portainer_stack_map.txt"
  rm -f /tmp/mig_portainer_map.txt
  success "Portainer stack map saved"
fi

success "Backup complete"

# ─── PHASE 4: RESTORE ────────────────────────────────────────────────────────
header "PHASE 4 — RESTORE ON NEW VPS"

ssh -i "$SSH_KEY" "$SSH_DEST" bash << REMOTE_SCRIPT
set -euo pipefail

# Helpers — must be defined here, this runs on the remote server
info()    { echo -e "\033[0;34m[INFO]\033[0m  \$1"; }
success() { echo -e "\033[0;32m[OK]\033[0m    \$1"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m  \$1"; }
error()   { echo -e "\033[0;31m[ERROR]\033[0m \$1"; }

# Variables passed from local shell (intentionally expanded by heredoc)
REMOTE_DIR="$REMOTE_DIR"
REGISTRY="$REGISTRY"
REGISTRY_USER="$REGISTRY_USER"
REGISTRY_TOKEN="$REGISTRY_TOKEN"

# Install Docker if needed
info "Checking Docker..."
if ! command -v docker &>/dev/null; then
  info "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker && systemctl start docker
fi
success "Docker ready (\$(docker --version | cut -d' ' -f3 | tr -d ','))"

# Init Swarm
info "Initializing Docker Swarm..."
docker swarm init 2>/dev/null || info "Swarm already active"

# Overlay network
info "Creating overlay network..."
docker network create --driver overlay --attachable network_public 2>/dev/null || true

# Shared helper volumes
docker volume create volume_swarm_shared 2>/dev/null || true

# Create all volumes from backup
info "Creating volumes..."
for tar in \$REMOTE_DIR/volumes/*.tar.gz; do
  [ -f "\$tar" ] || continue
  vol=\$(basename "\$tar" .tar.gz)
  docker volume create "\$vol" 2>/dev/null || true
done
success "Volumes created"

# Load images
info "Loading Docker images..."
if [ -f "\$REMOTE_DIR/images/all-images.tar.gz" ]; then
  gunzip -c "\$REMOTE_DIR/images/all-images.tar.gz" | docker load
  success "Images loaded"
else
  warn "No image archive found — skipping"
fi

# Restore volume data
info "Restoring volume data..."
for tar in \$REMOTE_DIR/volumes/*.tar.gz; do
  [ -f "\$tar" ] || continue
  vol=\$(basename "\$tar" .tar.gz)
  info "  Restoring: \$vol"
  gunzip -c "\$tar" | docker run --rm -i -v "\${vol}":/data alpine sh -c "tar -C /data -xpf -" || warn "  Could not restore \$vol"
done
success "Volume data restored"

# Load .env
if [ -f "\$REMOTE_DIR/yaml/.env" ]; then
  set -a; source "\$REMOTE_DIR/yaml/.env"; set +a
  success ".env loaded"
else
  warn ".env not found — stack env vars may be missing"
fi

# Registry login
if [ "\$REGISTRY" != "none" ] && [ -n "\$REGISTRY_TOKEN" ]; then
  info "Logging in to \$REGISTRY..."
  echo "\$REGISTRY_TOKEN" | docker login "\$REGISTRY" -u "\$REGISTRY_USER" --password-stdin
  success "Registry login OK"
fi

# Helpers
is_deployed() { docker stack ls --format '{{.Name}}' | grep -q "^\$1\$"; }
deploy_stack() {
  local file="\$1" name="\$2"
  info "  Deploying: \$name"
  docker stack deploy --with-registry-auth -c "\$file" "\$name" 2>&1 | grep -v "Ignoring unsupported" || true
}

info "Deploying stacks in order..."

# 1. Traefik first
for f in \$REMOTE_DIR/yaml/traefik.yaml \$REMOTE_DIR/yaml/traefik.yml; do
  [ -f "\$f" ] || continue
  is_deployed traefik || { deploy_stack "\$f" traefik; sleep 5; }
  break
done

# 2. Databases
for db in postgres mysql redis; do
  for f in \$REMOTE_DIR/yaml/\${db}.yaml \$REMOTE_DIR/yaml/\${db}.yml; do
    [ -f "\$f" ] || continue
    is_deployed "\$db" || deploy_stack "\$f" "\$db"
    break
  done
done

# 3. All remaining yaml stacks (skip already-handled and portainer)
SKIP_NAMES="traefik postgres mysql redis portainer"
for f in \$REMOTE_DIR/yaml/*.yaml \$REMOTE_DIR/yaml/*.yml; do
  [ -f "\$f" ] || continue
  name=\$(basename "\$f" .yaml); name=\$(basename "\$name" .yml)
  echo "\$SKIP_NAMES" | grep -qw "\$name" && continue
  is_deployed "\$name" && continue
  deploy_stack "\$f" "\$name"
done

# 4. Portainer-managed stacks (from map built during backup)
if [ -f "\$REMOTE_DIR/meta/portainer_stack_map.txt" ]; then
  info "Deploying Portainer-managed stacks..."
  while IFS=: read -r folder stack_name; do
    [ -n "\$folder" ] || continue
    file="/var/lib/docker/volumes/portainer_data/_data/compose/\${folder}/docker-compose.yml"
    [ -f "\$file" ] || { warn "  Compose file not found for folder \$folder — skipping"; continue; }
    is_deployed "\$stack_name" && continue
    deploy_stack "\$file" "\$stack_name" || warn "  Stack \$stack_name failed — skipping"
  done < "\$REMOTE_DIR/meta/portainer_stack_map.txt"
fi

# 5. Portainer last
for f in \$REMOTE_DIR/yaml/portainer.yaml \$REMOTE_DIR/yaml/portainer.yml; do
  [ -f "\$f" ] || continue
  is_deployed portainer || deploy_stack "\$f" portainer
  break
done

info "Waiting 30 seconds for services to stabilise..."
sleep 30
success "All stacks deployed"
REMOTE_SCRIPT

success "Restore complete"

# ─── PHASE 5: VERIFY ─────────────────────────────────────────────────────────
header "PHASE 5 — VERIFY"

ssh -i "$SSH_KEY" "$SSH_DEST" bash << 'VERIFY_SCRIPT'
echo ""
echo "Service Status:"
echo "──────────────────────────────────────────────────────"
FAILED=0; PASSED=0; FAILED_NAMES=()
while IFS= read -r line; do
  name=$(echo "$line"     | awk '{print $2}')
  replicas=$(echo "$line" | awk '{print $4}')
  [ "$name" = "NAME" ] && continue
  [[ "$replicas" == *"/"* ]] || continue
  current=$(echo "$replicas" | cut -d'/' -f1)
  desired=$(echo "$replicas"  | cut -d'/' -f2)
  if [ "$current" = "$desired" ]; then
    echo -e "\033[0;32m  ✓ $name ($replicas)\033[0m"
    PASSED=$((PASSED+1))
  else
    echo -e "\033[0;31m  ✗ $name ($replicas)\033[0m"
    FAILED=$((FAILED+1))
    FAILED_NAMES+=("$name")
  fi
done < <(docker service ls)
echo "──────────────────────────────────────────────────────"
echo "  Passed: $PASSED   Failed: $FAILED"
echo ""
if [ "$FAILED" -gt 0 ]; then
  echo "Troubleshoot failed services:"
  for svc in "${FAILED_NAMES[@]}"; do
    echo "  docker service ps --no-trunc $svc"
    echo "  docker service update --force --with-registry-auth $svc"
    echo ""
  done
fi
VERIFY_SCRIPT

# ─── PHASE 6: ARCHIVE BACKUP ─────────────────────────────────────────────────
header "PHASE 6 — ARCHIVE BACKUP"

echo ""
read -p "Save a full backup archive? (y/n): " SAVE_BACKUP
if [ "$SAVE_BACKUP" != "y" ]; then
  info "Skipping archive backup."
else
  ARCHIVE_NAME="migration-backup-${OLD_HOSTNAME}-${TAG}.tar.gz"
  info "Creating archive $ARCHIVE_NAME on new VPS..."
  ssh -i "$SSH_KEY" "$SSH_DEST" \
    "tar -C $(dirname "$REMOTE_DIR") -czf /tmp/$ARCHIVE_NAME $(basename "$REMOTE_DIR")"
  success "Archive created on new VPS"

  LOCAL_ARCHIVE=""

  # Save to old VPS local disk
  read -p "Download archive to this server (old VPS)? (y/n): " SAVE_LOCAL
  if [ "$SAVE_LOCAL" = "y" ]; then
    read -p "Local path [/mnt/backup]: " LOCAL_BACKUP_PATH
    LOCAL_BACKUP_PATH="${LOCAL_BACKUP_PATH:-/mnt/backup}"
    mkdir -p "$LOCAL_BACKUP_PATH"
    info "Downloading archive..."
    scp -i "$SSH_KEY" "$SSH_DEST:/tmp/$ARCHIVE_NAME" "$LOCAL_BACKUP_PATH/$ARCHIVE_NAME"
    LOCAL_ARCHIVE="$LOCAL_BACKUP_PATH/$ARCHIVE_NAME"
    success "Saved: $LOCAL_ARCHIVE  ($(du -sh "$LOCAL_ARCHIVE" | cut -f1))"
  fi

  # Push to third server
  read -p "Push archive to a third server? (y/n): " SAVE_REMOTE
  if [ "$SAVE_REMOTE" = "y" ]; then
    # Download to temp if not already local
    if [ -z "$LOCAL_ARCHIVE" ]; then
      info "Downloading archive to /tmp first..."
      scp -i "$SSH_KEY" "$SSH_DEST:/tmp/$ARCHIVE_NAME" "/tmp/$ARCHIVE_NAME"
      LOCAL_ARCHIVE="/tmp/$ARCHIVE_NAME"
    fi
    read -p "Third server IP: " THIRD_IP
    read -p "SSH user [root]: " THIRD_USER;     THIRD_USER="${THIRD_USER:-root}"
    read -p "SSH key [$SSH_KEY]: " THIRD_KEY;   THIRD_KEY="${THIRD_KEY:-$SSH_KEY}"
    read -p "Remote path [/backups]: " THIRD_PATH; THIRD_PATH="${THIRD_PATH:-/backups}"
    info "Pushing to $THIRD_USER@$THIRD_IP:$THIRD_PATH..."
    scp -i "$THIRD_KEY" "$LOCAL_ARCHIVE" "${THIRD_USER}@${THIRD_IP}:${THIRD_PATH}/"
    success "Pushed: $ARCHIVE_NAME → $THIRD_USER@$THIRD_IP:$THIRD_PATH/"
    # Clean temp if we downloaded only for this push
    [ "$LOCAL_ARCHIVE" = "/tmp/$ARCHIVE_NAME" ] && rm -f "/tmp/$ARCHIVE_NAME"
  fi

  # Clean up archive on new VPS
  ssh -i "$SSH_KEY" "$SSH_DEST" "rm -f /tmp/$ARCHIVE_NAME" || true
  info "Cleaned up temp archive on new VPS"
fi

# ─── DONE ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║           MIGRATION COMPLETE                 ║"
echo "╠══════════════════════════════════════════════╣"
printf "║  %-22s %-21s ║\n" "New VPS IP:"  "$NEW_VPS_IP"
printf "║  %-22s %-21s ║\n" "Portainer:"   "http://$NEW_VPS_IP:9000"
echo "╠══════════════════════════════════════════════╣"
echo "║  Next steps:                                 ║"
echo "║  1. Update DNS — point domains to new VPS    ║"
echo "║  2. Verify services in Portainer             ║"
echo "║  3. Decommission old VPS after DNS settles   ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
