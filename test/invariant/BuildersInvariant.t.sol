// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

interface IERC20Inv {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

struct SubnetInv {
    string name;
    address admin;
    uint128 unused1;
    uint128 withdrawLockPeriodAfterDeposit;
    uint128 unused2;
    uint256 minimalDeposit;
    address claimAdmin;
}

struct SubnetMetadataInv {
    string slug;
    string description;
    string website;
    string image;
}

struct UserDataInv {
    uint128 lastDeposit;
    uint128 unused1;
    uint256 deposited;
    uint256 unused2;
}

struct SubnetDataInv {
    uint128 unused1;
    uint256 deposited;
    uint256 unused2;
    uint256 rate;
    uint256 pendingRewards;
}

interface IBuildersV4Inv {
    function createSubnet(SubnetInv calldata subnet_, SubnetMetadataInv calldata metadata_) external;
    function editSubnet(bytes32 subnetId_, SubnetInv calldata newSubnet_) external;
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function withdraw(bytes32 subnetId_, uint256 amount_) external;
    function claim(bytes32 subnetId_, address receiver_) external;
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    function subnets(bytes32 subnetId_)
        external
        view
        returns (string memory, address, uint128, uint128, uint128, uint256, address);
    function usersData(address user_, bytes32 subnetId_) external view returns (UserDataInv memory);
    function subnetsData(bytes32 subnetId_) external view returns (SubnetDataInv memory);
    function allSubnetsData() external view returns (uint256, uint256, uint256, uint256);
    function allSubnetsDataV4() external view returns (uint256, uint256, uint256, uint128);
    function minimalWithdrawLockPeriod() external view returns (uint256);
    function getCurrentSubnetRewards(bytes32 subnetId_) external view returns (uint256);
    function getCurrentSubnetsRewards() external view returns (uint256);
}

/// @title Fase 3 Lane G4-C — BuildersV4 invariant fuzzing (Base fork 56038769)
/// @notice Random sequences of createSubnet / deposit / withdraw / claim /
///         editSubnet / warp by 4 unprivileged actors. No owner prank.
///         Handler keeps an independent ledger (measured deltas only — never
///         assumes the requested amount lands exactly) and the invariants
///         compare chain state against that ledger.
///         Live facts baked in: minimalWithdrawLockPeriod = 7 days,
///         subnetCreationFeeAmount = 0, MOR is a plain ERC20 on Base (no
///         share rounding), claim pays from the Treasury (not from
///         BuildersV4's own MOR balance) and takes a fee via feeConfig, so
///         received <= chain-accounted claimed.
///         Invariants (see phase-03-lane-g4c-invariant.md for formulas):
///         B1 totalDeposited == setup + net handler deposits
///         B2 last-touched subnet deposited == handler subnet ledger
///         B3 BuildersV4 MOR balance == setup balance + net handler deposits
///         B4 claimedRewards <= distributedRewards (chain)
///         B5 getCurrentSubnetsRewards() does not revert (claimed never
///            exceeds distributed + current accrual)
///         B6 last-touched subnet live pending <= global live pending
///         B7 global rate is non-decreasing
///         B8 last-touched (actor, subnet) deposited == handler pair ledger
///         B9 immediately after a claim, stored pendingRewards == 0
///         B10 per-actor withdrawn <= debited, shortfall <= 1 wei/withdraw
///         B11 handler-measured received <= chain claimed delta (fee-aware)
contract BuildersHandler is Test {
    uint256 constant DAY = 86400;
    uint256 constant MIN_LOCK = 604800; // 7 days, live minimalWithdrawLockPeriod

    address constant BUILDERS_V4 = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    address[4] public actors;

    bytes32[] public subnetIds;
    mapping(bytes32 => string) public subnetNameOf;
    mapping(bytes32 => address) public subnetAdminOf;
    mapping(bytes32 => address) public subnetClaimAdminOf;
    mapping(bytes32 => uint256) public subnetNet;
    mapping(address => uint256) public actorNet;
    mapping(address => mapping(bytes32 => uint256)) public pairNet;
    mapping(address => uint256) public stakedTotal;
    mapping(address => uint256) public withdrawnTotal;
    mapping(bytes32 => uint256) public claimedSubnet;

    uint256 public netDeposited;
    uint256 public totalClaimed;
    uint256 public numWithdraws;
    bytes32 public lastSubnet;
    address public lastPairActor;
    bytes32 public lastClaimSubnet;
    uint256 public lastClaimTime;

    uint256 public setupTotalDeposited;
    uint256 public setupBalance;
    uint256 public setupRate;
    uint256 public setupDistributed;
    uint256 public setupClaimed;
    uint256 public subnetNonce;

    constructor(address[4] memory _actors) {
        actors = _actors;
        (uint256 _u1, uint256 rate, uint256 total, uint256 _u2) =
            IBuildersV4Inv(BUILDERS_V4).allSubnetsData();
        setupRate = rate;
        setupTotalDeposited = total;
        setupBalance = IERC20Inv(MOR).balanceOf(BUILDERS_V4);
        (uint256 dist, uint256 _und, uint256 claimed, uint128 _lu) =
            IBuildersV4Inv(BUILDERS_V4).allSubnetsDataV4();
        setupDistributed = dist;
        setupClaimed = claimed;
    }

    function numSubnets() external view returns (uint256) {
        return subnetIds.length;
    }

    function subnetIdAt(uint256 i) external view returns (bytes32) {
        return subnetIds[i];
    }

    function createSubnet(uint256 seed) external {
        address admin = actors[seed % 4];
        address claimAdmin = actors[(seed >> 4) % 4];
        uint256 lock = MIN_LOCK + (seed % 54) * DAY; // 7..60 days
        string memory name = string.concat("InvSubnet", vm.toString(subnetNonce));
        subnetNonce++;

        SubnetInv memory s = SubnetInv({
            name: name,
            admin: admin,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: uint128(lock),
            unused2: 0,
            minimalDeposit: 1 ether,
            claimAdmin: claimAdmin
        });
        SubnetMetadataInv memory m =
            SubnetMetadataInv({slug: name, description: "invariant", website: "", image: ""});

        vm.prank(actors[seed % 4]);
        IBuildersV4Inv(BUILDERS_V4).createSubnet(s, m);

        bytes32 id = IBuildersV4Inv(BUILDERS_V4).getSubnetId(name);
        subnetIds.push(id);
        subnetNameOf[id] = name;
        subnetAdminOf[id] = admin;
        subnetClaimAdminOf[id] = claimAdmin;
        lastSubnet = id;
    }

    function deposit(uint256 seed, uint256 amount) external {
        if (subnetIds.length == 0) return;
        bytes32 subnet = subnetIds[seed % subnetIds.length];
        address actor = actors[(seed >> 8) % 4];
        uint256 amt = bound(amount, 1 ether, 500 ether);
        if (IERC20Inv(MOR).balanceOf(actor) < amt) return;

        uint256 beforeDep = IBuildersV4Inv(BUILDERS_V4).usersData(actor, subnet).deposited;
        vm.prank(actor);
        IBuildersV4Inv(BUILDERS_V4).deposit(subnet, amt);
        uint256 afterDep = IBuildersV4Inv(BUILDERS_V4).usersData(actor, subnet).deposited;
        uint256 delta = afterDep - beforeDep; // measured, never assumed == amt

        actorNet[actor] += delta;
        subnetNet[subnet] += delta;
        pairNet[actor][subnet] += delta;
        stakedTotal[actor] += delta;
        netDeposited += delta;
        lastSubnet = subnet;
        lastPairActor = actor;
    }

    function withdraw(uint256 seed, uint256 amount) external {
        if (subnetIds.length == 0) return;
        bytes32 subnet = subnetIds[seed % subnetIds.length];
        address actor = actors[(seed >> 8) % 4];
        uint256 pair = pairNet[actor][subnet];
        if (pair == 0) return;
        uint256 amt = bound(amount, 1, pair);
        if (pair - amt < 1 ether && pair - amt != 0) amt = pair; // respect minimalDeposit remainder

        uint256 beforeDep = IBuildersV4Inv(BUILDERS_V4).usersData(actor, subnet).deposited;
        uint256 beforeBal = IERC20Inv(MOR).balanceOf(actor);
        vm.prank(actor);
        IBuildersV4Inv(BUILDERS_V4).withdraw(subnet, amt);
        uint256 afterDep = IBuildersV4Inv(BUILDERS_V4).usersData(actor, subnet).deposited;
        uint256 afterBal = IERC20Inv(MOR).balanceOf(actor);
        uint256 depDelta = beforeDep - afterDep;
        uint256 received = afterBal - beforeBal;

        actorNet[actor] -= depDelta;
        subnetNet[subnet] -= depDelta;
        pairNet[actor][subnet] -= depDelta;
        netDeposited -= depDelta;
        withdrawnTotal[actor] += received;
        numWithdraws++;
        lastSubnet = subnet;
        lastPairActor = actor;
    }

    function claim(uint256 seed) external {
        if (subnetIds.length == 0) return;
        bytes32 subnet = subnetIds[seed % subnetIds.length];
        address caller = (seed & 1 == 0) ? subnetAdminOf[subnet] : subnetClaimAdminOf[subnet];
        address receiver = actors[seed % 4];

        uint256 beforeBal = IERC20Inv(MOR).balanceOf(receiver);
        vm.prank(caller);
        IBuildersV4Inv(BUILDERS_V4).claim(subnet, receiver);
        uint256 received = IERC20Inv(MOR).balanceOf(receiver) - beforeBal;

        claimedSubnet[subnet] += received;
        totalClaimed += received;
        lastClaimSubnet = subnet;
        lastClaimTime = block.timestamp;
        lastSubnet = subnet;
    }

    function warp(uint256 seed) external {
        uint256 days_ = bound(seed, 1, 30);
        vm.warp(block.timestamp + days_ * DAY);
    }

    function editSubnet(uint256 seed, uint256 lockDays) external {
        if (subnetIds.length == 0) return;
        bytes32 subnet = subnetIds[seed % subnetIds.length];
        address admin = subnetAdminOf[subnet];
        uint256 newLock = bound(lockDays, 7, 90) * DAY;

        SubnetInv memory s = SubnetInv({
            name: subnetNameOf[subnet],
            admin: admin,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: uint128(newLock),
            unused2: 0,
            minimalDeposit: 1 ether,
            claimAdmin: subnetClaimAdminOf[subnet]
        });
        vm.prank(admin);
        IBuildersV4Inv(BUILDERS_V4).editSubnet(subnet, s);
        lastSubnet = subnet;
    }
}

contract BuildersInvariantTest is Test {
    uint256 constant BASE_BLOCK = 56038769;
    address constant BUILDERS_V4 = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    BuildersHandler handler;
    address[4] actors;

    function setUp() public {
        vm.createSelectFork("base", BASE_BLOCK);
        actors = [makeAddr("bActor0"), makeAddr("bActor1"), makeAddr("bActor2"), makeAddr("bActor3")];
        handler = new BuildersHandler(actors);
        for (uint256 i = 0; i < 4; i++) {
            deal(MOR, actors[i], 100_000 ether);
            vm.prank(actors[i]);
            IERC20Inv(MOR).approve(BUILDERS_V4, type(uint256).max);
        }
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = BuildersHandler.createSubnet.selector;
        selectors[1] = BuildersHandler.deposit.selector;
        selectors[2] = BuildersHandler.withdraw.selector;
        selectors[3] = BuildersHandler.claim.selector;
        selectors[4] = BuildersHandler.warp.selector;
        selectors[5] = BuildersHandler.editSubnet.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_B1_totalDeposited() public view {
        (,, uint256 total,) = IBuildersV4Inv(BUILDERS_V4).allSubnetsData();
        assertEq(total, handler.setupTotalDeposited() + handler.netDeposited(), "B1 totalDeposited");
    }

    function invariant_B2_lastSubnetDeposited() public view {
        bytes32 id = handler.lastSubnet();
        if (id == bytes32(0)) return;
        uint256 dep = IBuildersV4Inv(BUILDERS_V4).subnetsData(id).deposited;
        assertEq(dep, handler.subnetNet(id), "B2 subnet deposited");
    }

    function invariant_B3_balance() public view {
        uint256 bal = IERC20Inv(MOR).balanceOf(BUILDERS_V4);
        assertEq(bal, handler.setupBalance() + handler.netDeposited(), "B3 MOR balance");
    }

    function invariant_B4_claimedBounded() public view {
        (uint256 dist,,, ) = IBuildersV4Inv(BUILDERS_V4).allSubnetsDataV4();
        (,, uint256 claimed,) = IBuildersV4Inv(BUILDERS_V4).allSubnetsDataV4();
        assertLe(claimed, dist, "B4 claimed <= distributed");
    }

    function invariant_B5_globalViewNoUnderflow() public view {
        // The view reverts with panic 0x11 if claimed > distributed +
        // current accrual; the call itself is the check.
        uint256 g = IBuildersV4Inv(BUILDERS_V4).getCurrentSubnetsRewards();
        assertGe(g, 0, "B5 global view");
    }

    function invariant_B6_lastSubnetPendingSubset() public view {
        bytes32 id = handler.lastSubnet();
        if (id == bytes32(0)) return;
        uint256 sub = IBuildersV4Inv(BUILDERS_V4).getCurrentSubnetRewards(id);
        uint256 glob = IBuildersV4Inv(BUILDERS_V4).getCurrentSubnetsRewards();
        assertLe(sub, glob, "B6 subnet pending <= global pending");
    }

    function invariant_B7_rateMonotonic() public view {
        (, uint256 rate,,) = IBuildersV4Inv(BUILDERS_V4).allSubnetsData();
        assertGe(rate, handler.setupRate(), "B7 rate monotonic");
    }

    function invariant_B8_lastPairLedger() public view {
        bytes32 id = handler.lastSubnet();
        address actor = handler.lastPairActor();
        if (id == bytes32(0) || actor == address(0)) return;
        uint256 dep = IBuildersV4Inv(BUILDERS_V4).usersData(actor, id).deposited;
        assertEq(dep, handler.pairNet(actor, id), "B8 pair deposited");
    }

    function invariant_B9_claimResetsPending() public view {
        bytes32 id = handler.lastClaimSubnet();
        if (id == bytes32(0)) return;
        if (block.timestamp != handler.lastClaimTime()) return;
        uint256 pending = IBuildersV4Inv(BUILDERS_V4).subnetsData(id).pendingRewards;
        assertEq(pending, 0, "B9 pending reset after claim");
    }

    function invariant_B10_withdrawExact() public view {
        for (uint256 i = 0; i < 4; i++) {
            address actor = actors[i];
            uint256 debited = handler.stakedTotal(actor) - handler.actorNet(actor);
            uint256 paid = handler.withdrawnTotal(actor);
            assertLe(paid, debited, "B10 never overpaid");
            assertLe(debited - paid, handler.numWithdraws(), "B10 shortfall <= 1 wei/withdraw");
        }
    }

    function invariant_B11_claimedReceivedBounded() public view {
        (,, uint256 claimed,) = IBuildersV4Inv(BUILDERS_V4).allSubnetsDataV4();
        assertLe(handler.totalClaimed(), claimed - handler.setupClaimed(), "B11 received <= claimed delta");
    }
}
