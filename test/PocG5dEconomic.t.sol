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
    function subnetsData(bytes32 subnetId_)
        external
        view
        returns (uint128, uint256, uint256, uint256, uint256);
    function usersData(address user_, bytes32 subnetId_) external view returns (UserData memory);
    function allSubnetsData() external view returns (uint256, uint256, uint256, uint256);
    function allSubnetsDataV4() external view returns (uint256, uint256, uint256, uint128);
    function minimalWithdrawLockPeriod() external view returns (uint256);
    function networkShare() external view returns (uint256);
    function subnetCreationFeeAmount() external view returns (uint256);
    function feeConfig() external view returns (address);
    function rewardPool() external view returns (address);
    function setNetworkShare(uint256 networkShare_) external;
    function setSubnetCreationFeeAmount(uint256 subnetCreationFeeAmount_) external;
    function getCurrentSubnetRewards(bytes32 subnetId_) external view returns (uint256);
    function getCurrentSubnetsRewards() external view returns (uint256);
}

interface IRewardPoolG5 {
    function getPeriodRewards(uint256 index_, uint128 startTime_, uint128 endTime_) external view returns (uint256);
}

interface IFeeConfigG5 {
    function getFeeAndTreasuryForOperation(address sender_, bytes32 operation_)
        external
        view
        returns (uint256, address);
    function setFee(address sender_, uint256 fee_) external;
    function setFeeForOperation(address sender_, bytes32 operation_, uint256 fee_) external;
    function discardCustomFee(address sender_, bytes32 operation_) external;
    function setTreasury(address treasury_) external;
    function setBaseFee(uint256 baseFee_) external;
    function setBaseFeeForOperation(bytes32 operation_, uint256 baseFeeForOperation_) external;
}

/// @title BuildersV4 — economic and ordering chains (Base fork)
/// @notice Fork PoCs on Base block 56038769. Attacker = fresh unprivileged
///         address; no owner/admin/multisig prank anywhere. Each test asserts
///         the NEGATIVE (no excess extraction) unless a chain actually pays.
contract PocG5dEconomicTest is Test {
    uint256 constant BASE_BLOCK = 56038769;
    address constant BUILDERS_V4 = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    uint256 constant DAY = 86400;
    uint256 constant MIN_LOCK = 604800; // 7 days, live minimalWithdrawLockPeriod
    uint256 constant PRECISION = 1e25;

    bytes32 constant FEE_CLAIM_OPERATION = "claim";
    bytes32 constant FEE_SUBNET_CREATE = "buildersV4.fee.subnet.create";

    address attacker;
    address attacker2;
    address legit;
    address victim1;
    address victim2;
    address victim3;

    function setUp() public {
        vm.createSelectFork("base", BASE_BLOCK);
        attacker = makeAddr("attacker");
        attacker2 = makeAddr("attacker2");
        legit = makeAddr("legitBuilder");
        victim1 = makeAddr("victim1");
        victim2 = makeAddr("victim2");
        victim3 = makeAddr("victim3");
        vm.deal(attacker, 10 ether);
        vm.deal(attacker2, 10 ether);
        vm.deal(legit, 10 ether);
        vm.deal(victim1, 10 ether);
        vm.deal(victim2, 10 ether);
        vm.deal(victim3, 10 ether);
        deal(MOR, attacker, 2_000_000 ether);
        deal(MOR, attacker2, 1_000_000 ether);
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
        return _mkSubnetMin(name, admin, claimAdmin, lock, 1 ether);
    }

    function _mkSubnetMin(string memory name, address admin, address claimAdmin, uint256 lock, uint256 minDeposit)
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
                minimalDeposit: minDeposit,
                claimAdmin: claimAdmin
            });
    }

    function _mkMeta() internal pure returns (SubnetMetadata memory) {
        return SubnetMetadata({slug: "g5d", description: "g5d", website: "https://example.com", image: ""});
    }

    function _create(string memory name, address admin, address claimAdmin, uint256 lock, address caller)
        internal
        returns (bytes32 id)
    {
        id = IBuildersV4G5(BUILDERS_V4).getSubnetId(name);
        vm.prank(caller);
        IBuildersV4G5(BUILDERS_V4).createSubnet(_mkSubnet(name, admin, claimAdmin, lock), _mkMeta());
    }

    function _createMin(string memory name, address admin, address claimAdmin, uint256 lock, uint256 minDeposit, address caller)
        internal
        returns (bytes32 id)
    {
        id = IBuildersV4G5(BUILDERS_V4).getSubnetId(name);
        vm.prank(caller);
        IBuildersV4G5(BUILDERS_V4).createSubnet(_mkSubnetMin(name, admin, claimAdmin, lock, minDeposit), _mkMeta());
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

    function _claim(address who, bytes32 id, address receiver) internal {
        vm.prank(who);
        IBuildersV4G5(BUILDERS_V4).claim(id, receiver);
    }

    function _pending(bytes32 id) internal view returns (uint256) {
        return IBuildersV4G5(BUILDERS_V4).getCurrentSubnetRewards(id);
    }

    function _rate() internal view returns (uint256) {
        (, uint256 rate,,) = IBuildersV4G5(BUILDERS_V4).allSubnetsData();
        return rate;
    }

    function _totalDeposited() internal view returns (uint256) {
        (,, uint256 total,) = IBuildersV4G5(BUILDERS_V4).allSubnetsData();
        return total;
    }

    function _lastUpdate() internal view returns (uint128) {
        (,,, uint128 lastUpdate) = IBuildersV4G5(BUILDERS_V4).allSubnetsDataV4();
        return lastUpdate;
    }

    /// @notice Builder-bucket emissions over [from_, to_] at live networkShare.
    function _emissions(uint128 from_, uint128 to_) internal view returns (uint256) {
        address rp = IBuildersV4G5(BUILDERS_V4).rewardPool();
        uint256 raw = IRewardPoolG5(rp).getPeriodRewards(3, from_, to_);
        return (raw * IBuildersV4G5(BUILDERS_V4).networkShare()) / PRECISION;
    }

    /// @notice 30-day Builder-bucket emissions from `from_` at live networkShare.
    function _emissions30d(uint128 from_) internal view returns (uint256) {
        return _emissions(from_, from_ + uint128(30 days));
    }

    // ------------------------------------------------------------------
    // (1) Share dilution: attacker self-stakes 1M MOR in their own subnet.
    // Pro-rata identity must hold exactly; any premium over the per-MOR
    // rate would be excess extraction. Dilution of the legit subnet is
    // measured against the no-attacker counterfactual.
    // ------------------------------------------------------------------
    function test_G5d_DilutionIsProRata_NoExcess() public {
        uint256 d0 = _totalDeposited();
        uint128 t0 = uint128(block.timestamp);
        uint256 e30 = _emissions30d(t0);
        emit log_named_uint("live totalDeposited (MOR)", d0 / 1 ether);
        emit log_named_uint("30d Builder emissions (MOR)", e30 / 1 ether);
        emit log_named_uint("live networkShare (1e25=100%)", IBuildersV4G5(BUILDERS_V4).networkShare());

        bytes32 legitId = _create("G5dLegit", legit, legit, MIN_LOCK, legit);
        _deposit(victim1, legitId, 50_000 ether);
        _deposit(victim2, legitId, 30_000 ether);
        _deposit(victim3, legitId, 20_000 ether);

        bytes32 atkId = _create("G5dAttacker", attacker, attacker, MIN_LOCK, attacker);
        _deposit(attacker, atkId, 1_000_000 ether);

        vm.warp(block.timestamp + 30 days);

        uint256 pendingLegit = _pending(legitId);
        uint256 pendingAtk = _pending(atkId);
        emit log_named_uint("legit pending 30d (MOR)", pendingLegit / 1 ether);
        emit log_named_uint("attacker pending 30d (MOR)", pendingAtk / 1 ether);

        // Pro-rata identity: attacker staked 10x the legit subnet, so its
        // pending must be 10x (within 0.2% rounding).
        assertApproxEqRel(pendingAtk, pendingLegit * 10, 0.002e18);

        // Both must match the schedule formula (no premium anywhere).
        uint256 denom = d0 + 1_100_000 ether;
        assertApproxEqRel(pendingLegit, (e30 * 100_000 ether) / denom, 0.01e18);
        assertApproxEqRel(pendingAtk, (e30 * 1_000_000 ether) / denom, 0.01e18);

        // Dilution: what the legit subnet WOULD have earned without the
        // attacker, vs what it actually earns.
        uint256 legitWithout = (e30 * 100_000 ether) / d0;
        uint256 dilutionBps = ((legitWithout - pendingLegit) * 10_000) / legitWithout;
        emit log_named_uint("legit yield without attacker (MOR)", legitWithout / 1 ether);
        emit log_named_uint("dilution of legit yield (bps)", dilutionBps);
        // Dilution must equal exactly 1 - D0/(D0+1.1M): mechanical pro-rata.
        uint256 dilutionExpectedBps = (1_100_000 ether * 10_000) / denom;
        assertApproxEqRel(dilutionBps, dilutionExpectedBps, 0.01e18);

        // Actually claim both: received must equal pending (fee is 0 live),
        // and per-MOR yield must be identical.
        uint256 legitBefore = IERC20M(MOR).balanceOf(legit);
        uint256 atkBefore = IERC20M(MOR).balanceOf(attacker);
        _claim(legit, legitId, legit);
        _claim(attacker, atkId, attacker);
        uint256 legitGot = IERC20M(MOR).balanceOf(legit) - legitBefore;
        uint256 atkGot = IERC20M(MOR).balanceOf(attacker) - atkBefore;
        assertEq(legitGot, pendingLegit, "legit claim must equal pending (fee 0)");
        assertEq(atkGot, pendingAtk, "attacker claim must equal pending (fee 0)");
        // Same yield per MOR staked: attacker earns NOTHING above the
        // honest-builder rate on their own capital.
        assertApproxEqRel(atkGot * 100_000 ether, legitGot * 1_000_000 ether, 0.002e18);
    }

    // ------------------------------------------------------------------
    // (2) Rate manipulation: 50 fresh subnets + lock edits to max must not
    // move the global rate, totalDeposited, lastUpdate, or any control
    // subnet's pending. Owner-only rate knobs must reject the attacker.
    // ------------------------------------------------------------------
    function test_G5d_RateUnaffectedBySubnetSpamAndLockEdits() public {
        uint128 t0 = uint128(block.timestamp);
        bytes32 controlId = _create("G5dControl", legit, legit, MIN_LOCK, legit);
        _deposit(victim1, controlId, 100_000 ether);

        uint256 r0 = _rate();
        uint256 d0 = _totalDeposited();
        uint128 lu0 = _lastUpdate();
        uint256 p0 = _pending(controlId);

        // Spam: 50 fresh subnets, locks edited to the max, metadata edited.
        for (uint256 i = 0; i < 50; i++) {
            string memory name = string(abi.encodePacked("G5dSpam", vm.toString(i)));
            bytes32 id = _create(name, attacker, attacker, MIN_LOCK, attacker);
            vm.prank(attacker);
            IBuildersV4G5(BUILDERS_V4).editSubnet(
                id, _mkSubnet(name, attacker, attacker, uint256(type(uint128).max) / 2)
            );
        }
        assertEq(_rate(), r0, "rate must not move on subnet spam");
        assertEq(_totalDeposited(), d0, "totalDeposited must not move on subnet spam");
        assertEq(_lastUpdate(), lu0, "lastUpdate must not move on subnet spam");
        assertEq(_pending(controlId), p0, "control pending must not move on subnet spam");

        // Lock edit on a subnet WITH deposits must not touch its stored
        // rate / pendingRewards either (editSubnet never calls _updatePoolData).
        bytes32 atkId = _create("G5dLockVictim", attacker, attacker, MIN_LOCK, attacker);
        _deposit(attacker, atkId, 10_000 ether);
        vm.warp(block.timestamp + 1 days);
        (,,, uint256 rateBefore, uint256 pendingBefore) = IBuildersV4G5(BUILDERS_V4).subnetsData(atkId);
        vm.prank(attacker);
        IBuildersV4G5(BUILDERS_V4).editSubnet(
            atkId, _mkSubnet("G5dLockVictim", attacker, attacker, uint256(type(uint128).max) / 2)
        );
        (,,, uint256 rateAfter, uint256 pendingAfter) = IBuildersV4G5(BUILDERS_V4).subnetsData(atkId);
        assertEq(rateAfter, rateBefore, "editSubnet must not touch stored rate");
        assertEq(pendingAfter, pendingBefore, "editSubnet must not touch stored pending");

        // Owner-only rate knobs reject the attacker.
        vm.prank(attacker);
        vm.expectRevert();
        IBuildersV4G5(BUILDERS_V4).setNetworkShare(PRECISION);
        vm.prank(attacker);
        vm.expectRevert();
        IBuildersV4G5(BUILDERS_V4).setSubnetCreationFeeAmount(1 ether);

        // After 30 more days the control subnet earns exactly the pro-rata
        // schedule share over the FULL window since its deposit (the 1-day
        // pre-spam window included). Note d0 already includes the control's
        // 100k, so the denominator only adds the attacker's 10k.
        uint256 eTotal = _emissions(t0, uint128(block.timestamp) + uint128(30 days));
        vm.warp(block.timestamp + 30 days);
        uint256 denom = d0 + 10_000 ether; // d0 already has control 100k
        assertApproxEqRel(_pending(controlId), (eTotal * 100_000 ether) / denom, 0.01e18);
    }

    // ------------------------------------------------------------------
    // (3) Lookalike first-mover: creating the lookalike BEFORE the real
    // subnet must confer no ordering premium; an empty subnet accrues no
    // retroactive rewards; exact-name squatting reverts.
    // ------------------------------------------------------------------
    function test_G5d_LookalikeFirstMoverNoOrderingPremium() public {
        // Attacker first: lookalike exists before the real subnet.
        bytes32 proId = _create("G5dRealBuilderPro", attacker, attacker, MIN_LOCK, attacker);
        bytes32 realId = _create("G5dRealBuilder", legit, legit, MIN_LOCK, legit);
        _deposit(victim1, proId, 50_000 ether);
        _deposit(victim2, proId, 50_000 ether);
        _deposit(victim1, realId, 50_000 ether);
        _deposit(victim2, realId, 50_000 ether);

        vm.warp(block.timestamp + 30 days);
        uint256 pendingPro = _pending(proId);
        uint256 pendingReal = _pending(realId);
        emit log_named_uint("lookalike pending 30d (MOR)", pendingPro / 1 ether);
        emit log_named_uint("real pending 30d (MOR)", pendingReal / 1 ether);
        // Equal deposits, equal time: identical yield. No first-mover premium.
        assertApproxEqRel(pendingPro, pendingReal, 0.001e18);

        // Empty-period check: a subnet with no deposits for 30 days, then
        // funded, must earn exactly what a fresh subnet funded at the same
        // moment earns (no retroactive rewards for the empty period).
        bytes32 ghostId = _create("G5dGhost", attacker, attacker, MIN_LOCK, attacker);
        vm.warp(block.timestamp + 30 days);
        _deposit(victim3, ghostId, 100_000 ether);
        bytes32 freshId = _create("G5dFresh", legit, legit, MIN_LOCK, legit);
        _deposit(legit, freshId, 100_000 ether);
        vm.warp(block.timestamp + 30 days);
        assertApproxEqRel(_pending(ghostId), _pending(freshId), 0.001e18);

        // Exact-name squatting still reverts.
        vm.prank(attacker);
        vm.expectRevert("BU: the Subnet already exist (1)");
        IBuildersV4G5(BUILDERS_V4).createSubnet(_mkSubnet("G5dRealBuilder", attacker, attacker, MIN_LOCK), _mkMeta());
    }

    // ------------------------------------------------------------------
    // (4) Deposit-claim-withdraw sequencing: a non-admin staker's yield
    // goes to the admin, never to the staker; same-block deposit+claim
    // yields nothing; splitting stake across N subnets earns the same
    // total as concentrating it in one.
    // ------------------------------------------------------------------
    function test_G5d_ClaimPaysAdminOnly_AttackerStakeYieldsToAdmin() public {
        uint256 d0 = _totalDeposited();
        uint128 t0 = uint128(block.timestamp);
        uint256 e30 = _emissions30d(t0);

        bytes32 legitId = _create("G5dYieldSink", legit, legit, MIN_LOCK, legit);
        _deposit(victim1, legitId, 50_000 ether);
        _deposit(victim2, legitId, 50_000 ether);
        _deposit(attacker, legitId, 10_000 ether); // attacker is a mere staker here

        vm.warp(block.timestamp + 30 days);

        // Non-admin cannot claim at all.
        vm.prank(attacker);
        vm.expectRevert("BU: invalid caller");
        IBuildersV4G5(BUILDERS_V4).claim(legitId, attacker);

        // The admin claims the yield on ALL 110k stake, including the
        // yield generated by the attacker's 10k.
        uint256 pending = _pending(legitId);
        uint256 legitBefore = IERC20M(MOR).balanceOf(legit);
        _claim(legit, legitId, legit);
        uint256 legitGot = IERC20M(MOR).balanceOf(legit) - legitBefore;
        assertEq(legitGot, pending, "admin claim must equal pending");
        assertApproxEqRel(legitGot, (e30 * 110_000 ether) / (d0 + 110_000 ether), 0.01e18);
        emit log_named_uint("admin claimed incl. attacker-stake yield (MOR)", legitGot / 1 ether);
        emit log_named_uint("of which generated by attacker 10k (MOR)", (legitGot * 10_000 ether) / (110_000 ether) / 1 ether);

        // Attacker withdraws principal after the lock: exactly 10k back,
        // zero yield. Their stake earned the admin money, not them.
        uint256 atkBefore = IERC20M(MOR).balanceOf(attacker);
        _withdraw(attacker, legitId, 10_000 ether);
        assertEq(IERC20M(MOR).balanceOf(attacker) - atkBefore, 10_000 ether);

        // Same-block flash: deposit + immediate claim yields nothing.
        bytes32 flashId = _create("G5dFlash", attacker, attacker, MIN_LOCK, attacker);
        _deposit(attacker, flashId, 100_000 ether);
        vm.prank(attacker);
        vm.expectRevert("BU: nothing to claim");
        IBuildersV4G5(BUILDERS_V4).claim(flashId, attacker);
    }

    function test_G5d_SplitVsConcentrateSameYield() public {
        uint256 d0 = _totalDeposited();
        uint128 t0 = uint128(block.timestamp);
        uint256 e30 = _emissions30d(t0);

        // Attacker splits 100k across 10 own subnets.
        bytes32[10] memory splitIds;
        for (uint256 i = 0; i < 10; i++) {
            string memory name = string(abi.encodePacked("G5dSplit", vm.toString(i)));
            splitIds[i] = _create(name, attacker, attacker, MIN_LOCK, attacker);
            _deposit(attacker, splitIds[i], 10_000 ether);
        }
        // Attacker2 concentrates 100k in one subnet.
        bytes32 oneId = _create("G5dOne", attacker2, attacker2, MIN_LOCK, attacker2);
        _deposit(attacker2, oneId, 100_000 ether);

        vm.warp(block.timestamp + 30 days);

        uint256 splitTotal;
        for (uint256 i = 0; i < 10; i++) {
            splitTotal += _pending(splitIds[i]);
        }
        uint256 oneTotal = _pending(oneId);
        emit log_named_uint("split 10x10k pending (MOR)", splitTotal / 1 ether);
        emit log_named_uint("concentrated 100k pending (MOR)", oneTotal / 1 ether);
        // Same stake, same time: identical total. Subnet multiplication
        // earns nothing extra.
        assertApproxEqRel(splitTotal, oneTotal, 0.001e18);
        assertApproxEqRel(oneTotal, (e30 * 100_000 ether) / (d0 + 200_000 ether), 0.01e18);
    }

    // ------------------------------------------------------------------
    // (5) FeeConfig: live claim fee is 0; every fee setter is owner-only
    // and rejects the attacker; a claim pays the receiver the full
    // pending (fee taken = 0).
    // ------------------------------------------------------------------
    function test_G5d_FeeConfigAttackerCannotTouch() public {
        address feeConfig = IBuildersV4G5(BUILDERS_V4).feeConfig();
        (uint256 claimFee, address claimTreasury) = IFeeConfigG5(feeConfig).getFeeAndTreasuryForOperation(
            BUILDERS_V4, FEE_CLAIM_OPERATION
        );
        (uint256 createFee,) = IFeeConfigG5(feeConfig).getFeeAndTreasuryForOperation(
            BUILDERS_V4, FEE_SUBNET_CREATE
        );
        emit log_named_uint("live claim fee (1e25=100%)", claimFee);
        emit log_named_uint("live subnet-create fee (MOR wei)", createFee);
        assertEq(claimFee, 0, "live claim fee must be 0");
        assertEq(IBuildersV4G5(BUILDERS_V4).subnetCreationFeeAmount(), 0, "live creation fee must be 0");
        assertTrue(claimTreasury != attacker, "fee treasury must not be the attacker");

        // Every fee setter is owner-only: attacker reverts on all of them.
        vm.prank(attacker);
        vm.expectRevert();
        IFeeConfigG5(feeConfig).setFee(attacker, 0);
        vm.prank(attacker);
        vm.expectRevert();
        IFeeConfigG5(feeConfig).setFeeForOperation(BUILDERS_V4, FEE_CLAIM_OPERATION, 0);
        vm.prank(attacker);
        vm.expectRevert();
        IFeeConfigG5(feeConfig).discardCustomFee(BUILDERS_V4, FEE_CLAIM_OPERATION);
        vm.prank(attacker);
        vm.expectRevert();
        IFeeConfigG5(feeConfig).setTreasury(attacker);
        vm.prank(attacker);
        vm.expectRevert();
        IFeeConfigG5(feeConfig).setBaseFee(0);
        vm.prank(attacker);
        vm.expectRevert();
        IFeeConfigG5(feeConfig).setBaseFeeForOperation(FEE_CLAIM_OPERATION, 0);

        // A real claim pays the full pending: fee taken is exactly 0.
        bytes32 id = _create("G5dFeeCheck", legit, legit, MIN_LOCK, legit);
        _deposit(victim1, id, 100_000 ether);
        vm.warp(block.timestamp + 30 days);
        uint256 pending = _pending(id);
        uint256 legitBefore = IERC20M(MOR).balanceOf(legit);
        _claim(legit, id, legit);
        assertEq(IERC20M(MOR).balanceOf(legit) - legitBefore, pending, "claim must pay full pending, fee 0");
    }

    // ------------------------------------------------------------------
    // (6) Rounding dust: 1-wei deposits across 20 fresh subnets accrue
    // exactly 0 over 30 days (Rounding.Down keeps sub-wei value with the
    // protocol; there is no dust to sweep).
    // ------------------------------------------------------------------
    function test_G5d_DustDepositsEarnNothing() public {
        bytes32[20] memory ids;
        for (uint256 i = 0; i < 20; i++) {
            string memory name = string(abi.encodePacked("G5dDust", vm.toString(i)));
            ids[i] = _createMin(name, attacker, attacker, MIN_LOCK, 1, attacker);
            _deposit(attacker, ids[i], 1);
        }
        vm.warp(block.timestamp + 30 days);
        uint256 total;
        for (uint256 i = 0; i < 20; i++) {
            total += _pending(ids[i]);
        }
        emit log_named_uint("total pending on 20x 1-wei deposits (wei)", total);
        assertEq(total, 0, "1-wei deposits must accrue zero (rounding down)");
    }

    // ------------------------------------------------------------------
    // (7) Schedule measurement: daily Builder-bucket emissions at +0/+7/
    // +14/+21/+29 days, to see whether the bucket is decaying (which
    // would bound the dilution/profit window) or flat.
    // ------------------------------------------------------------------
    function test_G5d_LogScheduleDecay() public {
        uint128 t0 = uint128(block.timestamp);
        emit log_named_uint("day 0-1 emissions (MOR)", _emissions(t0, t0 + uint128(1 days)) / 1 ether);
        emit log_named_uint("day 7-8 emissions (MOR)", _emissions(t0 + uint128(7 days), t0 + uint128(8 days)) / 1 ether);
        emit log_named_uint("day 14-15 emissions (MOR)", _emissions(t0 + uint128(14 days), t0 + uint128(15 days)) / 1 ether);
        emit log_named_uint("day 21-22 emissions (MOR)", _emissions(t0 + uint128(21 days), t0 + uint128(22 days)) / 1 ether);
        emit log_named_uint("day 29-30 emissions (MOR)", _emissions(t0 + uint128(29 days), t0 + uint128(30 days)) / 1 ether);
        emit log_named_uint("30d total emissions (MOR)", _emissions30d(t0) / 1 ether);
        emit log_named_uint("60d total emissions (MOR)", _emissions(t0, t0 + uint128(60 days)) / 1 ether);
        assertGt(_emissions30d(t0), 0, "schedule must still pay");
    }
}
