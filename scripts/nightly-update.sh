#!/usr/bin/env bash
# OpenClaw Nightly Update — pulls upstream, merges with fork, builds, restarts gateway
# Runs via cron at 3AM CT on Mac Mini

set -euo pipefail

REPO_DIR="$HOME/repos/openclaw"
LOG_DIR="$HOME/clawd/data/openclaw-update-log"
DATE=$(date +%Y-%m-%d)
LOG="$LOG_DIR/$DATE.log"

mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

cd "$REPO_DIR"

log "=== OpenClaw nightly update started ==="
log "Current version: $(git describe --tags --always 2>/dev/null || git rev-parse --short HEAD)"

# Clear stale OpenClaw update lock files (older than 2 hours)
LOCK_PATHS=(
    "$HOME/.openclaw/update.lock"
    "$HOME/.openclaw/.update.lock"
    "$HOME/repos/openclaw/.update.lock"
    "$HOME/repos/openclaw/update.lock"
)
STALE_THRESHOLD=7200  # 2 hours in seconds

for LOCK_FILE in "${LOCK_PATHS[@]}"; do
    if [ -f "$LOCK_FILE" ]; then
        LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0) ))
        if [ "$LOCK_AGE" -gt "$STALE_THRESHOLD" ]; then
            log "Removing stale lock file: $LOCK_FILE (age: ${LOCK_AGE}s)"
            rm -f "$LOCK_FILE"
        else
            log "Active lock file found: $LOCK_FILE (age: ${LOCK_AGE}s) — skipping update"
            exit 0
        fi
    fi
done

# Fetch upstream
log "Fetching upstream..."
git fetch upstream 2>&1 | tee -a "$LOG"

# Check if there are new commits
LOCAL=$(git rev-parse HEAD)
UPSTREAM=$(git rev-parse upstream/main)

if [ "$LOCAL" = "$UPSTREAM" ]; then
    log "Already up to date. No update needed."
    exit 0
fi

log "New upstream commits found. Merging..."

# Merge upstream into our main
git merge upstream/main --no-edit 2>&1 | tee -a "$LOG"
MERGE_EXIT=$?

if [ $MERGE_EXIT -ne 0 ]; then
    log "ERROR: Merge conflict! Aborting merge. Manual intervention needed."
    git merge --abort 2>/dev/null
    exit 1
fi

# Push merged changes to our fork
log "Pushing to origin..."
git push origin main 2>&1 | tee -a "$LOG"

# Install deps (in case they changed)
log "Installing dependencies..."
pnpm install 2>&1 | tail -3 | tee -a "$LOG"

# Build
log "Building..."
pnpm build 2>&1 | tail -5 | tee -a "$LOG"

# Restart gateway
log "Restarting gateway..."
openclaw gateway restart 2>&1 | tee -a "$LOG"

NEW_VERSION=$(git describe --tags --always 2>/dev/null || git rev-parse --short HEAD)
log "=== Update complete: $NEW_VERSION ==="
