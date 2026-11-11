// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

interface IERC20Cap {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

struct UserDataCap {
    uint128 lastStake;
    uint256 deposited;
    uint256 rate;
    uint256 pendingRewards;
    uint128 claimLockStart;
    uint128 claimLockEnd;
    uint256 virtualDeposited;
    uint128 lastClaim;
}

interface IPoolCap {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function withdraw(uint256 rewardPoolIndex_, uint256 amount_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function usersData(address, uint256) external view returns (UserDataCap memory);
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function totalDepositedInPublicPools() external view returns (uint256);
    function rewardPoolsData(uint256) external view returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
    function rewardPoolsProtocolDetails(uint256)
        external
        view
        returns (uint128, uint128, uint128, uint256, uint256);
}

interface IDistributorCap {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function getDistributedRewards(uint256, address) external view returns (uint256);
    function undistributedRewards() external view returns (uint256);
}

interface IRewardPoolCap {
    function getPeriodRewards(uint256 index_, uint128 startTime_, uint128 endTime_)
        external
        view
        returns (uint256);
}

interface IAggregatorCap {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title Fase 3 Lane G4-C — DepositPool/Distributor invariant fuzzing (ETH fork 26391516)
/// @notice Random sequences of stake / withdraw / claim / donateYield /
///         distribute / warp by 3 unprivileged actors on the stETH pool (0).
///         No owner prank. Handler keeps an independent ledger (measured
///         deltas only — Lido share rounding means a 1 stETH stake credits
///         1 ether - 1 wei; invariants never assume exact input amounts).
///         Funding: actors are funded with stETH by prank-transferring from
///         the Curve stETH/ETH pool (19,666 stETH at the pinned block) — the
///         Distributor itself is never touched for funding, so the excess
///         baseline stays clean. `deal()` cannot fund stETH (stdStorage
///         checked_write fails on Lido's share math).
///         Donations are NOT a protocol action: on a static fork stETH never
///         rebases and Aave's index never moves, so `distributeRewards`
///         would see totalYield == 0 and park every period's MOR in
///         undistributedRewards. A permissionless donation to the Distributor
///         simulates one day of natural yield (production: ~0.4 stETH/day
///         accrues from the 4,712 stETH alone) — the same primitive D1 used.
///         Chainlink feeds are re-mocked fresh after every warp (D1 pattern),
///         else they go stale and yields read 0.
///         Live facts baked in: minimalStake = 0.01 stETH, withdraw lock 7d,
///         claim locks 14d, minRewardsDistributePeriod = 1 day, pool-0
///         strategy is NONE (deposits stay raw stETH in the Distributor),
///         payoutStart = 1707393600, initialReward = 3456 MOR/day.
///         Invariants (see phase-03-lane-g4c-invariant.md for formulas):
///         C1 Distributor stETH excess over totalDeposited stays in
///            [-numWithdraws wei, setupExcess + totalDonated]
///         C2 sum of handler-measured claimed MOR <= chain distributedRewards
///         C3 distributedRewards <= schedule cap getPeriodRewards(payoutStart, now)
///         C4 incremental (distributed + undistributed) <= incremental
///            schedule cap + 1 day's initial reward (rounding tolerance)
///         C5 no phantom virtual stake: actorNet == 0 => virtual == 0;
///            virtual >= deposited
///         C6 immediately after a claim, getLatestUserReward == 0
///         C7 per-actor withdrawn <= debited, shortfall <= 1 wei/withdraw
///         C8 per-actor usersData.deposited == handler actor ledger
contract CapitalHandler is Test {
    uint256 constant DAY = 86400;

    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant POOL_STETH = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    address constant FEED_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address constant FEED_WETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant FEED_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address constant FEED_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    address[3] public actors;

    mapping(address => uint256) public actorNet;
    mapping(address => uint256) public stakedTotal;
    mapping(address => uint256) public withdrawnTotal;
    mapping(address => uint256) public claimedTotal;

    uint256 public totalDonated;
    uint256 public numWithdraws;
    address public lastClaimActor;
    uint256 public lastClaimTime;

    int256 public setupExcess;
    uint256 public setupDistributed;
    uint256 public setupUndistributed;
    uint128 public setupLastUpdate;

    constructor(address[3] memory _actors) {
        actors = _actors;
        setupExcess = int256(IERC20Cap(STETH).balanceOf(DISTRIBUTOR))
            - int256(IPoolCap(POOL_STETH).totalDepositedInPublicPools());
        (,,,, uint256 distributed) = IPoolCap(POOL_STETH).rewardPoolsProtocolDetails(0);
        setupDistributed = distributed;
        setupUndistributed = IDistributorCap(DISTRIBUTOR).undistributedRewards();
        (uint128 lastUpdate,,) = IPoolCap(POOL_STETH).rewardPoolsData(0);
        setupLastUpdate = lastUpdate;
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
            abi.encodeWithSelector(IAggregatorCap.latestRoundData.selector),
            abi.encode(roundId, answer, ts, ts, roundId)
        );
    }

    function mockFeedsFresh() external {
        _mockFeedsFresh();
    }

    function stake(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 3];
        uint256 amt = bound(amount, 0.01 ether, 5 ether);
        if (IERC20Cap(STETH).balanceOf(actor) < amt) return;

        uint256 beforeDep = IPoolCap(POOL_STETH).usersData(actor, 0).deposited;
        vm.prank(actor);
        IPoolCap(POOL_STETH).stake(0, amt, 0, address(0));
        uint256 afterDep = IPoolCap(POOL_STETH).usersData(actor, 0).deposited;
        uint256 delta = afterDep - beforeDep; // measured; Lido rounding makes this amt - 1 wei

        actorNet[actor] += delta;
        stakedTotal[actor] += delta;
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 3];
        uint256 dep = IPoolCap(POOL_STETH).usersData(actor, 0).deposited;
        if (dep == 0) return;
        uint256 amt = bound(amount, 1, dep);
        if (dep - amt < 0.01 ether && dep - amt != 0) amt = dep; // respect minimalStake remainder

        uint256 beforeDep = dep;
        uint256 beforeBal = IERC20Cap(STETH).balanceOf(actor);
        vm.prank(actor);
        IPoolCap(POOL_STETH).withdraw(0, amt);
        uint256 afterDep = IPoolCap(POOL_STETH).usersData(actor, 0).deposited;
        uint256 afterBal = IERC20Cap(STETH).balanceOf(actor);
        uint256 depDelta = beforeDep - afterDep;
        uint256 received = afterBal - beforeBal;

        actorNet[actor] -= depDelta;
        withdrawnTotal[actor] += received;
        numWithdraws++;
    }

    function claim(uint256 seed) external {
        address actor = actors[seed % 3];
        uint256 pending = IPoolCap(POOL_STETH).getLatestUserReward(0, actor);
        if (pending == 0) return;

        vm.prank(actor);
        IPoolCap(POOL_STETH).claim{value: 0.05 ether}(0, actor);
        // _claim zeroes pending; the MOR is minted on L2 via LayerZero, so
        // the claimed amount is measured as pending-before, not a balance.
        claimedTotal[actor] += pending;
        lastClaimActor = actor;
        lastClaimTime = block.timestamp;
    }

    function donateYield(uint256 seed, uint256 amount) external {
        address actor = actors[seed % 3];
        uint256 amt = bound(amount, 0.001 ether, 0.5 ether);
        if (IERC20Cap(STETH).balanceOf(actor) < amt) return;

        uint256 beforeBal = IERC20Cap(STETH).balanceOf(DISTRIBUTOR);
        vm.prank(actor);
        IERC20Cap(STETH).transfer(DISTRIBUTOR, amt);
        uint256 donated = IERC20Cap(STETH).balanceOf(DISTRIBUTOR) - beforeBal;
        totalDonated += donated;
    }

    function distribute(uint256 seed) external {
        vm.prank(actors[seed % 3]);
        IDistributorCap(DISTRIBUTOR).distributeRewards(0);
    }

    function warp(uint256 seed) external {
        uint256 days_ = bound(seed, 1, 30);
        vm.warp(block.timestamp + days_ * DAY);
        _mockFeedsFresh();
    }
}

contract CapitalInvariantTest is Test {
    uint256 constant ETH_BLOCK = 26391516;
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant POOL_STETH = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant REWARD_POOL = 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87;
    address constant CURVE_STETH_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    uint128 constant PAYOUT_START = 1707393600;
    uint256 constant ONE_DAY_REWARD = 3456 ether; // initialReward, rounding tolerance for C4

    CapitalHandler handler;
    address[3] actors;

    function setUp() public {
        vm.createSelectFork("eth", ETH_BLOCK);
        actors = [makeAddr("cActor0"), makeAddr("cActor1"), makeAddr("cActor2")];
        handler = new CapitalHandler(actors);
        handler.mockFeedsFresh();
        for (uint256 i = 0; i < 3; i++) {
            // Fund with stETH from the Curve pool (19,666 stETH at the pin).
            // `deal()` cannot fund stETH; the Distributor is never touched.
            vm.prank(CURVE_STETH_POOL);
            IERC20Cap(STETH).transfer(actors[i], 15 ether);
            vm.prank(actors[i]);
            IERC20Cap(STETH).approve(DISTRIBUTOR, type(uint256).max);
            vm.deal(actors[i], 10 ether); // LayerZero value for claims
        }
        vm.deal(address(handler), 10 ether); // fallback if value draws from the caller
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = CapitalHandler.stake.selector;
        selectors[1] = CapitalHandler.withdraw.selector;
        selectors[2] = CapitalHandler.claim.selector;
        selectors[3] = CapitalHandler.donateYield.selector;
        selectors[4] = CapitalHandler.distribute.selector;
        selectors[5] = CapitalHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _distributed() internal view returns (uint256) {
        (,,,, uint256 distributed) = IPoolCap(POOL_STETH).rewardPoolsProtocolDetails(0);
        return distributed;
    }

    function invariant_C1_excessBounds() public view {
        int256 excess = int256(IERC20Cap(STETH).balanceOf(DISTRIBUTOR))
            - int256(IPoolCap(POOL_STETH).totalDepositedInPublicPools());
        assertGe(excess, -int256(handler.numWithdraws()), "C1 excess lower bound");
        assertLe(
            excess,
            handler.setupExcess() + int256(handler.totalDonated()),
            "C1 excess upper bound"
        );
    }

    function invariant_C2_claimedBounded() public view {
        uint256 sum;
        for (uint256 i = 0; i < 3; i++) sum += handler.claimedTotal(actors[i]);
        assertLe(sum, _distributed(), "C2 claimed <= distributed");
    }

    function invariant_C3_scheduleCap() public view {
        uint256 cap = IRewardPoolCap(REWARD_POOL).getPeriodRewards(
            0, PAYOUT_START, uint128(block.timestamp)
        );
        assertLe(_distributed(), cap, "C3 distributed <= schedule cap");
    }

    function invariant_C4_incrementalCap() public view {
        uint256 distDelta = _distributed() - handler.setupDistributed();
        uint256 undDelta =
            IDistributorCap(DISTRIBUTOR).undistributedRewards() - handler.setupUndistributed();
        uint256 cap = IRewardPoolCap(REWARD_POOL).getPeriodRewards(
            0, handler.setupLastUpdate(), uint128(block.timestamp)
        );
        assertLe(distDelta + undDelta, cap + ONE_DAY_REWARD, "C4 incremental <= cap + 1 day");
    }

    function invariant_C5_noPhantomVirtual() public view {
        for (uint256 i = 0; i < 3; i++) {
            UserDataCap memory u = IPoolCap(POOL_STETH).usersData(actors[i], 0);
            if (handler.actorNet(actors[i]) == 0) {
                assertEq(u.virtualDeposited, 0, "C5 no phantom virtual");
            }
            assertGe(u.virtualDeposited, u.deposited, "C5 virtual >= deposited");
        }
    }

    function invariant_C6_claimResetsPending() public view {
        address actor = handler.lastClaimActor();
        if (actor == address(0)) return;
        if (block.timestamp != handler.lastClaimTime()) return;
        assertEq(IPoolCap(POOL_STETH).getLatestUserReward(0, actor), 0, "C6 pending reset");
    }

    function invariant_C7_withdrawExact() public view {
        for (uint256 i = 0; i < 3; i++) {
            address actor = actors[i];
            uint256 debited = handler.stakedTotal(actor) - handler.actorNet(actor);
            uint256 paid = handler.withdrawnTotal(actor);
            assertLe(paid, debited, "C7 never overpaid");
            assertLe(debited - paid, handler.numWithdraws(), "C7 shortfall <= 1 wei/withdraw");
        }
    }

    function invariant_C8_depositLedger() public view {
        for (uint256 i = 0; i < 3; i++) {
            uint256 dep = IPoolCap(POOL_STETH).usersData(actors[i], 0).deposited;
            assertEq(dep, handler.actorNet(actors[i]), "C8 deposited == ledger");
        }
    }
}
