#! /bin/bash -xe
# Create marker utxo

# fail if something goes wrong
set -e

chmod +x ./fuel-testnet.sh
exec ./fuel-testnet.sh devnet cardano-key.sk 10000000