// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

interface IPoolD1 {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function referrersData(
        address,
        uint256
    )
        external
        view
        returns (uint256 amountStaked, uint256 virtualAmountStaked, uint256 rate, uint256 pendingRewards, uint128 lastClaim);
    function getReferrerMultiplier(uint256, address) external view returns (uint256);
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function getLatestReferrerReward(uint256, address) external view returns (uint256);
    function rewardPoolsData(uint256) external view returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
}

interface IDistributorD1 {
    function distributeRewards(uint256 rewardPoolIndex_) external;
}

interface IERC20D1 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IAggregatorD1 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title Lane D1 control/disproof — referrer-tier multiplier scale
/// @notice Hypothesis tested (now DISPROVED): referrer tier multipliers are
///         configured on a 1e25 scale (live: 3e23/5e23/1e24/1.5e24) while
///         ReferrerLib.applyReferrerTier divides by PRECISION, supposedly 1e18,
///         which would give referrers 300,000x-1,500,000x virtual stake and let
///         any referrer capture ~all MOR emissions.
///
///         Disproof: Solarity's PRECISION is 1e25, not 1e18 (the lock
///         multiplier math in LockMultiplierMath returns 1e25-scale values and
///         the repo's own test tiers are `wei(0.01, 25)` = 1e23). Live fork
///         measurement below: 10 stETH referred at tier 1 (multiplier 5e23)
///         yields virtualAmountStaked = 10 * 5e23 / 1e25 = 0.5 stETH-equiv —
///         the intended 5% bonus, not 500,000x. End-to-end, the referrer earns
///         a fraction of what a 10x-bigger plain stake earns. No bug; the
///         mechanism works as designed. (Self-referral for the designed
///         1% + 3-15% bonus remains the already-known A1, acknowledged.)
///
///         Fork: Ethereum 26391516. Attacker = unprivileged; no owner/admin
///         prank anywhere.
///
///         Oracle note: on a static fork, stETH does not rebase and Aave's
///         index does not move, so `distributeRewards` would see totalYield
///         == 0 and park the period's MOR in `undistributedRewards`. The test
///         donates 0.01 stETH straight to the Distributor before distributing
///         — the same permissionless donation primitive C4 Low [01] describes
///         — to simulate one day of natural yield (in production ~0.4 stETH/day
///         accrues from the 4,712 stETH alone). Prices are held at fork values
///         via fresh-mocked feed reads (see _mockFeedsFresh); the measured
///         effect does not depend on price.
contract PocD1ReferrerTierTest is Test {
    uint256 constant ETH_BLOCK = 26391516;
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant POOL_STETH = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    address user;
    address referrer;
    address victim;

    address constant FEED_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address constant FEED_WETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant FEED_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address constant FEED_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    function setUp() public {
        vm.createSelectFork("eth", ETH_BLOCK);
        user = makeAddr("user");
        referrer = makeAddr("referrer");
        victim = makeAddr("victim");
        vm.deal(user, 10 ether);
        vm.deal(victim, 10 ether);
        vm.deal(referrer, 10 ether);
        vm.prank(DISTRIBUTOR);
        IERC20D1(STETH).transfer(user, 10.1 ether);
        vm.prank(DISTRIBUTOR);
        IERC20D1(STETH).transfer(victim, 100 ether);
    }

    function _mockFeedsFresh() internal {
        uint256 ts = block.timestamp - 60;
        _mockFeed(FEED_STETH_USD, 36893488147419126742, 205495608034, ts);
        _mockFeed(FEED_WETH_USD, 129127208515966896904, 205930106386, ts);
        _mockFeed(FEED_WBTC_BTC, 36893488147419104089, 99950000, ts);
        _mockFeed(FEED_BTC_USD, 129127208515966887235, 7395663995243, ts);
        _mockFeed(FEED_USDC_USD, 73786976294838206525, 99968041, ts);
        _mockFeed(FEED_USDT_USD, 73786976294838206522, 99876000, ts);
    }

    function _mockFeed(address feed, uint80 roundId, int256 answer, uint256 ts) internal {
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IAggregatorD1.latestRoundData.selector),
            abi.encode(roundId, answer, ts, ts, roundId)
        );
    }

    function _stakeBoth() internal {
        IPoolD1 pool = IPoolD1(POOL_STETH);
        vm.startPrank(victim);
        IERC20D1(STETH).approve(DISTRIBUTOR, 100 ether);
        pool.stake(0, 100 ether, 0, address(0));
        vm.stopPrank();
        vm.startPrank(user);
        IERC20D1(STETH).approve(DISTRIBUTOR, 10 ether);
        pool.stake(0, 10 ether, 0, referrer);
        vm.stopPrank();
    }

    /// Disproof of the scale bug: virtual stake is the intended 5%, not 500,000x.
    function test_ReferrerTierMultiplierIsAsDesigned() public {
        IPoolD1 pool = IPoolD1(POOL_STETH);
        _stakeBoth();
        assertEq(pool.getReferrerMultiplier(0, referrer), 5e23, "tier 1 multiplier");
        (, uint256 virtualStaked, , , ) = pool.referrersData(referrer, 0);
        // 10 stETH * 5e23 / PRECISION(1e25) = 0.5 stETH-equiv (5% bonus).
        assertEq(virtualStaked, 5e17, "virtual staked = 5% of referred, as designed");
        (, , uint256 totalVirtual) = pool.rewardPoolsData(0);
        assertLt(virtualStaked, totalVirtual / 1000, "referrer virtual is negligible vs pool");
        emit log_named_uint("referrer virtual (wei)", virtualStaked);
        emit log_named_uint("pool totalVirtualDeposited (wei)", totalVirtual);
    }

    /// End-to-end control: over 25h the referrer earns far LESS than a plain
    /// 10x-bigger stake — the referral bonus dilutes nobody.
    function test_ReferrerEarningsAreNegligibleVsPlainStake() public {
        IPoolD1 pool = IPoolD1(POOL_STETH);
        _stakeBoth();
        vm.warp(block.timestamp + 25 hours);
        _mockFeedsFresh();
        // Simulate one day of natural yield (see contract notice).
        vm.prank(user);
        IERC20D1(STETH).transfer(DISTRIBUTOR, 0.01 ether);
        IDistributorD1(DISTRIBUTOR).distributeRewards(0);

        uint256 referrerPending = pool.getLatestReferrerReward(0, referrer);
        uint256 victimPending = pool.getLatestUserReward(0, victim);
        emit log_named_uint("referrer pending MOR (wei)", referrerPending);
        emit log_named_uint("victim pending MOR (wei)", victimPending);
        // Measured on the fork: stETH pool takes ~23% of the 25h emission
        // (other AAVE pools earn their share from time-based index accrual),
        // victim (100 stETH, no referrer) earns ~6.3 MOR, referrer ~0.03 MOR.
        assertGt(victimPending, 5 ether, "victim earns a normal share (~6 MOR)");
        assertLt(referrerPending, victimPending / 50, "referrer earns <2% of the victim's share");
        assertLt(referrerPending, 1 ether, "referrer earns < 1 MOR over 25h");
    }
}
