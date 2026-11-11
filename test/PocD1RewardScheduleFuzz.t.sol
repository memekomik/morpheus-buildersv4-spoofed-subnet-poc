// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

interface IRewardPoolD1 {
    function getPeriodRewards(uint256 index_, uint128 startTime_, uint128 endTime_) external view returns (uint256);
}

/// @title Lane D1 — fuzz check on RewardPool.getPeriodRewards (LinearDistributionIntervalDecrease)
/// @notice The emission schedule is pure math with several branches
///         (_calculateFullPeriodReward subtracts a triangular decrease term).
///         A fuzz run over arbitrary (start, end) pairs checks it never
///         reverts (underflow) and never returns rewards for an empty period.
///         Fork: Ethereum 26391516 (RewardPool proxy is the deployed contract).
contract PocD1RewardScheduleFuzzTest is Test {
    address constant REWARD_POOL = 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87;

    function setUp() public {
        vm.createSelectFork("eth", 26391516);
    }

    function testFuzz_GetPeriodRewardsNeverReverts(uint128 start, uint128 end) public view {
        uint256 r = IRewardPoolD1(REWARD_POOL).getPeriodRewards(0, start, end);
        if (start >= end) {
            assertEq(r, 0, "empty/inverted period pays 0");
        }
        // Emission is bounded: <= initialReward (3456 MOR) per day of period.
        // (Very loose bound: period length in days + 2, times 3456 MOR.)
        uint256 numDays = (uint256(end) > uint256(start)) ? (uint256(end) - uint256(start)) / 86400 + 2 : 0;
        assertLe(r, numDays * 3456 ether, "emission bounded by daily rate");
    }

    function test_GetPeriodRewardsKnownValues() public view {
        IRewardPoolD1 rp = IRewardPoolD1(REWARD_POOL);
        // Values observed live via cast at block 26391516.
        assertEq(rp.getPeriodRewards(0, 1794180863, 1794270863), 2979971901973579547221, "25h window");
        assertEq(rp.getPeriodRewards(0, 1794180863, 1794180863), 0, "zero-length window");
        assertEq(rp.getPeriodRewards(0, 0, 1707393600), 0, "before payoutStart");
        // Final interval: maxIntervals = ceil(3456e18 / 592558728240000000) = 5833,
        // maxEndTime = 1707393600 + 5833*86400 = 2211364800. The last interval
        // pays exactly the residual initial - 5832*decrease = 197.49690432 MOR.
        assertEq(rp.getPeriodRewards(0, 2211278400, 2211364800), 197496904320000000, "final partial interval");
        assertEq(rp.getPeriodRewards(0, 2211364800, 2211451200), 0, "after max end time");
    }
}
