# builder-veto-guard

Safe transaction guard (Safe 1.3.0 / 1.4.1 / 1.5.0, plus the 1.5.0 module guard) that makes a
Safe's transactions revert in any block built by a vetoed builder. Default veto: Titan Builder,
by fee recipient `0x4838B106FCe9647Bdf1E7877BF73cE8B0BAD5f97` and by the Phylax Credible Registry
marker.

```
./setup.sh      # pinned forge-std + Safe 1.3.0 / 1.4.1 / 1.5.0 sources into lib/
forge test
```

Fork proof on a real Safe: `fork_proof.json`, produced by `scripts/builder_veto_fork.py` in the Live_Sim_Mix dashboard repo.

Design, on-chain findings, test evidence and limits: [docs/design.md](docs/design.md).
