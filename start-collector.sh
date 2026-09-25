#!/bin/sh
set -e
cd "$(dirname "$0")"
if ! command -v node >/dev/null 2>&1; then
  echo "Install Node.js LTS, then re-run."
  exit 1
fi
if [ ! -f ./collector.config.json ]; then
  echo "Missing collector.config.json — download it from SuperCloud → Sites."
  exit 1
fi
exec node ./bastion-collector.mjs "$@"
