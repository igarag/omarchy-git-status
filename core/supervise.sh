#!/usr/bin/env bash
# Keeps the scan's process group alive until it has been killed outright.
#
# Usage: supervise.sh <grace_sec> <cmd> [args...]
#
# Runs under timeout(1), which leads the group. A TERM -- timeout's deadline, or
# the panel stopping timeout, which forwards it -- reaches the whole group, but
# find/git can ignore it and outlive their script. So this does not exit on
# TERM: it waits out the grace period, then sends KILL to its own group.
#
# That KILL is only safe because it comes from inside. While this shell is a
# member the group id cannot be recycled, so the signal reaches our stragglers
# and nothing else. A KILL sent by number from outside, after the group might
# have emptied, can land on an unrelated group that reused the id.

set -u
export PATH=/usr/bin:/bin

grace=$1
shift
doomed=
trap 'doomed=1' TERM INT HUP

"$@" &
wait $!
rc=$?
[ -z "$doomed" ] && exit "$rc"

# Inherited by sleep, so a repeated TERM cannot cut the grace period short.
trap '' TERM INT HUP
sleep "$grace"
kill -KILL 0
