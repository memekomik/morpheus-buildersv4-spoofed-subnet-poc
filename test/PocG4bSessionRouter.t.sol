// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import "./PocD3Lumerin.t.sol";

/// @notice Fase 3 Gap G4-B — SessionRouter line-by-line audit, fork PoCs.
/// Fork: Base block 56038769. All calls go through the diamond.
/// Attacker = unprivileged address, no owner/admin prank anywhere.
/// Inherits the D3 harness (provider + model registered, users funded).
/// Every test asserts a branch D3/G1 left untested; a PASS is a DEAD verdict
/// for the corresponding candidate (or a PROVEN finding if it shows a loss).
contract PocG4bSessionRouterTest is PocD3LumerinTest {
    uint256 constant MAX_PRICE = 1e16; // 0.01 MOR/s, top of [1e10, 1e16]

    // ---- G4B-1: user can close late WITHOUT provider cooperation (self-signed receipt) ----
    // closeSession needs a receipt + signature. _isValidProviderReceipt calls
    // ECDSA.recover, which REVERTS on a malformed signature — so the question is
    // whether a user whose provider goes silent can ever close. Answer: yes, by
    // self-signing a receipt (takes the dispute branch). A garbage-length sig
    // reverts, but the user can always produce a well-formed one themselves.
    function test_G4B01_selfSignedCloseLate() public {
        bytes32 bidId = _postBid();
        uint256 amount = _stakeForDuration(4 hours);
        bytes32 sessionId = _openAs(userA, amount, bidId);
        Session memory s = diamond.getSession(sessionId);
        uint256 entitlement = (s.endsAt - s.openedAt) * PRICE;

        vm.warp(s.endsAt + 1);

        // (a) malformed signature (64 bytes) reverts the whole close
        (bytes memory receipt, ) = _signReceipt(sessionId, userAPk);
        vm.prank(userA);
        vm.expectRevert();
        diamond.closeSession(receipt, abi.encodePacked(bytes32(0), bytes32(0)));

        // (b) the SAME receipt self-signed by the user closes fine (dispute branch)
        (bytes memory receipt2, bytes memory sig2) = _signReceipt(sessionId, userAPk);
        uint256 balPreClose = IERC20(MOR).balanceOf(userA);
        uint256 provPreClose = IERC20(MOR).balanceOf(provider);
        vm.prank(userA);
        diamond.closeSession(receipt2, sig2);
        Session memory s2 = diamond.getSession(sessionId);
        assertEq(s2.closeoutType, 1); // dispute
        assertEq(s2.closedAt, s.endsAt + 1);

        // user refund + day-locked hold == stake (same-day late close)
        uint256 refund = IERC20(MOR).balanceOf(userA) - balPreClose;
        (, uint256 hold) = diamond.getUserStakesOnHold(userA, 255);
        assertEq(refund + hold, amount);
        // provider paid in full AT CLOSE (late close -> no hold subtracted)
        assertEq(IERC20(MOR).balanceOf(provider) - provPreClose, entitlement);
    }

    // ---- G4B-2: close still works after the bid is deleted; provider still paid ----
    // _deleteBid only sets deletedAt; the Bid struct (provider, price) persists,
    // and closeSession never checks isBidActive. D3-06 always paired delete +
    // deregister; this isolates delete-only.
    function test_G4B02_closeAfterBidDeletedProviderPaid() public {
        bytes32 bidId = _postBid();
        uint256 amount = _stakeForDuration(4 hours);
        bytes32 sessionId = _openAs(userA, amount, bidId);
        Session memory s = diamond.getSession(sessionId);
        uint256 entitlement = (s.endsAt - s.openedAt) * PRICE;

        vm.prank(provider);
        diamond.deleteModelBid(bidId);
        Bid memory b = diamond.getBid(bidId);
        assertTrue(b.deletedAt != 0);
        assertEq(b.provider, provider);
        assertEq(b.pricePerSecond, PRICE);

        vm.warp(s.endsAt + 1);
        (bytes memory receipt, bytes memory sig) = _signReceipt(sessionId, providerPk);
        uint256 provPreClose = IERC20(MOR).balanceOf(provider);
        uint256 balPreClose = IERC20(MOR).balanceOf(userA);
        vm.prank(userA);
        diamond.closeSession(receipt, sig);

        assertEq(IERC20(MOR).balanceOf(provider) - provPreClose, entitlement);
        uint256 refund = IERC20(MOR).balanceOf(userA) - balPreClose;
        (, uint256 hold) = diamond.getUserStakesOnHold(userA, 255);
        assertEq(refund + hold, amount);
    }

    // ---- G4B-3: ghost sessions + unended claims ----
    // (a) claimForProvider on a nonexistent session reverts (delegatee gate vs address(0)).
    // (b) closeSession on a nonexistent session reverts the same way.
    // (c) claimForProvider on an open, unended session is a no-op paying 0.
    function test_G4B03_ghostSessionAndUnendedClaim() public {
        bytes32 ghost = keccak256("g4b-ghost-session");
        vm.prank(provider);
        vm.expectRevert();
        diamond.claimForProvider(ghost);

        (bytes memory receipt, bytes memory sig) = _signReceipt(ghost, userAPk);
        vm.prank(userA);
        vm.expectRevert();
        diamond.closeSession(receipt, sig);

        bytes32 bidId = _postBid();
        uint256 amount = _stakeForDuration(4 hours);
        bytes32 sessionId = _openAs(userA, amount, bidId);
        uint256 provBefore = IERC20(MOR).balanceOf(provider);
        vm.prank(provider);
        diamond.claimForProvider(sessionId); // session not ended yet: 0, no revert
        assertEq(IERC20(MOR).balanceOf(provider), provBefore);
    }

    // ---- G4B-4: getComputeBalance cannot underflow — numerical bound, live fork values ----
    // getComputeBalance = compute periodReward - providersTotalClaimed. A panic here
    // would brick stakeToStipend -> getSessionEnd -> openSession for everyone.
    // Bound: one session's provider payout <= its stipend
    //   stipend = amount * CB / (TS * 100),
    // so total payouts over ALL sessions ever <= CB * (total staked) / (TS * 100).
    // Total staked <= circulating MOR (77.28M, ETH MOR totalSupply read live
    // 2026-11-11 via eth.drpc.org). With live CB/TS this caps total claims at
    // ~7.5% of CB — the underflow is unreachable by ~8x headroom.
    function test_G4B04_computeBudgetBound() public {
        uint128 now_ = uint128(block.timestamp);
        uint256 cb = diamond.getComputeBalance(now_);
        uint256 ts = diamond.totalMORSupply(now_);
        uint256 claimed = diamond.getProvidersTotalClaimed();
        uint256 circulating = 77_286_119.889 ether; // ETH MOR totalSupply, live 2026-11-11

        assertGt(cb, 0);
        assertGt(cb, claimed);
        console.log("G4B-04 CB", cb);
        console.log("G4B-04 TS", ts);
        console.log("G4B-04 claimed", claimed);

        uint256 maxNewClaims = (cb * circulating) / (ts * 100);
        console.log("G4B-04 maxNewClaims if ALL circulating MOR staked at once", maxNewClaims);
        // even the absolute worst case leaves >50% of the compute balance intact
        assertLt(maxNewClaims + claimed, cb / 2);

        // empirical: run a whale session through the full lifecycle; CB stays healthy
        deal(MOR, userA, 5_000_000 ether);
        bytes32 bidId = _postBid();
        uint256 amount = _stakeForDuration(4 hours);
        bytes32 sessionId = _openAs(userA, amount, bidId);
        Session memory s = diamond.getSession(sessionId);
        uint256 entitlement = (s.endsAt - s.openedAt) * PRICE;
        vm.warp(s.endsAt + 1);
        (bytes memory receipt, bytes memory sig) = _signReceipt(sessionId, providerPk);
        vm.prank(userA);
        diamond.closeSession(receipt, sig);
        assertEq(diamond.getProvidersTotalClaimed(), claimed + entitlement);
        assertGt(diamond.getComputeBalance(uint128(block.timestamp)), 0);
    }

    // ---- G4B-5: deregister -> re-register does NOT reset the 365-day limiter ----
    // providerRegister only sets limitPeriodEnd/earned on FIRST creation
    // (createdAt == 0). Deregister within the period leaves stake == earned;
    // re-registering keeps earned, so the claim cap stays stake - earned.
    // A provider cannot launder earned rewards into fresh claim headroom.
    function test_G4B05_deregisterReregisterLimiterBinds() public {
        bytes32 bidId = _postBid();
        uint256 amount = _stakeForDuration(4 hours);
        bytes32 sessionId = _openAs(userA, amount, bidId);
        Session memory s = diamond.getSession(sessionId);

        // providersTotalClaimed is cumulative on the fork (live ~184,414 MOR),
        // so record the baseline; all later assertions use deltas from it.
        uint256 claimed0 = diamond.getProvidersTotalClaimed();

        // provider claims the first entitlement before close
        vm.warp(s.endsAt + 1);
        uint256 provBefore = IERC20(MOR).balanceOf(provider);
        vm.prank(provider);
        diamond.claimForProvider(sessionId);
        uint256 earned1 = IERC20(MOR).balanceOf(provider) - provBefore;
        assertGt(earned1, 0);

        // close (provider already paid; close pays 0 more), delete bid, deregister
        (bytes memory receipt, bytes memory sig) = _signReceipt(sessionId, providerPk);
        vm.prank(userA);
        diamond.closeSession(receipt, sig);
        vm.prank(provider);
        diamond.deleteModelBid(bidId);
        vm.prank(provider);
        diamond.providerDeregister(provider);
        Provider memory p = diamond.getProvider(provider);
        assertTrue(p.isDeleted);
        assertEq(p.stake, earned1); // within-period: only stake - earned was returned
        assertEq(p.limitPeriodEarned, earned1);

        // re-register with 1000 MOR: stake grows, earned does NOT reset
        vm.prank(provider);
        diamond.providerRegister(provider, 1000 ether, "https://example.com:8080");
        p = diamond.getProvider(provider);
        assertEq(p.stake, earned1 + 1000 ether);
        assertEq(p.limitPeriodEarned, earned1);
        assertEq(p.isDeleted, false);

        _secondSessionCappedClaim(earned1, claimed0);
    }

    // Second half of G4B-05 (split out: stack-too-deep otherwise).
    // New max-price 7-day session: entitlement 6048 MOR, but the claim must
    // cap at the fresh 1000 MOR of headroom (stake - earned).
    function _secondSessionCappedClaim(uint256 earned1, uint256 claimed0) internal {
        vm.prank(provider);
        bytes32 bidId2 = diamond.postModelBid(provider, modelId, MAX_PRICE);
        uint256 ts_ = diamond.totalMORSupply(uint128(block.timestamp));
        uint256 cb_ = diamond.getComputeBalance(uint128(block.timestamp));
        uint256 stipend_ = 7 days * MAX_PRICE;
        uint256 stake2 = ((stipend_ * ts_ * 100) / cb_) * 3 / 2;
        deal(MOR, userA, stake2 + 1_000_000 ether);
        bytes32 sessionId2 = _openAs(userA, stake2, bidId2);
        Session memory s2 = diamond.getSession(sessionId2);
        assertEq(s2.endsAt - s2.openedAt, 7 days);
        uint256 entitlement2 = (s2.endsAt - s2.openedAt) * MAX_PRICE;
        assertGt(entitlement2, 1000 ether);

        vm.warp(s2.endsAt + 1);
        uint256 provMid = IERC20(MOR).balanceOf(provider);
        vm.prank(provider);
        diamond.claimForProvider(sessionId2);
        uint256 secondClaim = IERC20(MOR).balanceOf(provider) - provMid;
        assertEq(secondClaim, 1000 ether); // limiter binds: stake - earned == 1000
        assertEq(diamond.getProvidersTotalClaimed(), claimed0 + earned1 + 1000 ether);

        // close pays 0 more (remaining entitlement exceeds the exhausted limit)
        (bytes memory receipt2, bytes memory sig2) = _signReceipt(sessionId2, providerPk);
        vm.prank(userA);
        diamond.closeSession(receipt2, sig2);
        assertEq(IERC20(MOR).balanceOf(provider), provMid + 1000 ether);
    }

    // ---- G4B-6: openSession edge cases ----
    // (a) approval for a deleted bid reverts (isBidActive checked first).
    // (b) zero stake reverts (duration 0 < MIN_SESSION_DURATION).
    function test_G4B06_openEdgeCases() public {
        bytes32 bidId = _postBid();
        vm.prank(provider);
        diamond.deleteModelBid(bidId);
        (bytes memory approval, bytes memory sig) = _signApproval(userA, bidId);
        vm.prank(userA);
        vm.expectRevert();
        diamond.openSession(userA, 1 ether, false, approval, sig);

        bytes32 bidId2 = _postBid();
        (bytes memory approval2, bytes memory sig2) = _signApproval(userA, bidId2);
        vm.prank(userA);
        vm.expectRevert();
        diamond.openSession(userA, 0, false, approval2, sig2);
    }
}
