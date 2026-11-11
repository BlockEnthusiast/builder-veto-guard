# Builder veto guard: Safe transactions Titan cannot build

This repo holds `BuilderVetoGuard`, a Safe transaction guard. A transaction guard
is a contract the Safe calls before every owner-signed `execTransaction`; if the guard reverts,
the whole transaction reverts. This guard reverts whenever the block it lands in was built by a
vetoed builder. The default veto list holds Titan Builder.

Status (2026-11-11): unit-tested on Safe 1.3.0, 1.4.1 and 1.5.0, fork-proven on the ETH Ops
Safe. **Not deployed, not installed on any Safe.**

## Why

On 2026-11-10 Phylax Systems and Titan Builder launched "circuit breakers" on Ethereum mainnet.
An app registers rules (Phylax calls them assertions) and Titan drops any transaction that breaks
them while it builds a block. An app can also make Titan mandatory: a guarded contract refuses
to run unless a Phylax builder marked the current block in an on-chain registry. This guard is the
mirror image for our Safes: a Safe transaction refuses to run in a block Titan built.

## What Phylax and Titan look like on chain

Measured 2026-11-11 against mainnet head 26,389,4xx.

| Item | Value | How we know |
| --- | --- | --- |
| Titan fee recipient (`block.coinbase`) | `0x4838B106FCe9647Bdf1E7877BF73cE8B0BAD5f97` (titanbuilder.eth) | Titan docs; 136 of 136 Titan-tagged blocks in a 300-block scan |
| Titan share of blocks | 136 of 300 (45%) | same scan (extraData `Titan (titanbuilder.xyz)`) |
| Live Credible Registry | `0xbac71fe7a8c78f49eeb2d33b250988224796af70` | `CredibleBlockMarked` logs since block 26,358,669; verified source |
| Previous registry | `0x5924b2eadd9e9419246d651039d48d32b4434672` | 28 marks, last at block 26,349,396 |
| Registry named in `phylax-rpc` | `0xF33F66b57dCD96b2729A50D95D6C2Ac2c8b2958c` | never marked (`lastCredibleBlock() == 0`), creation tx only |
| Marker sender | EOA `0x0a03d5b6bab06f3dceac6b313e23117eadc1d17f` | sender of all 20 recent marker txs |
| Marker call | `markCurrentBlockCredible(uint256 expectedBlockTimestamp)` (`0xdc01653c`) | verified source |
| Marked blocks | Titan only (20 of 20 recent) | coinbase of each marked block |
| Marker frequency | 22 marks in ~27,000 blocks | log count; Titan marks only blocks that carry a guarded call |

Registry rules that matter here (verified source of `0xbac7…af70`):

- `lastCredibleBlock()` returns the latest marked block number. Only the latest is stored.
- Only `CREDIBLE_BUILDER_ROLE` holders can mark, and the timestamp argument must equal
  `block.timestamp`, so a marker only counts in the block it was built for.
- Adding or removing a builder goes through a 3-day timelock. Nobody can grant the role instantly.
- `isCredibleBlock()` also returns true when `tx.gasprice == 0` (wallet simulation bypass).

Sources: [Phylax Credible Layer contracts](https://docs.phylax.systems/credible/credible-layer-contracts),
[Phylax Ethereum architecture](https://docs.phylax.systems/credible/architecture-overview),
[Titan docs](https://docs.titanbuilder.xyz/),
[Bankless launch report](https://www.bankless.com/read/news/phylax-and-titan-bring-circuit-breakers-to-ethereum),
[phylax-rpc `connection.ts`](https://github.com/phylaxsystems/phylax-rpc/blob/main/src/connection.ts).

## How the guard decides

`checkTransaction` runs before every owner-signed Safe transaction. On Safe 1.5.0,
`checkModuleTransaction` runs before every module transaction once the guard is also set with
`setModuleGuard`.

1. **Simulation pass.** If `tx.gasprice == 0`, allow. `eth_call` and `eth_estimateGas` run at gas
   price 0 unless the caller sets one, and they see the latest block's fee recipient. Without
   this, every wallet and Safe UI simulation would fail while the latest block is Titan's. Every
   mined mainnet transaction pays a base fee above zero, so this never applies on chain.
2. **Fee-recipient veto.** If `block.coinbase` is on the veto list, revert `VetoedBuilder(coinbase)`.
   This applies to every transaction, guard maintenance included.
3. **Maintenance pass.** A plain call to the guard itself, or `setGuard` / `setModuleGuard` on the
   Safe, skips step 4. A registry that marked every block therefore cannot lock the Safe.
4. **Phylax marker veto.** For each watched registry (at most 4), read `lastCredibleBlock()` with a
   30,000-gas cap. If it equals `block.number`, revert `VetoedCredibleBlock(registry, block)`.
   A failed, short, long or out-of-gas read counts as "not marked".

A guard revert reverts the whole `execTransaction`. The Safe nonce stays unused, so the same
signed transaction can be executed again and land in a later block from another builder.

Configuration lives in the guard and only the Safe can change it, through a Safe transaction:

- `setCoinbaseVeto(address coinbase, bool vetoed)`
- `setRegistryWatch(address registry, bool watched)`, needed when Phylax moves its registry again

Views: `vetoedCoinbases()`, `watchedRegistries()`, `isVetoedCoinbase(a)`, `isWatchedRegistry(a)`.

## Evidence

Unit tests: `./setup.sh && forge test` builds real Safe 1.3.0, 1.4.1 and
1.5.0 from source. 12 of 12 pass: interface ids match each Safe's own `type(...).interfaceId`,
Titan block reverts with the nonce unused, any other fee recipient passes (fuzzed), marked block
reverts, broken registries fail open, zero-price simulation passes, removal works in a marked block
but not in a Titan block, the maintenance pass is narrow (no delegatecall, no other self-call),
the 1.5.0 module guard, and configuration access.

Fork proof: `scripts/builder_veto_fork.py` in the Live_Sim_Mix dashboard repo (ape-managed anvil fork) against the ETH Ops Safe
`0x9e2b6378ee8ad2A4A95Fe481d63CAba8FB0EBBF9` (Safe 1.3.0, 7 owners, threshold 3) at fork block
26,389,538, with the live registry and Titan's real marker EOA. Output in
`fork_proof.json`. All 8 checks pass:

| Check | Result |
| --- | --- |
| install via owner-approved `setGuard` | guard slot set, 79,016 gas |
| Titan fee recipient | reverts `VetoedBuilder`, nonce 3235 unused |
| `eth_call` at 1 gwei under Titan | reverts `VetoedBuilder` |
| `eth_call` at gas price 0 under Titan | passes |
| same signatures, other fee recipient | lands, nonce 3235 → 3236 |
| marker ahead of the Safe tx, same block | reverts `VetoedCredibleBlock`, nonce unused |
| marker after the Safe tx, same block | lands (known limit, see below) |
| `setGuard(0)` in a marked block | lands, guard removed |
| `setGuard(0)` in a Titan block | reverts `VetoedBuilder`, guard stays |

Gas: a guarded no-op Safe transaction costs 78,204 against 59,705 unguarded, so the guard adds
about 18,500 gas per transaction with one watched registry.

## Limits

- **Titan can still include the transaction.** The guard makes it revert there, so the Safe
  action does not happen, but the executor still pays gas for the failed attempt. Send executions
  through a private route that excludes Titan (for example a builder-selected private RPC), not
  the public mempool. The guard is the hard rule; routing avoids paying for reverts.
- **Fee-recipient spoofing.** Titan could set another address as `block.coinbase` and pay the
  proposer some other way. It has not done so in any block we scanned. The marker signal catches a
  spoofed block only when Titan marked it ahead of our transaction. An allow list (only known
  non-Titan builders) would close this gap and is a possible later mode.
- **Marker after our transaction.** Titan marks only blocks that carry a guarded call, and the
  marker only has to precede those calls. A Safe transaction placed ahead of the marker passes the
  marker check. The fee-recipient check still catches it in any block Titan built under its own
  address.
- **Modules.** Safe 1.3.0 and 1.4.1 have no module guard, so module transactions (Zodiac Roles,
  bots) skip this guard on those Safes. Safe 1.5.0 covers them through `setModuleGuard`.
- **Batches.** The maintenance pass covers only a plain `setGuard` / `setModuleGuard` call. A
  MultiSend batch that contains one is checked like any other transaction.
- **Mainnet only.** The simulation pass assumes no zero-price transaction can be mined. Do not
  install this guard on a chain where one can.
- **Registry moves.** Phylax replaced its registry once in about 200,000 blocks. The fee-recipient
  veto keeps working; the marker veto needs `setRegistryWatch` for the new address.

## Installing (not done)

Step-by-step commands, checks and the Safe{Wallet} flow: [README](../README.md#deploy).

1. Deploy `BuilderVetoGuard(safe, [0x4838B106FCe9647Bdf1E7877BF73cE8B0BAD5f97], [0xbac71fe7a8c78f49eeb2d33b250988224796af70])`.
   One deployment per Safe.
2. Safe transaction: `safe.setGuard(guard)`. On Safe 1.5.0 also `safe.setModuleGuard(guard)` to
   cover modules.
3. Removal: `safe.setGuard(address(0))`, executed in any block Titan did not build.

## Files

- `src/BuilderVetoGuard.sol`: the guard
- `test/BuilderVetoGuard.t.sol`: unit tests on Safe 1.3.0 / 1.4.1 / 1.5.0
- `setup.sh`: fetches pinned forge-std and Safe sources into `lib/`
- `fork_proof.json`: last fork proof output (script lives in the Live_Sim_Mix dashboard repo)
