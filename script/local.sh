#!/usr/bin/env bash
# Local mainnet-fork environment: anvil fork at the pinned block, GrowingShape deployed, launched and
# unpaused. Uses anvil's account 0 unlocked (no key is read or written). Pair with
# `node keeper/dev-vrf.mjs` to fulfil VRF locally, since Chainlink does not serve a fork.
set -euo pipefail
cd "$(dirname "$0")/.."

FORK_RPC=${MAINNET_RPC_URL:-https://mainnet.gateway.tenderly.co}
FORK_BLOCK=${FORK_BLOCK:-26305681}
PORT=${PORT:-8545}
RPC=http://127.0.0.1:$PORT
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 # anvil account 0
FWA_TOKEN=0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845
FWA_HOLDER=0x000000000000000000000000000000000000dEaD # holds burned FWA; impersonated on the fork only

if ! cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "starting anvil fork at block $FORK_BLOCK on $RPC (log: anvil.log)"
  nohup anvil --fork-url "$FORK_RPC" --fork-block-number "$FORK_BLOCK" --port "$PORT" \
    --chain-id 31337 --auto-impersonate --block-time "${BLOCK_TIME:-2}" >anvil.log 2>&1 &
  for _ in $(seq 1 60); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
fi

[ "$(cast chain-id --rpc-url "$RPC")" = 31337 ] || { echo "RPC $RPC is not a chain-31337 local fork"; exit 1; }
export GS_OWNER=$DEPLOYER GS_RESIDUAL_RECIPIENT=$DEPLOYER
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --unlocked --sender "$DEPLOYER" --broadcast --slow -q
GAME=$(jq -r .growingShape deployments/31337.json)
export GS_GAME=$GAME

FEE=$(cast call 0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c "poolCreationFee()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
cast rpc anvil_setBalance "$FWA_HOLDER" 0x8AC7230489E80000 --rpc-url "$RPC" >/dev/null
cast send --unlocked --from "$FWA_HOLDER" "$FWA_TOKEN" "transfer(address,uint256)" "$GAME" "$FEE" --rpc-url "$RPC" >/dev/null

forge script script/Deploy.s.sol:Launch --rpc-url "$RPC" --unlocked --sender "$DEPLOYER" --broadcast --slow -q
forge script script/Deploy.s.sol:Postflight --rpc-url "$RPC" 2>&1 | grep -E "postflight|pool|wei|Error|revert" || true
cast send --unlocked --from "$DEPLOYER" "$GAME" "setPaused(bool)" false --rpc-url "$RPC" >/dev/null
echo "GrowingShape $GAME"
echo "pool $(cast call "$GAME" "pool()(address)" --rpc-url "$RPC")"
