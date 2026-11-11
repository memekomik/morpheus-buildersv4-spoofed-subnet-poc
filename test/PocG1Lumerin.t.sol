// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import "./PocD3Lumerin.t.sol";

/// @title Fase 3 Gap G1 — Lumerin claimForProvider underflow variants (Base)
/// @notice Inherits the proven D3 harness (Base fork 56038769, provider +
///         model registered in setUp). The session USER (userA) plays the
///         attacker throughout: closeSession only accepts the session user
///         (delegatee check), so a late close can only be forced by the user
///         themselves — the question is whether the provider's loss from it
///         can ever become permanent.
contract PocG1LumerinTest is PocD3LumerinTest {
    // ---- G1-V4: attacker-user forces a late close; provider claim must
    // revert only until the next UTC midnight, then pay in full. DEAD
    // (temporary delay, no permanent loss) if the post-midnight claim
    // pays the exact entitlement. ----
    // OUTCOME (verified by this test): the provider is in fact paid in FULL
    // AT CLOSE — _rewardProviderAfterClose only subtracts the hold on an
    // EARLY dispute close, and a late close (isClosingLate_) pays the full
    // entitlement immediately. The reverting claim is therefore a pure
    // nuisance: there is nothing left to pay, before midnight or after.
    function test_G1_ForcedLateClose_HealsAtMidnight() public {
        bytes32 bidId = _postBid();
        uint256 amount = _stakeForDuration(4 hours);
        bytes32 sessionId = _openAs(userA, amount, bidId);
        Session memory s = diamond.getSession(sessionId);
        uint256 entitlement = (s.endsAt - s.openedAt) * PRICE;

        // Attacker (the user) deliberately closes LATE with a valid receipt.
        vm.warp(s.endsAt + 1 hours);
        (bytes memory receipt, bytes memory sig) = _signReceipt(sessionId, providerPk);
        uint256 provBeforeClose = IERC20(MOR).balanceOf(provider);
        vm.prank(userA);
        diamond.closeSession(receipt, sig);
        Session memory closed = diamond.getSession(sessionId);
        assertGt(closed.closedAt, s.endsAt);
        // Provider paid in FULL at close (not delayed to a later claim).
        assertEq(
            IERC20(MOR).balanceOf(provider) - provBeforeClose,
            entitlement,
            "late close must pay the provider in full at close"
        );

        // The later claim reverts (the known underflow: 0 - hold) ...
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        diamond.claimForProvider(sessionId);

        // ...but after the next UTC midnight it is a clean no-op — nothing
        // was ever owed, so nothing is lost.
        vm.warp(diamond.startOfTheDay(closed.closedAt) + 1 days + 1);
        uint256 provBefore = IERC20(MOR).balanceOf(provider);
        vm.prank(provider);
        diamond.claimForProvider(sessionId);
        assertEq(IERC20(MOR).balanceOf(provider), provBefore, "post-midnight claim must be a no-op");
        assertEq(provBefore, provBeforeClose + entitlement);
    }

    // ---- G1-V5: extreme lateness — 1h session closed 3 DAYS after endsAt.
    // Hold ((closedAt - startOfClosedAt) * price) dwarfs the entitlement, so
    // the underflow is at its worst. Still must heal at midnight. ----
    // OUTCOME: same as G1-V4 — the provider is paid in full AT CLOSE even
    // for a 3-day-late close, so the reverting claim loses nothing.
    function test_G1_LateCloseDaysLate_HealsAtMidnight() public {
        bytes32 bidId = _postBid();
        uint256 amount = _stakeForDuration(1 hours);
        bytes32 sessionId = _openAs(userA, amount, bidId);
        Session memory s = diamond.getSession(sessionId);
        uint256 entitlement = (s.endsAt - s.openedAt) * PRICE;

        vm.warp(s.endsAt + 3 days);
        (bytes memory receipt, bytes memory sig) = _signReceipt(sessionId, providerPk);
        uint256 provBeforeClose = IERC20(MOR).balanceOf(provider);
        vm.prank(userA);
        diamond.closeSession(receipt, sig);
        Session memory closed = diamond.getSession(sessionId);
        assertEq(
            IERC20(MOR).balanceOf(provider) - provBeforeClose,
            entitlement,
            "3-day-late close must still pay the provider in full at close"
        );

        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        diamond.claimForProvider(sessionId);

        vm.warp(diamond.startOfTheDay(closed.closedAt) + 1 days + 1);
        uint256 provBefore = IERC20(MOR).balanceOf(provider);
        vm.prank(provider);
        diamond.claimForProvider(sessionId);
        assertEq(IERC20(MOR).balanceOf(provider), provBefore, "post-midnight claim must be a no-op");
    }

    // ---- G1-V6: late DISPUTE close (self-signed receipt). The provider is
    // paid in full AT close (isClosingLate_ skips the hold), so a later
    // claim must underflow (0 - hold) pre-midnight and be a no-op after. ----
    function test_G1_LateDisputeClose_HealsAtMidnight() public {
        bytes32 bidId = _postBid();
        uint256 amount = _stakeForDuration(4 hours);
        bytes32 sessionId = _openAs(userA, amount, bidId);
        Session memory s = diamond.getSession(sessionId);
        uint256 entitlement = (s.endsAt - s.openedAt) * PRICE;

        vm.warp(s.endsAt + 2 hours);
        (bytes memory receipt, bytes memory sig) = _signReceipt(sessionId, userAPk); // self-signed -> dispute
        uint256 provBefore = IERC20(MOR).balanceOf(provider);
        vm.prank(userA);
        diamond.closeSession(receipt, sig);
        Session memory closed = diamond.getSession(sessionId);
        assertEq(closed.closeoutType, 1, "must be a dispute close");
        assertEq(
            IERC20(MOR).balanceOf(provider) - provBefore,
            entitlement,
            "late dispute close pays the provider in full at close"
        );

        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        diamond.claimForProvider(sessionId);

        vm.warp(diamond.startOfTheDay(closed.closedAt) + 1 days + 1);
        uint256 provMid = IERC20(MOR).balanceOf(provider);
        vm.prank(provider);
        diamond.claimForProvider(sessionId);
        assertEq(IERC20(MOR).balanceOf(provider), provMid, "post-midnight claim must be a no-op");
    }

    // ---- G1-V7: three late closes stacked — no hold stacking past midnight. ----
    // OUTCOME: each provider payment lands AT its close (per-close deltas
    // equal the entitlements exactly); the three post-midnight claims are
    // all no-ops. No stacking, no loss. (Note: the provider's overall
    // balance also moves by the 0.3 MOR postModelBid fee per bid, so the
    // per-close delta — not the overall balance — is the right assertion.)
    function test_G1_ThreeLateCloses_AllHeal() public {
        uint256 totalEntitlement;
        bytes32[3] memory ids;
        for (uint256 i = 0; i < 3; i++) {
            bytes32 bidId = _postBid();
            uint256 amount = _stakeForDuration(1 hours);
            bytes32 sessionId = _openAs(userA, amount, bidId);
            Session memory s = diamond.getSession(sessionId);
            uint256 entitlement = (s.endsAt - s.openedAt) * PRICE;
            totalEntitlement += entitlement;
            vm.warp(s.endsAt + 30 minutes);
            (bytes memory receipt, bytes memory sig) = _signReceipt(sessionId, providerPk);
            uint256 provBeforeClose = IERC20(MOR).balanceOf(provider);
            vm.prank(userA);
            diamond.closeSession(receipt, sig);
            assertEq(
                IERC20(MOR).balanceOf(provider) - provBeforeClose,
                entitlement,
                "each late close must pay its entitlement at close"
            );
            ids[i] = sessionId;

            vm.prank(provider);
            vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
            diamond.claimForProvider(sessionId);
        }

        // Past the last close's next midnight, every claim is a no-op.
        Session memory last = diamond.getSession(ids[2]);
        vm.warp(diamond.startOfTheDay(last.closedAt) + 1 days + 1);
        uint256 provBefore = IERC20(MOR).balanceOf(provider);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(provider);
            diamond.claimForProvider(ids[i]);
        }
        assertEq(IERC20(MOR).balanceOf(provider), provBefore, "post-midnight claims must all be no-ops");
        assertGt(totalEntitlement, 0);
    }
}
