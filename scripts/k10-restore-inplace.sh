#!/usr/bin/env bash
# Wrap an IN-PLACE Kasten K10 restore with the Argo CD sync pause it needs.
#
# Why: K10 restores in place by scaling the app to 0 and deleting/recreating
# its PVCs. Argo selfHeal sees both as drift and reverts them mid-restore
# (scales the app back up, recreates the PVC blank from git), deadlocking
# the restore until it times out ("Failed to scale down some of workloads").
# Root app must be paused before the child, or root's selfHeal re-enables
# the child's sync.
#
# Restores into a NEW namespace ("Restore as" in the dashboard) touch no
# Argo-managed resources and do NOT need this script.
#
# Usage: scripts/k10-restore-inplace.sh <app-name>   # app == its namespace
#   1. Pauses auto-sync on root, then the app.
#   2. Waits for you to trigger the restore in the K10 dashboard.
#   3. Waits for the RestoreAction to finish (K10 retries on its own).
#   4. Re-enables auto-sync (also on ctrl-c / failure, via trap).

set -euo pipefail

APP="${1:?usage: k10-restore-inplace.sh <app-name>}"
command -v kubectl >/dev/null && KUBECTL=kubectl || KUBECTL="nix run nixpkgs#kubectl --"

pause()  { $KUBECTL -n argocd patch applications.argoproj.io "$1" --type merge \
             -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null; }
resume() { $KUBECTL -n argocd patch applications.argoproj.io "$1" --type merge \
             -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null; }

cleanup() {
  echo "Re-enabling auto-sync (app, then root)..."
  resume "$APP" || true
  resume root || true
}
trap cleanup EXIT

echo "Pausing auto-sync: root, then $APP"
pause root
pause "$APP"

echo
echo ">> Trigger the in-place restore for '$APP' in the K10 dashboard now."
echo ">> Waiting for a RestoreAction in namespace $APP..."

deadline=$(( $(date +%s) + 3600 ))
state=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  state=$($KUBECTL -n "$APP" get restoreactions.actions.kio.kasten.io \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].status.state}' 2>/dev/null || true)
  case "$state" in
    Complete) echo "Restore Complete."; exit 0 ;;
    Failed)   echo "Restore FAILED — check the K10 dashboard."; exit 1 ;;
    Running)  printf 'Running (%s%%)\r' "$($KUBECTL -n "$APP" get restoreactions.actions.kio.kasten.io --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].status.progress}' 2>/dev/null)" ;;
  esac
  sleep 10
done
echo "Timed out after 1h waiting for the restore."
exit 1
