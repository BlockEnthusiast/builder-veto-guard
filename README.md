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
- The executor pays gas for every failed attempt. Send executions through a route that never
  reaches Titan, and keep them out of the public mempool. See the next section.
- Simulations at gas price 0 still pass. That is the default for `eth_call` and gas estimation. A
  simulation that sets a gas price fails while the latest block is Titan's.

## Send executions without Titan

The guard stops a Safe transaction from running in a Titan block. It cannot stop Titan from
including the attempt, and the executor pays gas for that revert. Titan includes reverting
transactions routinely: 118 of 13,329 transactions in 57 Titan blocks (2026-11-11). The way to
avoid that cost is to never let Titan see the transaction. Any wallet's default RPC sends to the
public mempool, which Titan reads.

**Routes that leave Titan out** (checked 2026-11-11 against each provider's docs):

| Route | Endpoint | Use it as | Reaches |
| --- | --- | --- | --- |
| Flashbots Protect, default | `https://rpc.flashbots.net` | wallet RPC (reads and sends) | Flashbots builder only |
| Flashbots Protect, chosen builders | `https://rpc.flashbots.net?builder=Quasar&builder=Bombora&builder=Eureka` | wallet RPC (reads and sends) | Flashbots builder plus each `builder=` named |
| Quasar, direct | `https://rpc.quasar.win` | send only (`cast publish`); it answers no reads | Quasar only |

- Flashbots Protect docs: by default "Transactions are only forwarded to the Flashbots block
  builder", they are retried for 25 blocks and then dropped, and "Reverted transactions are not
  included on chain."
- The `builder=` names come from Flashbots' builder registry
  ([builder-registrations.json](https://github.com/flashbots/dowg/blob/main/builder-registrations.json)).
  Titan is listed there as `Titan`. Never add it.
- Quasar docs: "All transactions sent to our builder are kept private." No API key needed.
- Each builder you add gets your transaction privately. You trust it to keep it private.

**Avoid:**

- `https://rpc.flashbots.net/fast`: "Transactions are shared with all registered builders", Titan
  included.
- MEV Blocker: no way to choose or exclude builders.
- bloXroute `blxr_private_tx` with `mev_builders` set to `all`. bloXroute can target named
  builders (leave out `titan`), but it needs a paid key. It also falls back to the public mempool
  after its `timeout` unless the timeout is 0.
- Titan's own RPC, and any public RPC (Infura, Alchemy, a node's default `eth_sendRawTransaction`).

**Speed.** In a 300-block sample (2026-11-11), Titan built 45% of blocks, Quasar 16%, BuilderNet
(the Flashbots builder) 12%, Bombora 11% and Eureka 6%. Protect's default reaches about 12% of
blocks, so a transaction can take a few minutes. It is dropped after 25 blocks if it hasn't landed.
The chosen-builders URL above reaches about 45% of blocks, so a transaction usually lands within a
few blocks.

**Safe{Wallet}:** the owner who presses **Execute** sends the transaction from their own wallet.
Add a custom network to that wallet (chain id 1) with one of the Protect URLs above as its RPC,
switch to it, then execute.

**Scripts:** sign the fully signed `execTransaction` call as a raw transaction, then publish it to
one or more routes. Sending the same signed transaction to several routes is safe. The first
inclusion uses the executor's nonce, and every other copy becomes invalid.

```sh
RAW=$(cast mktx $SAFE <execTransaction calldata> --ledger --rpc-url $ETH_RPC_URL)

cast publish --rpc-url "https://rpc.flashbots.net?builder=Quasar&builder=Bombora&builder=Eureka" $RAW
cast publish --rpc-url https://rpc.quasar.win $RAW
```

Providers change their sharing rules. Re-check these routes before relying on them. If a route
starts reaching Titan, the guard still keeps the Safe action from running there.

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
