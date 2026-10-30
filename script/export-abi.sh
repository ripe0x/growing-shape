#!/usr/bin/env bash
# Writes the ABIs the keeper and web app import. Re-run after any interface change.
set -euo pipefail
cd "$(dirname "$0")/.."
for c in GrowingShape IFWAClone IFWAVRFService IShapes IShapePacks; do
  forge inspect "$c" abi --json >"abi/$c.json"
done
