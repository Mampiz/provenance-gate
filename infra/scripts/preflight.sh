#!/usr/bin/env bash
# Checks the host limits that kind needs before a cluster is created.
#
# This exists because the failure it prevents is unreadable. When the host runs
# out of inotify instances, systemd inside the kind node cannot allocate its
# cgroup watcher and exits as PID 1, and all kind reports is:
#
#   could not find a log line that matches "Reached target .*Multi-User System.*"
#
# which says nothing about inotify. The real message is only in
# "docker logs <node>": "Failed to create control group inotify object: Too many
# open files". Every running cluster holds instances, so a limit that was fine
# for one cluster fails on the third.
set -euo pipefail

# kind's own documented minimum. Each node needs a handful and each container
# runtime component holds more, so the headroom is deliberate.
MIN_INSTANCES=512
MIN_WATCHES=524288

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2; }

instances="$(sysctl -n fs.inotify.max_user_instances)"
watches="$(sysctl -n fs.inotify.max_user_watches)"
problem=0

if [ "${instances}" -lt "${MIN_INSTANCES}" ]; then
  fail "fs.inotify.max_user_instances is ${instances}, kind needs at least ${MIN_INSTANCES}"
  problem=1
else
  pass "fs.inotify.max_user_instances = ${instances}"
fi

if [ "${watches}" -lt "${MIN_WATCHES}" ]; then
  fail "fs.inotify.max_user_watches is ${watches}, kind needs at least ${MIN_WATCHES}"
  problem=1
else
  pass "fs.inotify.max_user_watches = ${watches}"
fi

if ! docker info >/dev/null 2>&1; then
  fail "the Docker daemon is not reachable"
  problem=1
else
  pass "Docker daemon is reachable"
fi

if [ "${problem}" -ne 0 ]; then
  cat >&2 <<'REMEDY'

  The inotify limits are a host setting and need root once. To raise them
  permanently:

    echo -e 'fs.inotify.max_user_instances=8192\nfs.inotify.max_user_watches=524288' \
      | sudo tee /etc/sysctl.d/99-kind.conf
    sudo sysctl --system

REMEDY
  exit 1
fi
