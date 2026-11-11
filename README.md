# builder-veto-guard

Safe transaction guard (Safe 1.3.0 / 1.4.1 / 1.5.0, plus the 1.5.0 module guard) that makes a
Safe's transactions revert in any block built by a vetoed builder. Default veto: Titan Builder,
by fee recipient `0x4838B106FCe9647Bdf1E7877BF73cE8B0BAD5f97` and by the Phylax Credible Registry
marker.

Design, on-chain findings, test evidence and limits: [docs/design.md](docs/design.md).

## Build and test

```sh
./setup.sh      # pinned forge-std + Safe 1.3.0 / 1.4.1 / 1.5.0 sources into lib/
forge test
```

Fork proof on a real Safe: `fork_proof.json`, produced by `scripts/builder_veto_fork.py` in the
Live_Sim_Mix dashboard repo.

## Deploy

Deploy one guard per Safe. The constructor fixes which Safe the guard serves, and only that Safe
can edit the guard's lists. The deployer gets no rights over the guard.

**1. Check the Safe.**

```sh
export ETH_RPC_URL=<mainnet rpc url>
SAFE=<your Safe address>

cast call $SAFE "VERSION()(string)"
cast storage $SAFE 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8
```

The version must be 1.3.0, 1.4.1 or 1.5.0. The storage slot holds the Safe's current guard. It
reads all zeros when there is none. A Safe has one guard, so installing this one replaces any
existing guard.

**2. Check that the Phylax registry is still live.**

```sh
cast call 0xbac71fe7a8c78f49eeb2d33b250988224796af70 "lastCredibleBlock()(uint256)"
cast block-number
```

The first number is the last block Titan marked. It should be fairly recent: on 2026-11-11 it
read 26,385,833 with the head at 26,389,602. If it stops moving for weeks, Phylax may have moved
the registry. [docs/design.md](docs/design.md) explains how to find the new one from its
`CredibleBlockMarked` events. Use the new address in step 3.

**3. Deploy.**

```sh
forge create src/BuilderVetoGuard.sol:BuilderVetoGuard \
  --rpc-url $ETH_RPC_URL \
  --ledger \
  --broadcast \
  --verify --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $SAFE \
    "[0x4838B106FCe9647Bdf1E7877BF73cE8B0BAD5f97]" \
    "[0xbac71fe7a8c78f49eeb2d33b250988224796af70]"
```

- `--ledger` signs with a Ledger. Use `--account <name>` for a `cast wallet` keystore instead.
- `--broadcast` sends the transaction. Without it, forge only simulates.
- `--constructor-args` must stay last. Its three values are the Safe, the vetoed fee recipients,
  and the watched registries.
- `--verify` publishes the source on Etherscan. Drop it and the key if you verify later.

Forge prints `Deployed to: <address>`. That address is the guard.

**4. Check the deployed guard.**

```sh
GUARD=<the "Deployed to" address>

cast call $GUARD "SAFE()(address)"                  # must be your Safe
cast call $GUARD "vetoedCoinbases()(address[])"     # [0x4838…5f97]
cast call $GUARD "watchedRegistries()(address[])"   # [0xbac7…af70]
```

## Add it to the Safe

Installing takes one Safe transaction from the Safe to itself: `setGuard(GUARD)`. It needs the
usual owner signatures.

**Safe{Wallet}:**

1. Open **Apps**, then **Transaction Builder**.
2. Enter your Safe's own address as the contract address. If no ABI loads, paste this one:

   ```json
   [{"inputs":[{"name":"guard","type":"address"}],"name":"setGuard","outputs":[],"stateMutability":"nonpayable","type":"function"}]
   ```

3. Pick `setGuard`, enter the guard address, and leave the value at 0.
4. Add the transaction, create the batch, sign, collect the other signatures, and execute.

**Any other tool** (Safe CLI, a script that proposes to the Safe queue): send to `$SAFE`, value 0,
operation CALL, with this data:

```sh
cast calldata "setGuard(address)" $GUARD
```

**Safe 1.5.0 only:** send `setModuleGuard(GUARD)` the same way, so module transactions are guarded
too. Safe 1.3.0 and 1.4.1 have no module guard, so their modules skip this guard.

```sh
cast calldata "setModuleGuard(address)" $GUARD
```

**Confirm:**

```sh
cast storage $SAFE 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8
```

The slot should now end with the guard address.

## After installing

- Every owner-signed Safe transaction reverts in a block Titan built. The Safe nonce stays unused,
  so you can execute the same signed transaction again. It lands once another builder builds the
  block.
- The executor pays gas for every failed attempt. Send executions through a private RPC that
  excludes Titan, and keep them out of the public mempool.
- Simulations at gas price 0 still pass. That is the default for `eth_call` and gas estimation. A
  simulation that sets a gas price fails while the latest block is Titan's.

## Change the lists

Send a Safe transaction to the guard address (not the Safe) with one of these:

```sh
cast calldata "setCoinbaseVeto(address,bool)" <fee recipient> true    # false to remove
cast calldata "setRegistryWatch(address,bool)" <registry> true        # false to remove
```

The guard watches at most 4 registries. Calls to the guard skip the registry check, so you can
drop a misbehaving registry even while it marks every block.

## Remove

Send a Safe transaction to the Safe with:

```sh
cast calldata "setGuard(address)" 0x0000000000000000000000000000000000000000
```

On Safe 1.5.0, also clear the module guard with `setModuleGuard(0x0000000000000000000000000000000000000000)`.

Send the removal as one plain call to the Safe. A removal inside a MultiSend batch gets no
exemption from the registry check. Check that the review screen shows the Safe itself as the
target and not MultiSendCallOnly. The removal still reverts in a Titan block, like every other
transaction.
