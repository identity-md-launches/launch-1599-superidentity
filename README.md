# SuperIdentity (SUPER)

A fixed-supply ERC-20 token for launch on Robinhood Chain (chain id 4663) through the IdentityMD
ProjectFactory, paired with IMD.

| | |
|---|---|
| Solidity contract | `SuperIdentityToken` (`src/SuperIdentityToken.sol`) |
| Token name | `SuperIdentity` |
| Symbol | `SUPER` |
| Decimals | 18 |
| Total supply | 1,000,000,000 SUPER = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Minting | once, the whole supply, to `msg.sender` (the deployer) in the constructor |
| Owner / admin | none |

## What the token does

- Plain EIP-20: `transfer`, `approve`, `transferFrom`, `balanceOf`, `allowance`, `totalSupply`,
  `name`, `symbol`, `decimals`. Every transfer moves exactly the amount requested; there is no fee,
  burn, reflection or tax on any transfer.
- EIP-2612 `permit`, so a holder can grant an allowance by signature (`DOMAIN_SEPARATOR`, `nonces`).
  The domain separator is cached at construction and recomputed if the chain id ever changes.
- An allowance of `type(uint256).max` is treated as infinite and is not decremented.
- Transfers and approvals to or from the zero address revert.
- The contract does not accept ether.

## What the token deliberately does not do

- No owner, no roles. After construction there is no privileged function of any kind.
- No `mint`, `issue` or minter role: the supply can never grow after launch.
- No `burn`: the supply does not shrink either. `totalSupply()` is a compile-time constant.
- No pause, blacklist, freeze, lock, seize or `burnFrom`: nobody but a holder, or a spender the
  holder approved, can move a holder's balance.
- No proxy, no upgrade path, no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in the bytecode.
- No external calls in the constructor, so it deploys on an empty chain.
- No linked libraries: the bytecode is complete as built.

## Assumptions

- The deployer is whoever runs the constructor. On the IdentityMD launch that is the ProjectFactory,
  which receives the whole supply and pays it out: 10% to the launch's MerkleDistributor, 80% to
  seed the Uniswap v4 pool against IMD, and the remaining 10% to the requester's
  `economics.remainderTo` address. Because the token has no transfer fee, no exemption list is
  needed for the factory, the PoolManager or the distributor: every flow arrives whole.
- The launch manifest is written by the manifest step, not here. The values it will carry for this
  token are: contract `SuperIdentityToken`, name `SuperIdentity`, symbol `SUPER`, decimals `18`,
  `constructorArgs` `[]`, `totalSupply` `1000000000000000000000000000`.
- The contract name is 18 characters, within the 32-byte limit the factory records.
- `bytecode_hash = "none"` and `cbor_metadata = false` are set in `foundry.toml`, so the built
  bytecode carries no metadata hash and is reproducible from source with solc 0.8.26.
- The permit's EIP-712 domain uses name `SuperIdentity` and version `1`.

## Deployment parameters

The token has no constructor arguments and nothing to configure after launch. The only deployment
choice is who deploys, because the deployer receives the whole supply.

- **IdentityMD launch (the intended path).** The factory deploys the attested bytecode via CREATE2
  and holds the supply. Nothing in this repository deploys, broadcasts or signs anything.
- **Local or test deployment.** `script/Deploy.s.sol` exposes `deploy()`, which constructs the
  token from the caller, and `run()`, which broadcasts it from the signer `forge script` is given.
  Tests call `deploy()` directly; `run()` reads no environment variables itself.

Compiler pins in `foundry.toml`: `solc = "0.8.26"`, `evm_version = "cancun"`, optimizer on with
200 runs, `bytecode_hash = "none"`, `ffi = false`, no filesystem permissions.

## Operational responsibilities

- **Nobody can intervene.** There is no admin to pause, freeze, mint or recover tokens. Anything
  sent to a wrong address, including the token contract itself, is unrecoverable. This is by design
  and should be communicated to holders.
- **The factory's payout is the whole distribution.** Once the factory has paid out the supply, the
  requester's share sits at `economics.remainderTo`; securing that wallet is the requester's job.
- **Pool and distributor are launch infrastructure.** This repository contains only the token. The
  pool fee (1.25%), tick spacing (60), opening market cap and pairing with IMD are fixed by the
  launch and the requester's economics, not by the token.
- **Monitoring.** Watch `Transfer` and `Approval` events as with any ERC-20. There are no other
  events.
- **Explorer verification** of the deployed bytecode against this source is the launch deployer's
  step, not this repository's.

## Repository layout

```
foundry.toml                   compiler pins and build settings
remappings.txt                 forge-std/ -> lib/forge-std/src/
src/SuperIdentityToken.sol     the token
script/Deploy.s.sol            reference deploy script (deploy() is unit-tested)
test/SuperIdentityToken.t.sol  unit, failure-path and fuzz tests
lib/forge-std/                 forge-std 1.9.7, vendored as ordinary files (MIT/Apache-2.0)
```

## Building and testing

```
forge build
forge test
forge fmt --check
```

Tests read no environment variables and do not depend on the calling address, so they pass in any
order and in parallel.

## Security notes

- The contract was written against the eth-security checklist: reentrancy is not reachable (no
  external calls), there is no access control to get wrong, inputs are validated (zero addresses,
  balances, allowances, permit deadline and signature, including rejection of high-`s` malleable
  signatures), and no floating point or oracle is involved.
- Tests passing do not constitute an audit. A separate adversarial review by an independent
  contributor is still appropriate before release, as for any contract that will hold value.
- Static analysers (Slither, Mythril) were not available on the build machine and were not run.
