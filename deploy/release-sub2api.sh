#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./deploy/release-sub2api.sh --host HOST --user USER [options]

Options:
  --host HOST                     Remote host (required)
  --user USER                     Remote ssh user (required)
  --port PORT                     SSH port (default: 22)
  --mode MODE                     local-docker | remote-build (default: local-docker)
  --remote-app-root PATH          Default: /opt/sub2api/app
  --remote-deploy-dir PATH        Default: /opt/sub2api/app/deploy
  --remote-release-root PATH      Default: /opt/sub2api/releases
  --remote-backup-root PATH       Default: /opt/backups/sub2api
  --remote-domain DOMAIN          Default: key.waisoft.com
  --remote-site-config PATH       Default: /etc/nginx/sites-available/key.waisoft.com
  --compose-file FILE             Default: docker-compose.source.local.yml
  --skip-db-backup                Skip pg_dump
  --skip-remote-health-check      Skip https health check

Notes:
  - local-docker is recommended: build locally, upload image tar, remote only loads + switches.
  - remote-build is fallback only: upload source tar, remote Docker performs the build.
  - Script assumes SSH/SCP access. Do not store passwords in this script.
EOF
}

HOST=""
USER_NAME=""
PORT="22"
MODE="local-docker"
REMOTE_APP_ROOT="/opt/sub2api/app"
REMOTE_DEPLOY_DIR="/opt/sub2api/app/deploy"
REMOTE_RELEASE_ROOT="/opt/sub2api/releases"
REMOTE_BACKUP_ROOT="/opt/backups/sub2api"
REMOTE_DOMAIN="key.waisoft.com"
REMOTE_SITE_CONFIG="/etc/nginx/sites-available/key.waisoft.com"
COMPOSE_FILE="docker-compose.source.local.yml"
SKIP_DB_BACKUP="false"
SKIP_REMOTE_HEALTH_CHECK="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --user) USER_NAME="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --remote-app-root) REMOTE_APP_ROOT="$2"; shift 2 ;;
    --remote-deploy-dir) REMOTE_DEPLOY_DIR="$2"; shift 2 ;;
    --remote-release-root) REMOTE_RELEASE_ROOT="$2"; shift 2 ;;
    --remote-backup-root) REMOTE_BACKUP_ROOT="$2"; shift 2 ;;
    --remote-domain) REMOTE_DOMAIN="$2"; shift 2 ;;
    --remote-site-config) REMOTE_SITE_CONFIG="$2"; shift 2 ;;
    --compose-file) COMPOSE_FILE="$2"; shift 2 ;;
    --skip-db-backup) SKIP_DB_BACKUP="true"; shift ;;
    --skip-remote-health-check) SKIP_REMOTE_HEALTH_CHECK="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$HOST" && -n "$USER_NAME" ]] || { usage; exit 1; }
[[ "$MODE" == "local-docker" || "$MODE" == "remote-build" ]] || { echo "Invalid mode: $MODE" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_ID="$(date -u +%Y%m%dT%H%M%SZ)"
COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
ORIGIN_MAIN="$(git -C "$REPO_ROOT" rev-parse origin/main)"
SHORT_COMMIT="${COMMIT:0:8}"
PACKAGE_NAME="sub2api-${COMMIT:0:12}.tar.gz"
PACKAGE_PATH="$REPO_ROOT/$PACKAGE_NAME"
REMOTE_RELEASE_DIR="$REMOTE_RELEASE_ROOT/$RELEASE_ID"
REMOTE_BACKUP_DIR="$REMOTE_BACKUP_ROOT/$RELEASE_ID"
REMOTE_PACKAGE_PATH="$REMOTE_RELEASE_DIR/$PACKAGE_NAME"
REMOTE_COMPOSE_PATH="$REMOTE_DEPLOY_DIR/$COMPOSE_FILE"
IMAGE_REPOSITORY="sub2api-source"
IMAGE_ALIAS_TAG="$IMAGE_REPOSITORY:local"
IMAGE_VERSION_TAG="$IMAGE_REPOSITORY:$SHORT_COMMIT"
ROLLBACK_TAG="$IMAGE_REPOSITORY:backup-$RELEASE_ID"
LOG_DIR="$REPO_ROOT/docs/deploy-logs"
RUNTIME_LOG="$LOG_DIR/$RELEASE_ID-runtime.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$RUNTIME_LOG") 2>&1

echo "==> verifying git state"
[[ "$COMMIT" == "$ORIGIN_MAIN" ]] || { echo "HEAD is not aligned with origin/main" >&2; exit 1; }

if [[ "$MODE" == "local-docker" ]]; then
  command -v docker >/dev/null 2>&1 || { echo "Docker not found locally; use --mode remote-build or install Docker" >&2; exit 1; }
fi

echo "==> preparing release package"
rm -f "$PACKAGE_PATH"
git -C "$REPO_ROOT" archive --format=tar.gz --output="$PACKAGE_PATH" HEAD
sha256sum "$PACKAGE_PATH"

LOCAL_IMAGE_TAR=""
if [[ "$MODE" == "local-docker" ]]; then
  echo "==> local docker build"
  LOCAL_IMAGE_TAR="$REPO_ROOT/${IMAGE_REPOSITORY}-${SHORT_COMMIT}-image.tar"
  rm -f "$LOCAL_IMAGE_TAR"
  docker build -t "$IMAGE_VERSION_TAG" -f "$REPO_ROOT/Dockerfile" "$REPO_ROOT"
  docker save -o "$LOCAL_IMAGE_TAR" "$IMAGE_VERSION_TAG"
  sha256sum "$LOCAL_IMAGE_TAR"
fi

SSH_TARGET="$USER_NAME@$HOST"
SSH_OPTS=(-p "$PORT" -o StrictHostKeyChecking=accept-new)
SCP_OPTS=(-P "$PORT" -o StrictHostKeyChecking=accept-new)

echo "==> creating remote release paths"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "mkdir -p '$REMOTE_RELEASE_DIR' '$REMOTE_BACKUP_DIR'"

echo "==> uploading package"
scp "${SCP_OPTS[@]}" "$PACKAGE_PATH" "$SSH_TARGET:$REMOTE_PACKAGE_PATH"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sha256sum '$REMOTE_PACKAGE_PATH'"

if [[ "$MODE" == "local-docker" ]]; then
  REMOTE_IMAGE_TAR="$REMOTE_RELEASE_DIR/${IMAGE_REPOSITORY}-${SHORT_COMMIT}-image.tar"
  echo "==> uploading image tar"
  scp "${SCP_OPTS[@]}" "$LOCAL_IMAGE_TAR" "$SSH_TARGET:$REMOTE_IMAGE_TAR"
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sha256sum '$REMOTE_IMAGE_TAR'"
fi

DB_BACKUP_CMD="docker exec sub2api-postgres pg_dump -U sub2api -d sub2api -Fc > '$REMOTE_BACKUP_DIR/sub2api.pgcustom'"
if [[ "$SKIP_DB_BACKUP" == "true" ]]; then
  DB_BACKUP_CMD="echo 'skip db backup' > '$REMOTE_BACKUP_DIR/db-backup-skipped.txt'"
fi

echo "==> remote backup and rollback tag"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" /bin/bash <<EOF
set -euo pipefail
cp '$REMOTE_DEPLOY_DIR/.env' '$REMOTE_BACKUP_DIR/'
cp '$REMOTE_COMPOSE_PATH' '$REMOTE_BACKUP_DIR/'
cp '$REMOTE_SITE_CONFIG' '$REMOTE_BACKUP_DIR/' 2>/dev/null || true
docker compose -f '$REMOTE_COMPOSE_PATH' config > '$REMOTE_BACKUP_DIR/docker-compose.rendered.yml'
docker inspect sub2api > '$REMOTE_BACKUP_DIR/sub2api.container.inspect.json'
docker image inspect '$IMAGE_ALIAS_TAG' > '$REMOTE_BACKUP_DIR/sub2api.image.inspect.json'
$DB_BACKUP_CMD
tar -C '$REMOTE_DEPLOY_DIR' -czf '$REMOTE_BACKUP_DIR/sub2api.data-and-redis.tgz' data redis_data
if docker image inspect '$IMAGE_ALIAS_TAG' >/dev/null 2>&1; then
  docker tag '$IMAGE_ALIAS_TAG' '$ROLLBACK_TAG'
fi
EOF

if [[ "$MODE" == "remote-build" ]]; then
  echo "==> remote build fallback"
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" /bin/bash <<EOF
set -euo pipefail
SRC='$REMOTE_RELEASE_DIR/src'
mkdir -p "\$SRC"
rm -rf "\$SRC"/*
tar -xzf '$REMOTE_PACKAGE_PATH' -C "\$SRC"
rsync -a --delete \
  --exclude 'deploy/.env' \
  --exclude 'deploy/data/' \
  --exclude 'deploy/postgres_data/' \
  --exclude 'deploy/redis_data/' \
  --exclude 'deploy/$COMPOSE_FILE' \
  "\$SRC"/ '$REMOTE_APP_ROOT'/
cd '$REMOTE_DEPLOY_DIR'
docker compose -f '$REMOTE_COMPOSE_PATH' build sub2api | tee '$REMOTE_BACKUP_DIR/build.log'
docker tag '$IMAGE_ALIAS_TAG' '$IMAGE_VERSION_TAG'
EOF
else
  echo "==> docker load on remote"
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" /bin/bash <<EOF
set -euo pipefail
LOAD_OUT=\$(docker load -i '$REMOTE_RELEASE_DIR/${IMAGE_REPOSITORY}-${SHORT_COMMIT}-image.tar')
echo "\$LOAD_OUT" | tee '$REMOTE_BACKUP_DIR/docker-load.log'
docker tag '$IMAGE_VERSION_TAG' '$IMAGE_ALIAS_TAG'
EOF
fi

echo "==> recreate sub2api only"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" /bin/bash <<EOF
set -euo pipefail
cd '$REMOTE_DEPLOY_DIR'
docker compose -f '$REMOTE_COMPOSE_PATH' up -d --no-build --force-recreate sub2api | tee '$REMOTE_BACKUP_DIR/deploy.log'
for i in \$(seq 1 60); do
  if curl -fsS 'http://127.0.0.1:18080/health' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker compose -f '$REMOTE_COMPOSE_PATH' ps > '$REMOTE_BACKUP_DIR/compose_ps.txt'
docker logs --tail 200 sub2api > '$REMOTE_BACKUP_DIR/sub2api.tail.log' 2>&1 || true
docker inspect sub2api --format '{{.Image}} {{.Config.Image}}' > '$REMOTE_BACKUP_DIR/sub2api.image.current.txt'
docker image inspect '$IMAGE_ALIAS_TAG' --format '{{.Id}} {{.Created}}' > '$REMOTE_BACKUP_DIR/sub2api.image.inspect.current.txt'
docker exec sub2api-postgres psql -U sub2api -d sub2api -Atc "select filename from schema_migrations order by filename desc limit 20;" > '$REMOTE_BACKUP_DIR/schema_migrations_after.txt'
curl -fsS 'http://127.0.0.1:18080/health' > '$REMOTE_BACKUP_DIR/health.local.json'
EOF

if [[ "$SKIP_REMOTE_HEALTH_CHECK" != "true" ]]; then
  echo "==> public health check"
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "curl -k -fsS --resolve '$REMOTE_DOMAIN:443:127.0.0.1' 'https://$REMOTE_DOMAIN/health' | tee '$REMOTE_BACKUP_DIR/health.public.json'"
fi

echo "==> deployment done"
echo "commit      : $COMMIT"
echo "release id  : $RELEASE_ID"
echo "backup dir  : $REMOTE_BACKUP_DIR"
echo "rollback tag: $ROLLBACK_TAG"
echo "runtime log : $RUNTIME_LOG"
