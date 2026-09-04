#!/usr/bin/env bash
# Portable git repository sync indicator.
#
# Walks every git repository under the directories given on the command line
# and reports which ones have work "pending to sync":
#   - uncommitted changes (dirty working tree or untracked files).
#   - local commits ahead of the upstream tracking branch.
#   - HEAD not reachable from any remote tracking ref (when no upstream is
#     configured but at least one remote exists).
#
# Usage: git-status.sh <max_depth> <dir> [dir...]
#        `~` at the start of a dir expands to $HOME.
#
# Emits a single JSON object on stdout:
#
#   {
#     "state": "synced" | "unsynced",
#     "scanned": 12,
#     "pending": [{"name": "foo", "path": "/home/me/code/foo",
#                  "dir": "~/code", "issues": "uncommitted changes"}],
#     "watched": [{"path": "~/code", "state": "ok", "repos": 12, "pending": 1}]
#   }
#
# A watched folder's state is "ok", "missing" (not a directory) or "empty" (no
# repositories below it).
#
# Rendering (icons, colors, layout) belongs to the caller. Deps: bash, git, jq.

set -uo pipefail

MAX_DEPTH="${1:-4}"
shift || true
[ $# -gt 0 ] || set -- "$HOME/code"

scanned=0
pending_json="[]"
watched_json="[]"

add_pending() {
  pending_json=$(jq -c \
    --arg name "$1" --arg path "$2" --arg dir "$3" --arg issues "$4" \
    '. + [{name: $name, path: $path, dir: $dir, issues: $issues}]' \
    <<<"$pending_json")
}

add_watched() {
  watched_json=$(jq -c \
    --arg path "$1" --arg state "$2" --argjson repos "$3" --argjson pending "$4" \
    '. + [{path: $path, state: $state, repos: $repos, pending: $pending}]' \
    <<<"$watched_json")
}

for watch_dir in "$@"; do
  watch_dir="${watch_dir/#\~/$HOME}"
  watch_dir="${watch_dir%/}"
  display_dir="${watch_dir/#$HOME/\~}"

  if [ ! -d "$watch_dir" ]; then
    add_watched "$display_dir" missing 0 0
    continue
  fi

  mapfile -t git_dirs < <(find "$watch_dir" -maxdepth "$MAX_DEPTH" -type d -name .git -prune 2>/dev/null | sort)

  if [ ${#git_dirs[@]} -eq 0 ]; then
    add_watched "$display_dir" empty 0 0
    continue
  fi

  dir_pending=0

  for git_dir in "${git_dirs[@]}"; do
    repo="${git_dir%/.git}"
    scanned=$((scanned + 1))
    issues=()

    if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
      issues+=("uncommitted changes")
    fi

    if git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      ahead=$(git -C "$repo" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
      if [ "${ahead:-0}" -gt 0 ]; then
        issues+=("$ahead unpushed commit(s)")
      fi
    elif git -C "$repo" rev-parse HEAD >/dev/null 2>&1; then
      # No upstream configured. `git push origin main` still puts the commits on
      # the remote, so only flag HEAD that no remote tracking ref contains.
      if [ -n "$(git -C "$repo" remote 2>/dev/null)" ] \
         && [ -z "$(git -C "$repo" branch -r --contains HEAD 2>/dev/null)" ]; then
        issues+=("unpushed")
      fi
    fi

    if [ ${#issues[@]} -gt 0 ]; then
      # ${issues[*]} with IFS=', ' joins on the comma alone -- bash only uses
      # the first character of IFS -- so build the list explicitly.
      joined=$(printf '%s, ' "${issues[@]}")
      add_pending "${repo#$watch_dir/}" "$repo" "$display_dir" "${joined%, }"
      dir_pending=$((dir_pending + 1))
    fi
  done

  add_watched "$display_dir" ok "${#git_dirs[@]}" "$dir_pending"
done

jq -cn \
  --argjson pending "$pending_json" \
  --argjson watched "$watched_json" \
  --argjson scanned "$scanned" \
  '{state: (if ($pending | length) > 0 then "unsynced" else "synced" end),
    scanned: $scanned, pending: $pending, watched: $watched}'
