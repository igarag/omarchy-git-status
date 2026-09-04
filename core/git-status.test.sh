#!/usr/bin/env bash
# Self-check for git-status.sh. Builds throwaway repositories covering each
# branch of the "is this repo pending?" decision and asserts the verdict.
#
#   ./core/git-status.test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-status.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email test@example.com
git config --global user.name Test
git config --global init.defaultBranch main

failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   $label"
  else
    echo "FAIL $label: expected '$expected', got '$actual'"
    failures=$((failures + 1))
  fi
}

# A repo with one commit, plus a bare "remote" it is already pushed to.
seed() {
  local repo="$WORK/repos/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  echo seed > "$repo/file"
  git -C "$repo" add file
  git -C "$repo" commit -qm seed
  git init -q --bare "$WORK/remotes/$1.git"
  git -C "$repo" remote add origin "$WORK/remotes/$1.git"
  echo "$repo"
}

verdict() { "$SCRIPT" 3 "$WORK/repos" | jq -r '.state'; }
issues_for() { "$SCRIPT" 3 "$WORK/repos" | jq -r --arg n "$1" '.pending[] | select(.name == $n) | .issues'; }

# No remote at all: nothing to be out of sync with.
repo=$(seed local-only)
git -C "$repo" remote remove origin
check "repo with no remote is synced" synced "$(verdict)"
rm -rf "$WORK/repos" "$WORK/remotes"

# Pushed without -u. No upstream is configured, but HEAD is on the remote, so
# this must NOT be reported — the regression this fallback exists for.
repo=$(seed pushed-no-upstream)
git -C "$repo" push -q origin main
check "pushed without -u is synced" synced "$(verdict)"

# Same repo, now with a commit that never left.
echo more > "$repo/file"
git -C "$repo" commit -qam second
check "unpushed commit without upstream" "unpushed" "$(issues_for pushed-no-upstream)"
rm -rf "$WORK/repos" "$WORK/remotes"

# Tracking branch configured, one commit ahead.
repo=$(seed tracking)
git -C "$repo" push -qu origin main
echo more > "$repo/file"
git -C "$repo" commit -qam second
check "commit ahead of upstream" "1 unpushed commit(s)" "$(issues_for tracking)"

# An untracked file is pending work too, and both issues are reported together.
touch "$repo/scratch"
check "untracked file plus ahead" "uncommitted changes, 1 unpushed commit(s)" "$(issues_for tracking)"
rm -rf "$WORK/repos" "$WORK/remotes"

# Folders that cannot be scanned are notes, not pending repos.
mkdir -p "$WORK/repos"
check "missing folder is a note" "$WORK/gone does not exist" \
  "$("$SCRIPT" 3 "$WORK/gone" | jq -r '.notes[0]')"
check "folder without repos is a note" "$WORK/repos has no git repos" \
  "$("$SCRIPT" 3 "$WORK/repos" | jq -r '.notes[0]')"

[ $failures -eq 0 ] || { echo "$failures check(s) failed"; exit 1; }
echo "all checks passed"
