#!/usr/bin/env bash
# Launch-and-play rehearsal with production parameters on its own anvil mainnet fork (default port 8547):
# Deploy -> Launch -> Postflight -> unpause, then the real keeper (profit-seeking), the dev VRF fulfiller
# and a player bot run until TARGET_CYCLES featured Shapes are won. Outputs in rehearsal/.
set -euo pipefail
cd "$(dirname "$0")/.."
PORT=${PORT:-8547}
RPC=http://127.0.0.1:$PORT
export GS_DEPLOYMENT_FILE=deployments/rehearsal-$PORT.json
mkdir -p rehearsal
PORT=$PORT BLOCK_TIME=${BLOCK_TIME:-1} ./script/local.sh | tee rehearsal/launch.log
GAME=$(jq -r .growingShape "$GS_DEPLOYMENT_FILE")
export RPC_URL=$RPC GAME FROM_BLOCK=$(jq -r .deployBlock "$GS_DEPLOYMENT_FILE")
node keeper/dev-vrf.mjs >rehearsal/vrf.log 2>&1 &
VRF=$!
KEEPER_UNLOCKED=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC INTERVAL_MS=${INTERVAL_MS:-4000} node keeper/keeper.mjs >rehearsal/keeper.log 2>&1 &
KEEPER=$!
trap 'kill $VRF $KEEPER 2>/dev/null || true' EXIT
TARGET_CYCLES=${TARGET_CYCLES:-3} MAX_DRAWS=${MAX_DRAWS:-12000} node keeper/players.mjs | tee rehearsal/players.log
sleep 40 # let the keeper book and replenish the tail
node keeper/report.mjs | tee rehearsal/report.json
echo "keeper txs: $(grep -c ': success' rehearsal/keeper.log || true)  failed: $(grep -c ': reverted' rehearsal/keeper.log || true)"
