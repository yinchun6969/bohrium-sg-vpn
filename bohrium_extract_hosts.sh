#!/usr/bin/env bash
set -Eeuo pipefail

# Extract unique Bohrium SSH/public hosts from copied web text, SSH commands,
# JSON, or a file containing any of those.

if [ "$#" -gt 0 ]; then
  cat "$@"
else
  cat
fi | grep -Eao '[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.bohrium\.tech' | awk '!seen[$0]++'
