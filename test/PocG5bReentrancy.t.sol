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

interface IBuildersV4G5 {
    function createSubnet(Subnet calldata subnet_, SubnetMetadata calldata metadata_) external;
    function editSubnet(bytes32 subnetId_, Subnet calldata newSubnet_) external;
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function withdraw(bytes32 subnetId_, uint256 amount_) external;
    function claim(bytes32 subnetId_, address receiver_) external;
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    function subnets(bytes32 subnetId_)
        external
        view
        returns (string memory, address, uint128, uint128, uint128, uint256, address);
    function usersData(address user_, bytes32 subnetId_) external view returns (UserData memory);
    function minimalWithdrawLockPeriod() external view returns (uint256);
    function getCurrentSubnetRewards(bytes32 subnetId_) external view returns (uint256);
}

interface IFeeConfigG5 {
    function getFeeAndTreasuryForOperation(address sender_, bytes32 operation_)
        external
        view
        returns (uint256, address);
    function setFeeForOperation(address sender_, bytes32 operation_, uint256 fee_) external;
}

/// @notice Malicious receiver: every time it receives MOR it tries to reenter
///         BuildersV4 (same-subnet claim, cross-subnet claim, withdraw).
///         If plain-ERC20 transfers ever invoked a receiver hook, the
///         counters below would move. They must stay at zero.
contract EvilReceiver {
    address public immutable builders;
    bytes32 public targetSubnet;
    bytes32 public otherSubnet;
    bytes32 public withdrawSubnet;
    uint256 public reentryAttempts;
    uint256 public reentrySuccesses;

    constructor(address builders_) {
        builders = builders_;
    }

    receive() external payable {
        _tryReenter();
    }

    fallback() external payable {
        _tryReenter();
    }

    function setTargets(bytes32 t_, bytes32 o_, bytes32 w_) external {
        targetSubnet = t_;
        otherSubnet = o_;
        withdrawSubnet = w_;
    }

    function _tryReenter() internal {
        reentryAttempts++;
        if (targetSubnet != bytes32(0)) {
            try IBuildersV4G5(builders).claim(targetSubnet, address(this)) {
                reentrySuccesses++;
            } catch {}
        }
        if (otherSubnet != bytes32(0)) {
            try IBuildersV4G5(builders).claim(otherSubnet, address(this)) {
                reentrySuccesses++;
            } catch {}
        }
        if (withdrawSubnet != bytes32(0)) {
            try IBuildersV4G5(builders).withdraw(withdrawSubnet, type(uint256).max) {
                reentrySuccesses++;
            } catch {}
        }
    }

    function doClaim(bytes32 id_, address receiver_) external {
        IBuildersV4G5(builders).claim(id_, receiver_);
    }

    function doWithdraw(bytes32 id_, uint256 amount_) external {
        IBuildersV4G5(builders).withdraw(id_, amount_);
    }

    function doDeposit(bytes32 id_, uint256 amount_) external {
        IERC20M(0x7431aDa8a591C955a994a21710752EF9b882b8e3).approve(builders, amount_);
        IBuildersV4G5(builders).deposit(id_, amount_);
    }

    function doEditSubnet(bytes32 id_, Subnet calldata s_) external {
        IBuildersV4G5(builders).editSubnet(id_, s_);
    }
}

/// @title BuildersV4 — reentrancy and receiver-controlled flows (Base fork)
/// @notice Fork tests on Base block 56038769. claim() pays pendingRewards to a
///         caller-chosen receiver via BuildersTreasuryV2.sendRewards (plain
///         MOR safeTransfer); withdraw() pays to msg.sender the same way.
///         The question is whether a malicious receiver contract can reenter
///         and extract more than its single-call entitlement.
contract PocG5bReentrancyTest is Test {
    uint256 constant BASE_BLOCK = 56038769;
    address constant BUILDERS_V4 = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    address constant FEE_CONFIG = 0x2e1fF173085A5ef12046c27E442f12f79A0092b7;

    uint256 constant MIN_LOCK = 604800; // 7 days, live minimalWithdrawLockPeriod

    address attacker;
    address legit;
    address victim1;
    address victim2;
    EvilReceiver evil;

    function setUp() public {
        vm.createSelectFork("base", BASE_BLOCK);
        attacker = makeAddr("attacker");
        legit = makeAddr("legitBuilder");
        victim1 = makeAddr("victim1");
        victim2 = makeAddr("victim2");
        evil = new EvilReceiver(BUILDERS_V4);
        vm.deal(attacker, 10 ether);
        vm.deal(legit, 10 ether);
        vm.deal(victim1, 10 ether);
        vm.deal(victim2, 10 ether);
        deal(MOR, attacker, 100_000 ether);
        deal(MOR, legit, 100_000 ether);
        deal(MOR, victim1, 100_000 ether);
        deal(MOR, victim2, 100_000 ether);
        deal(MOR, address(evil), 100_000 ether);
    }

    function _mkSubnet(string memory name, address admin, address claimAdmin, uint256 lock)
        internal
        pure
        returns (Subnet memory)
    {
        return
            Subnet({
                name: name,
                admin: admin,
                unused1: 0,
                withdrawLockPeriodAfterDeposit: uint128(lock),
                unused2: 0,
                minimalDeposit: 1 ether,
                claimAdmin: claimAdmin
            });
    }

    function _mkMeta() internal pure returns (SubnetMetadata memory) {
        return SubnetMetadata({slug: "g5b", description: "g5b", website: "https://example.com", image: ""});
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
        IERC20M(MOR).approve(BUILDERS_V4, amount);
        vm.prank(who);
        IBuildersV4G5(BUILDERS_V4).deposit(id, amount);
    }

    function _fundSpoof(bytes32 id, uint256 v1, uint256 v2) internal {
        _deposit(victim1, id, v1);
        _deposit(victim2, id, v2);
    }

    // R1: receiver contract as claimAdmin, receiver = itself. The MOR
    // transfer must not invoke the receiver hook at all; and even a direct
    // second claim must revert because pendingRewards is zeroed first.
    function test_R1_ReceiverCannotReenterClaimSameSubnet() public {
        bytes32 spoof = _create("R1Spoof", legit, address(evil), MIN_LOCK, attacker);
        _fundSpoof(spoof, 50_000 ether, 50_000 ether);
        evil.setTargets(spoof, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + 30 days);
        uint256 pending = IBuildersV4G5(BUILDERS_V4).getCurrentSubnetRewards(spoof);
        assertGt(pending, 1_000 ether, "spoof must have material pending rewards");

        uint256 before = IERC20M(MOR).balanceOf(address(evil));
        evil.doClaim(spoof, address(evil));
        uint256 received = IERC20M(MOR).balanceOf(address(evil)) - before;

        assertEq(received, pending, "receiver must get exactly one claim");
        assertEq(evil.reentryAttempts(), 0, "no callback into the receiver may happen");
        assertEq(evil.reentrySuccesses(), 0, "no reentrant call may succeed");
        assertEq(IBuildersV4G5(BUILDERS_V4).getCurrentSubnetRewards(spoof), 0, "pending must be zeroed");

        vm.expectRevert("BU: nothing to claim");
        evil.doClaim(spoof, address(evil));
    }

    // R2: cross-subnet reentry. Evil is claimAdmin of two funded spoofs; the
    // claim of A must not let it touch B inside the same call, nor change
    // B's pending at all.
    function test_R2_ReceiverCannotReenterClaimCrossSubnet() public {
        bytes32 a = _create("R2SpoofA", legit, address(evil), MIN_LOCK, attacker);
        bytes32 b = _create("R2SpoofB", legit, address(evil), MIN_LOCK, attacker);
        _fundSpoof(a, 50_000 ether, 50_000 ether);
        _fundSpoof(b, 50_000 ether, 50_000 ether);
        evil.setTargets(a, b, bytes32(0));

        vm.warp(block.timestamp + 30 days);
        uint256 pendingA = IBuildersV4G5(BUILDERS_V4).getCurrentSubnetRewards(a);
        uint256 pendingB = IBuildersV4G5(BUILDERS_V4).getCurrentSubnetRewards(b);
        assertGt(pendingA, 1_000 ether);
        assertGt(pendingB, 1_000 ether);

        uint256 before = IERC20M(MOR).balanceOf(address(evil));
        evil.doClaim(a, address(evil));
        uint256 received = IERC20M(MOR).balanceOf(address(evil)) - before;

        assertEq(received, pendingA, "only A's entitlement may be paid");
        assertEq(evil.reentryAttempts(), 0, "no callback into the receiver may happen");
        assertEq(evil.reentrySuccesses(), 0, "no reentrant call may succeed");
        assertEq(
            IBuildersV4G5(BUILDERS_V4).getCurrentSubnetRewards(b),
            pendingB,
            "B's pending must be untouched by A's claim"
        );
    }

    // R3: withdraw to a contract receiver. State (userData.deposited) is cut
    // before the MOR transfer, so a second withdraw finds nothing.
    function test_R3_ReceiverCannotReenterWithdraw() public {
        bytes32 w = _create("R3Subnet", legit, legit, MIN_LOCK, attacker);
        evil.setTargets(bytes32(0), bytes32(0), w);
        evil.doDeposit(w, 10_000 ether);

        vm.warp(block.timestamp + 8 days);
        uint256 before = IERC20M(MOR).balanceOf(address(evil));
        evil.doWithdraw(w, 10_000 ether);
        uint256 received = IERC20M(MOR).balanceOf(address(evil)) - before;

        assertEq(received, 10_000 ether, "one full withdraw only");
        assertEq(evil.reentryAttempts(), 0, "no callback into the receiver may happen");
        assertEq(evil.reentrySuccesses(), 0, "no reentrant call may succeed");
        assertEq(
            IBuildersV4G5(BUILDERS_V4).usersData(address(evil), w).deposited, 0, "position must be empty"
        );

        vm.expectRevert("BU: nothing to withdraw");
        evil.doWithdraw(w, 1 ether);
    }

    // R4: deposit pulls MOR from the caller via safeTransferFrom. No hook
    // fires on the depositor, so no reentry is possible through deposit.
    function test_R4_ReceiverCannotReenterDeposit() public {
        bytes32 d = _create("R4Subnet", legit, legit, MIN_LOCK, attacker);
        evil.setTargets(d, d, d);
        evil.doDeposit(d, 10_000 ether);

        assertEq(evil.reentryAttempts(), 0, "no callback into the depositor may happen");
        assertEq(
            IBuildersV4G5(BUILDERS_V4).usersData(address(evil), d).deposited,
            10_000 ether,
            "deposit recorded exactly once"
        );
    }

    // R5: editSubnet has no external calls at all; a non-admin receiver
    // cannot edit from inside (or outside) a claim.
    function test_R5_ReceiverCannotReenterEditSubnet() public {
        bytes32 s = _create("R5Subnet", legit, legit, MIN_LOCK, attacker);
        evil.setTargets(s, bytes32(0), bytes32(0));

        vm.expectRevert("BU: not the Subnet owner");
        evil.doEditSubnet(s, _mkSubnet("R5Subnet", address(evil), address(evil), MIN_LOCK));

        (, address adminAfter,,,,, address claimAfter) = IBuildersV4G5(BUILDERS_V4).subnets(s);
        assertEq(adminAfter, legit, "admin unchanged");
        assertEq(claimAfter, legit, "claimAdmin unchanged");
    }

    // R6: claim + withdraw in one sequence. claim() never touches the
    // caller's userData, so it cannot reset or bypass the withdraw lock.
    function test_R6_ClaimDoesNotBypassWithdrawLock() public {
        bytes32 spoof = _create("R6Spoof", legit, attacker, MIN_LOCK, attacker);
        _fundSpoof(spoof, 50_000 ether, 50_000 ether);
        _deposit(attacker, spoof, 10_000 ether);

        vm.warp(block.timestamp + 2 days);
        uint256 pending = IBuildersV4G5(BUILDERS_V4).getCurrentSubnetRewards(spoof);
        assertGt(pending, 0, "yield must have accrued");

        vm.prank(attacker);
        IBuildersV4G5(BUILDERS_V4).claim(spoof, attacker);

        // Attacker just claimed; their own 10k deposit is still locked.
        vm.prank(attacker);
        vm.expectRevert("BU: user withdraw is locked");
        IBuildersV4G5(BUILDERS_V4).withdraw(spoof, 10_000 ether);

        // Control: after the lock passes, the same withdraw works normally.
        vm.warp(block.timestamp + 6 days);
        uint256 before = IERC20M(MOR).balanceOf(attacker);
        vm.prank(attacker);
        IBuildersV4G5(BUILDERS_V4).withdraw(spoof, 10_000 ether);
        assertEq(IERC20M(MOR).balanceOf(attacker) - before, 10_000 ether);
    }

    // R7: claiming to a contract pays exactly what claiming to an EOA pays.
    function test_R7_ClaimToContractEqualsClaimToEOA() public {
        bytes32 eoaSub = _create("R7Eoa", legit, attacker, MIN_LOCK, attacker);
        bytes32 ctrSub = _create("R7Ctr", legit, address(evil), MIN_LOCK, attacker);
        _fundSpoof(eoaSub, 50_000 ether, 50_000 ether);
        _fundSpoof(ctrSub, 50_000 ether, 50_000 ether);
        evil.setTargets(bytes32(0), bytes32(0), bytes32(0));

        vm.warp(block.timestamp + 30 days);
        uint256 pendingEoa = IBuildersV4G5(BUILDERS_V4).getCurrentSubnetRewards(eoaSub);
        uint256 pendingCtr = IBuildersV4G5(BUILDERS_V4).getCurrentSubnetRewards(ctrSub);
        assertEq(pendingEoa, pendingCtr, "identical setups must accrue identically");

        uint256 eoaBefore = IERC20M(MOR).balanceOf(attacker);
        vm.prank(attacker);
        IBuildersV4G5(BUILDERS_V4).claim(eoaSub, attacker);
        uint256 eoaGot = IERC20M(MOR).balanceOf(attacker) - eoaBefore;

        uint256 ctrBefore = IERC20M(MOR).balanceOf(address(evil));
        evil.doClaim(ctrSub, address(evil));
        uint256 ctrGot = IERC20M(MOR).balanceOf(address(evil)) - ctrBefore;

        assertEq(eoaGot, ctrGot, "contract receiver gets exactly the EOA amount");
        assertEq(evil.reentryAttempts(), 0);
    }

    // R8: the FeeConfig call inside claim() is a view to an owner-set
    // contract; the live claim fee is 0 and the attacker cannot change it.
    function test_R8_FeeConfigNotAttackerInfluencable() public {
        (uint256 claimFee, address claimTreasury) = IFeeConfigG5(FEE_CONFIG)
            .getFeeAndTreasuryForOperation(BUILDERS_V4, bytes32("claim"));
        assertEq(claimFee, 0, "live claim fee must be 0");
        // Treasury is unset (address 0) live, but irrelevant: with fee 0 the
        // `if (feeAmount_ > 0)` branch in claim() never runs, so no MOR is
        // ever sent to it.
        assertEq(claimTreasury, address(0), "claim treasury unset live; unused while fee is 0");

        (uint256 createFee, ) = IFeeConfigG5(FEE_CONFIG).getFeeAndTreasuryForOperation(
            BUILDERS_V4, bytes32("buildersV4.fee.subnet.create")
        );
        assertEq(createFee, 0, "live subnet-create fee must be 0");

        vm.prank(attacker);
        vm.expectRevert();
        IFeeConfigG5(FEE_CONFIG).setFeeForOperation(BUILDERS_V4, bytes32("claim"), 1e25);
    }

    // R9: claiming to BuildersV4 itself just parks MOR in the contract;
    // no accounting reads the contract's MOR balance, so nothing drifts.
    function test_R9_ClaimToBuildersV4ItselfNoDrift() public {
        bytes32 spoof = _create("R9Spoof", legit, attacker, MIN_LOCK, attacker);
        _fundSpoof(spoof, 50_000 ether, 50_000 ether);

        vm.warp(block.timestamp + 30 days);
        uint256 pending = IBuildersV4G5(BUILDERS_V4).getCurrentSubnetRewards(spoof);
        assertGt(pending, 1_000 ether);

        // BuildersV4 already holds all deposited principal (live subnets +
        // this spoof's 100k MOR), so measure the delta, not the absolute.
        uint256 balanceBefore = IERC20M(MOR).balanceOf(BUILDERS_V4);
        vm.prank(attacker);
        IBuildersV4G5(BUILDERS_V4).claim(spoof, BUILDERS_V4);
        assertEq(
            IERC20M(MOR).balanceOf(BUILDERS_V4) - balanceBefore,
            pending,
            "yield parked in BuildersV4"
        );
        assertEq(IBuildersV4G5(BUILDERS_V4).getCurrentSubnetRewards(spoof), 0, "pending zeroed");

        vm.prank(attacker);
        vm.expectRevert("BU: nothing to claim");
        IBuildersV4G5(BUILDERS_V4).claim(spoof, attacker);

        // Victims can still withdraw their principal in full afterwards.
        vm.prank(victim1);
        IBuildersV4G5(BUILDERS_V4).withdraw(spoof, 50_000 ether);
        assertEq(IERC20M(MOR).balanceOf(victim1), 100_000 ether, "victim principal intact");
    }
}
