# Morpheus bounty PoC: DepositPool reward settlement is not time-weighted (CAP-H1)

The Distributor releases a reward tranche at most once per
`minRewardsDistributePeriod` (1 day). When a DepositPool settles, the
tranche is split pro-rata by the stakers' CURRENT `virtualDeposited`,
with no weighting for how long each stake was in the pool during the
window the tranche accrued over. A stake placed seconds before the
distribution gate opens therefore captures a full pro-rata share of the
whole window's emissions, and a stake placed after the tranche lands
captures none of it. The extra share is paid by the window's honest
stakers, out of the same fixed tranche.

## Run

```bash
forge test
```

Ethereum mainnet fork pinned at block 26,314,439. The fork URL is set in
the test (`https://eth.drpc.org`, which serves archive state at that
block); any archive-capable Ethereum RPC endpoint can replace it.

Expected: 1 passed, 0 failed.

- `test_SettlementSniping`: two fresh stakers each deposit 1,000 stETH
  (funded through Lido's public `submit()`, multiplier 1.0x). The honest
  staker enters at the fork timestamp, inside the closed distribution
  window (about 16.6 hours before the gate). The sniper enters 61
  seconds before the gate opens. After a permissionless
  `distributeRewards(0)` call at gate + 1 second lands the real
  2,682.679 MOR tranche, both stakers' rewards are exactly equal
  (208.773720 MOR each): the sniper was present for 62 of the window's
  86,401 seconds and captures about 1,394x their time-weighted fair
  share of 0.1498 MOR. A third staker entering after the tranche lands
  earns exactly 0, which pins the window edge to the distribution
  event, not to time in the pool.

Scaffolding disclosure: the test warps time to the distribution gate
and pins the Distributor's Chainlink price reads to their fork-block
values (after a warp the feeds are stale and the price consumer
returns 0). No protocol logic is mocked, no position is impersonated,
and no owner, admin, or multisig account is used anywhere.
