# PoC: Donated "yield" steals MOR share — DistributorV2 (Morpheus CAPITAL)

**Verdict: PASS — the finding reproduces on a mainnet fork. A $400 donation
buys ~1,494 MOR (~$1,072) of extra rewards; net profit ≈ +$672/day,
repeatable daily.**

## Result (one command: `forge test`)

```
Ran 2 tests for test/DonatedYield.t.sol:DonatedYieldTest
[PASS] testDistributeRevertsAfterWarpWithoutMock()
[PASS] testDonatedYield()
Suite result: ok. 2 passed; 0 failed; 0 skipped
```

Fork: Ethereum mainnet block **26427095** (ts 1794826127, 2026-11-16),
RPC **https://ethereum.publicnode.com** (default; override with `ETH_RPC_URL`).
MOR price **$0.717123** (CoinGecko `morpheusai`, 2026-11-16).

## Measured numbers (identical setup, two forks at the same block)

| | Attack (donate) | Honest control | Delta |
|---|---|---|---|
| aUSDT donated to Distributor | 399,999,998 raw (~$400.00) | 0 | — |
| MOR credited to USDT pool, attack-day distribute | 2,560.18 MOR | 791.55 MOR | **+1,768.63 MOR** |
| Attacker pending MOR at claim (after 14d locks) | 2,162.96 MOR | 668.74 MOR | **+1,494.22 MOR** |
| Delta value @ $0.717123 | — | — | **$1,071.54** |
| **Net profit per day** | — | — | **+$671.54** |
| `claim()` on fork | ok | ok | — |

Attacker: ordinary address, staked **200,000 USDT** in the USDT DepositPool
(`0x3B51989212BEdaB926794D6bf8e9E991218cf116`), 1x multiplier, no referrer,
**84.48% virtual share** of the pool. `distributeRewards(0)` was called by
the attacker (public function, no privileges). The donation was made the
honest way: supply 400 USDT to Aave V3, transfer the minted aUSDT to the
Distributor (`0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A`).

## What the numbers mean

- The donation is counted as USDT-pool "yield" exactly as predicted:
  the pool's share of the ~1-day emission (~2,856 MOR) jumps from
  791.55 MOR to 2,560.18 MOR. The attacker keeps 84.48% of the inflated
  credit (1,494.22 of 1,768.63 MOR); the other ~15.5% leaks to the
  pre-existing USDT stakers.
- The control's 791.55 MOR is **not** free money: it is the USDT pool's
  legitimate share of that day's emission, driven mostly by the Aave
  interest on the attacker's own $200k stake (~$20/day) plus the
  pre-existing $4,739 TVL. Both runs have it; the delta isolates the
  donation. The attacker's $200k stake is returned on withdraw — only
  the $400 donation is lost.
- The measured net (+$672/day) is at the **high end** of the plausible
  range, because of a timing quirk: Lido stETH only accrues yield when
  the oracle reports (daily step), and **no rebase fell inside this
  fork's 24h attack window**, so stETH's counted yield that day was ~$0
  and the USDT pool's share was inflated. On a day where a rebase does
  fall in the window, total daily yield is ~$600 (stETH ~$531), the
  USDT attack share is ~42% instead of ~90%, and the estimated net is
  **~$270/day** — still clearly profitable. Either way the finding
  reproduces; the exact daily profit depends on rebase timing.
- Donation sizing: $400 is near-optimal for the measured window
  (predicted optimum was ~$504/day at the audit's assumed yields).

## On-chain state confirmed in-test (not assumed)

- `RewardPool.rewardPools(0)`: payoutStart 1707393600, decreaseInterval
  86400, initialReward 3,456 MOR/day, rewardDecrease 0.59255872824
  MOR/day, public. Current emission ≈ 2,856 MOR/day.
- `minRewardsDistributePeriod` = 86400 (1 day).
- Pool 0 has 5 deposit pools: stETH, wBTC, WETH, USDC, USDT.
- USDT pool: `minimalStake` = 1,000,000 raw = **$1** — the audit's worry
  that `_step5`'s `1e16` raw minimalStake made USDT unstakeable is
  **resolved: it was fixed on-chain**. TVL $4,739, pre-existing virtual
  36,729,288,039 (existing stakers carry ~7.75x lock multipliers).
- **Claim locks are 14 days, not 90**: `claimLockPeriodAfterStake` =
  `claimLockPeriodAfterClaim` = 1,209,600; withdraw lock 604,800 (7d).
  The PoC warps 14d+1s past the stake (not 90d) — see deviations.
- Prices at fork: stETH $1,801.12, wETH $1,808.49,
  wBTC $64,330.86, USDC $0.99972, USDT $0.99933.

## Deviations from the task plan (all forced by on-chain facts)

1. **Mock Chainlink consumer (required).** On live mainnet the feeds
   update every few minutes, so a distribute 1 day later sees fresh
   prices. On a fork the aggregator state is frozen at the fork block,
   and the 3600s `allowedPriceUpdateDelay` on the stETH/ETH/BTC feeds
   makes *any* distribute after a >1h warp revert
   (`"DR: price for pair is zero"`). This is proven by
   `testDistributeRevertsAfterWarpWithoutMock`, which passes on the
   pure fork. The PoC therefore swaps the Distributor's
   `chainLinkDataConsumer` pointer (storage slot 207, found empirically
   with a `vm.load` scan) for a mock returning the **exact prices read
   from the real consumer at the fork block**. No price is invented;
   the mock only keeps frozen prices "fresh", exactly as live feeds
   would. All yield accounting, staking, Aave and reward contracts are
   the real forked ones.
2. **Claim warp is 14 days, not 90+ days.** On-chain claim locks are
   1,209,600s (14d), not the 7,776,000s (90d) in the deploy script.
   Warping 15 days total (1d + 14d) satisfies every lock.
3. **Claim fee is a flat 0.05 ETH**, not the LayerZero `estimateFees`
   quote (~0.00063 ETH), which underquotes on the fork and makes
   `claim()` revert. With 0.05 ETH the real `claim()` succeeds on the
   fork (LayerZero message recorded by the forked endpoint).
4. **Approvals go to the Distributor, not the DepositPool:**
   `Distributor.supply()` pulls tokens directly from the user
   (`safeTransferFrom(holder_=user, ...)`), so the staker approves the
   Distributor. (Also: USDT `approve` returns nothing, so the PoC uses
   a no-return interface — calling it via standard `IERC20` reverts on
   empty returndata.)

## Files

- `test/DonatedYield.t.sol` — the PoC (2 tests; `forge-std` only, no
  repo dependencies). Interfaces are minimal and hand-written.
- `foundry.toml` — solc 0.8.20, `via_ir = true` (stack-too-deep
  otherwise), `evm_version = "osaka"` (see note below).
- `lib/forge-std/` — forge-std from the master tarball (no git clone).

## Reproduce

```bash
cd ~/workspace/bounty-hunt/poc-donated-yield
forge test            # uses https://ethereum.publicnode.com by default
# or: ETH_RPC_URL=<your mainnet rpc> forge test
```

Verified from a fully clean state (`forge clean`, empty Foundry RPC
cache, no `ETH_RPC_URL`): 2 passed, 0 failed in ~35s. Requires
network access to a mainnet RPC. No mainnet transactions are sent, no
real funds move, no privileged accounts are used.

## Incidental observations (not part of the finding)

- During development, fresh-fork runs once hit a deterministic
  `NotActivated` revert inside `AavePool.withdraw` (called by
  `Distributor._withdrawYield` during `supply()`). It stopped recurring
  after the `foundry.toml` change + recompile and has not recurred in
  any later run, including the cold-cache verification. Suspected cause
  is a stale/empty cached implementation-code entry for the Aave Pool
  (or EVM-spec handling of newer opcodes in that implementation);
  `forge config` reports `evm_version = "shanghai"` despite
  `evm_version = "osaka"` in `foundry.toml`, so the setting appears to
  be normalized by this Foundry version (1.9.0) and is not the fix.
  If it recurs, clearing `~/.foundry/cache/rpc` and re-running should
  resolve it.
- The pure-fork stale-feed revert (`testDistributeRevertsAfterWarpWithoutMock`)
  is an independent confirmation of the audit's Finding 3 mechanism
  (one stale feed reverts the whole distribute): it fires here with
  frozen fork feeds, on the real consumer, with no mocking.
