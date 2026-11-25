#!/usr/bin/env bash
# Stop every setup's model server and sandboxes on this machine and free the GPU. Projects and sessions are kept.
exec "$(dirname "$(readlink -f "$0")")/start.sh" --stop "$@"
