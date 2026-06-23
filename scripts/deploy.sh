#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/var/www/swapprocaddy"

cd "$REPO_DIR"
git fetch origin main
git reset --hard origin/main

docker compose up -d

echo "swapprocaddy deploy complete"
