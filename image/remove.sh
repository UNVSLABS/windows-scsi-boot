#!/usr/bin/env bash
# Delete a golden image from the storage server (docs/golden-image.md), from the PC in WSL or Git Bash:
#   image/remove.sh <version>
# Refused while any disk is on it, a client's (clients/update-clients.sh moves them to another image) or a test's, or
# while the build VM runs it. So it also drops a build or change that isn't finished, once the build VM is off.
# Nothing else deletes golden images: clients/update-clients.sh lists those that no disk uses any more, and an older
# one is what clients roll back to. Safe to re-run.
set -euo pipefail

VERSION=${1:-}
[[ $VERSION =~ ^[0-9]+$ ]] || { sed -n '3p' "$0" >&2; exit 1; }
cd "$(dirname "$0")/.."
# shellcheck source=servers/remote.sh
. servers/remote.sh
TAG=golden-v$VERSION
run "admin@$SAN" image/san/remove-image.ps1 "$VERSION"
