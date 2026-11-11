#!/usr/bin/env bash
# Fetch the pinned test dependencies into lib/ (not committed).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p lib
clone() {  # dir tag url
  [ -d "lib/$1" ] || git -c advice.detachedHead=false clone -q --depth 1 --branch "$2" "$3" "lib/$1"
}
clone forge-std  v1.9.7 https://github.com/foundry-rs/forge-std.git
clone safe-1.3.0 v1.3.0 https://github.com/safe-global/safe-smart-account.git
clone safe-1.4.1 v1.4.1 https://github.com/safe-global/safe-smart-account.git
clone safe-1.5.0 v1.5.0 https://github.com/safe-global/safe-smart-account.git
