# Morpheus BuildersV4 — Spoofed Subnet Admin PoC

Foundry proof-of-concept for a bug reported to the Morpheus bug bounty
program (devs@mor.org), subject
`[BOUNTY] BuildersV4 — Spoofed subnet admin lets an attacker claim a subnet's yield`.

## The finding

`BuildersV4.createSubnet()` (Base `0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9`)
never binds the `admin` / `claimAdmin` parameters to `msg.sender`.
`_validateSubnet` only checks that they are non-zero. An attacker can
create a subnet named after a legitimate builder, set `admin` to that
builder (who never consents or signs) and `claimAdmin` to themselves, then
claim the subnet's yield once victims deposit into it.

The PoC (`test/PocG1Builders.t.sol`,
`test_G1_SpoofedAdminClaimAdminStealsYield`) runs on a Base mainnet fork
pinned at block 56038769: an attacker creates subnet "RealBuilderPro"
with a spoofed admin, three victims deposit 100,000 MOR, and after 30 days
the attacker claims **2,246.07 MOR (~$1,775)** to themselves. The
legitimate builder receives 0. Victim principals are untouched.

Self-assessment: Medium (per the program's reward bands).

## Run it

```shell
forge test --match-test test_G1_SpoofedAdminClaimAdminStealsYield -vv
```

Full suite (all hunt tests, including the disproofs):

```shell
forge test
```

Invariant suites (separate profile, they need their own invocation):

```shell
FOUNDRY_PROFILE=invariant forge test --match-contract BuildersInvariantTest
FOUNDRY_PROFILE=invariant forge test --match-contract CapitalInvariantTest
```

Requirements: Foundry 1.8.6, solc 0.8.24 (both set in `foundry.toml`).
Fork RPCs are pinned in `foundry.toml`: Base `https://mainnet.base.org`,
Ethereum `https://eth.drpc.org`, Arbitrum `https://arb1.arbitrum.io/rpc`.

## Layout

- `test/PocG1Builders.t.sol` — the PoC for this report.
- `test/PocD1*.t.sol`, `test/PocD2Builders.t.sol`,
  `test/PocD3Lumerin.t.sol`, `test/PocD4Crosschain.t.sol`,
  `test/PocG1Lumerin.t.sol`, `test/PocG4aUnbound.t.sol`,
  `test/PocG4bSessionRouter.t.sol` — directed disproof tests from the same
  hunt (no finding in any of them).
- `test/invariant/` — property fuzzing: 11 BuildersV4 invariants and
  8 DepositPool/Distributor invariants, all holding.
- `lib/forge-std/` — vendored, so the repo builds from a clean clone with
  no extra install step.

## Scope note

`forge-std` is included verbatim under its own MIT/Apache-2.0 licenses.
Everything else in this repo was written for this report.
