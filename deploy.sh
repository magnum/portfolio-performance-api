#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

set -a && source .env && set +a
bundle exec kamal deploy
