#!/usr/bin/env bash
# Thin wrapper that calls install.sh --uninstall.
# Exists so people who reach for `uninstall.sh` find it.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/install.sh" --uninstall "$@"
