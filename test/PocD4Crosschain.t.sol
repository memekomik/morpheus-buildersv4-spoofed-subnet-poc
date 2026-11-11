// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

interface IERC20D4 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface IL2MessageReceiverD4 {
    function lzReceive(uint16, bytes memory, uint64, bytes memory) external;
    function nonblockingLzReceive(uint16, bytes memory, bytes memory) external;
    function retryMessage(uint16, bytes memory, uint64, bytes memory) external;
    function failedMessages(uint16, bytes calldata, uint64) external view returns (bytes32);
    function config() external view returns (address gateway, address sender, uint16 senderChainId);
    function rewardToken() external view returns (address);
}

interface IL2TokenReceiverV2D4 {
    function withdrawToken(address, address, uint256) external;
    function withdrawTokenId(address, address, uint256) external;
    function swap(uint256, uint256, uint256, bool) external returns (uint256);
    function editParams(bytes memory, bool) external;
    function collectFees(uint256) external returns (uint256, uint256);
}

interface IDistributorD4 {
    function sendMintMessage(uint256, address, uint256, address) external payable;
}

interface IL1SenderV2D4 {
    function sendMintMessage(address, uint256, address) external payable;
}

interface IMOROFTD4 {
    function mint(address, uint256) external;
}

/// @title Fase 2 Lane D4 — cross-chain messaging + MOR token (DISPROOF tests)
/// @notice Every test here asserts that an unprivileged attacker CANNOT
///         mint MOR or steal funds through the cross-chain surface. A PASS
///         means the attack fails; a FAIL would mean a live hole.
///         Forks pinned (Fase 0/1): ETH 26391516, Arb 523270627, Base 56038769.
///         Attacker = fresh random address, no owner/admin/multisig role.
///
///         Why `vm.prank(gateway)` is legitimate in the L2 tests: on mainnet
///         ANYONE can pay the LZ fee on L1 and have the endpoint deliver a
///         message to L2MessageReceiver — the delivered srcAddress is then
///         the attacker's own address. Pranking the gateway models exactly
///         that delivery; it does NOT model endpoint compromise (the gateway
///         check itself is tested separately in test_D4_1a).
contract PocD4CrosschainTest is Test {
    uint256 constant ETH_BLOCK = 26391516;
    uint256 constant ARB_BLOCK = 523270627;
    uint256 constant BASE_BLOCK = 56038769;

    address constant L2MR = 0xd4a8ECcBe696295e68572A98b1aA70Aa9277d427;
    address constant L2TR_V2 = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant MOR_ARB = 0x092bAaDB7DEf4C3981454dD9c0A0D7FF07bCFc86;
    address constant LZ_ENDPOINT_ARB = 0x3c2269811836af69497E5F486A85D7316753cf62;
    address constant L1_SENDER_V2 = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;

    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant MOR_ETH = 0xcBB8f1BDA10b9696c57E13BC128Fe674769DCEc0;
    address constant MOROFT_BASE = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    address attacker = makeAddr("attacker");
    address user = makeAddr("user");

    function _arbFork() internal {
        vm.createSelectFork("arb", ARB_BLOCK);
    }

    function _ethFork() internal {
        vm.createSelectFork("eth", ETH_BLOCK);
    }

    function _baseFork() internal {
        vm.createSelectFork("base", BASE_BLOCK);
    }

    // ---- H1: L2MessageReceiver ----

    /// @notice Config on-chain: gateway = LZ Endpoint V1 Arb, sender =
    ///         L1SenderV2, senderChainId = 101 (Ethereum). Grounds the tests.
    function test_D4_1_config() public {
        _arbFork();
        (address gateway, address sender, uint16 chainId) = IL2MessageReceiverD4(L2MR).config();
        assertEq(gateway, LZ_ENDPOINT_ARB);
        assertEq(sender, L1_SENDER_V2);
        assertEq(chainId, 101);
        assertEq(IL2MessageReceiverD4(L2MR).rewardToken(), MOR_ARB);
    }

    /// @notice Direct lzReceive from an unprivileged caller reverts:
    ///         gateway check ("L2MR: invalid gateway"). No forged delivery.
    function test_D4_1a_directLzReceiveReverts() public {
        _arbFork();
        bytes memory src = abi.encodePacked(L1_SENDER_V2, L2MR);
        bytes memory payload = abi.encode(user, 1_000_000 ether);
        vm.prank(attacker);
        vm.expectRevert("L2MR: invalid gateway");
        IL2MessageReceiverD4(L2MR).lzReceive(101, src, 1, payload);
        assertEq(IERC20D4(MOR_ARB).balanceOf(attacker), 0);
    }

    /// @notice Direct nonblockingLzReceive reverts: only the contract itself
    ///         may call it ("L2MR: invalid caller").
    function test_D4_1b_directNonblockingReverts() public {
        _arbFork();
        bytes memory src = abi.encodePacked(L1_SENDER_V2, L2MR);
        bytes memory payload = abi.encode(user, 1_000_000 ether);
        vm.prank(attacker);
        vm.expectRevert("L2MR: invalid caller");
        IL2MessageReceiverD4(L2MR).nonblockingLzReceive(101, src, payload);
        assertEq(IERC20D4(MOR_ARB).balanceOf(attacker), 0);
    }

    /// @notice Attacker-delivered LZ message (sender = attacker) is stored
    ///         as failed — and can NEVER mint: retry with altered payload
    ///         reverts on the hash, retry with the original payload reverts
    ///         on the sender check. Attacker MOR balance stays 0.
    function test_D4_1c_attackerMessageCanNeverMint() public {
        _arbFork();
        bytes memory src = abi.encodePacked(attacker, L2MR);
        bytes memory payload = abi.encode(attacker, 1_000_000 ether);
        uint64 nonce = 999;

        // Delivery via the real gateway path (attacker paid LZ fee on L1):
        // sender check fails inside _nonblockingLzReceive -> stored failed.
        vm.prank(LZ_ENDPOINT_ARB);
        IL2MessageReceiverD4(L2MR).lzReceive(101, src, nonce, payload);
        assertEq(
            IL2MessageReceiverD4(L2MR).failedMessages(101, src, nonce),
            keccak256(payload)
        );
        assertEq(IERC20D4(MOR_ARB).balanceOf(attacker), 0);

        // Altered payload -> hash mismatch.
        vm.prank(attacker);
        vm.expectRevert("L2MR: invalid payload");
        IL2MessageReceiverD4(L2MR).retryMessage(101, src, nonce, abi.encode(attacker, 1 ether));

        // Original payload -> sender check fails again (sender != L1SenderV2).
        vm.prank(attacker);
        vm.expectRevert("L2MR: invalid sender address");
        IL2MessageReceiverD4(L2MR).retryMessage(101, src, nonce, payload);

        // Still stored (failed retry rolls back the delete), still 0 minted.
        assertEq(
            IL2MessageReceiverD4(L2MR).failedMessages(101, src, nonce),
            keccak256(payload)
        );
        assertEq(IERC20D4(MOR_ARB).balanceOf(attacker), 0);
    }

    /// @notice POSITIVE CONTROL: a genuine L1SenderV2 message mints exactly
    ///         once to the payload's user (not to the retry caller), and a
    ///         second retry reverts — no double-mint.
    function test_D4_1d_legitMessageMintsOnce() public {
        _arbFork();
        bytes memory src = abi.encodePacked(L1_SENDER_V2, L2MR);
        bytes memory payload = abi.encode(user, 100 ether);
        uint64 nonce = 1000;
        uint256 supplyBefore = IERC20D4(MOR_ARB).totalSupply();

        vm.prank(LZ_ENDPOINT_ARB);
        IL2MessageReceiverD4(L2MR).lzReceive(101, src, nonce, payload);
        assertEq(IERC20D4(MOR_ARB).balanceOf(user), 100 ether);
        assertEq(IERC20D4(MOR_ARB).totalSupply(), supplyBefore + 100 ether);
        assertEq(IL2MessageReceiverD4(L2MR).failedMessages(101, src, nonce), bytes32(0));

        // No stored message -> retry reverts; no second mint.
        vm.prank(attacker);
        vm.expectRevert("L2MR: no stored message");
        IL2MessageReceiverD4(L2MR).retryMessage(101, src, nonce, payload);
        assertEq(IERC20D4(MOR_ARB).balanceOf(user), 100 ether);
        assertEq(IERC20D4(MOR_ARB).balanceOf(attacker), 0);
    }

    // ---- H2: L2TokenReceiverV2 ----

    /// @notice All fund-moving functions are owner-only: attacker calls revert.
    function test_D4_2a_l2TokenReceiverOwnerOnly() public {
        _arbFork();
        vm.prank(attacker);
        vm.expectRevert();
        IL2TokenReceiverV2D4(L2TR_V2).withdrawToken(attacker, MOR_ARB, 1 ether);
        vm.prank(attacker);
        vm.expectRevert();
        IL2TokenReceiverV2D4(L2TR_V2).withdrawTokenId(attacker, MOR_ARB, 1);
        vm.prank(attacker);
        vm.expectRevert();
        IL2TokenReceiverV2D4(L2TR_V2).swap(1 ether, 1, block.timestamp + 1, false);
    }

    /// @notice collectFees is permissionless but can only collect the
    ///         contract's OWN Uniswap positions to itself. It holds 0
    ///         positions on Arbitrum (Lane C / on-chain read), so any call
    ///         reverts and the attacker gains nothing either way.
    function test_D4_2b_collectFeesNoGain() public {
        _arbFork();
        uint256 morBefore = IERC20D4(MOR_ARB).balanceOf(L2TR_V2);
        vm.prank(attacker);
        vm.expectRevert();
        IL2TokenReceiverV2D4(L2TR_V2).collectFees(0);
        assertEq(IERC20D4(MOR_ARB).balanceOf(attacker), 0);
        assertEq(IERC20D4(MOR_ARB).balanceOf(L2TR_V2), morBefore);
    }

    // ---- H3: L1SenderV2 / Distributor.sendMintMessage ----

    /// @notice Distributor.sendMintMessage requires msg.sender to be a
    ///         registered DepositPool ("DR: deposit pool doesn't exist").
    function test_D4_3a_distributorSendMintMessageReverts() public {
        _ethFork();
        vm.prank(attacker);
        vm.expectRevert("DR: deposit pool doesn't exist");
        IDistributorD4(DISTRIBUTOR).sendMintMessage(0, attacker, 1_000_000 ether, attacker);
    }

    /// @notice L1SenderV2.sendMintMessage requires msg.sender == Distributor.
    function test_D4_3b_l1SenderSendMintMessageReverts() public {
        _ethFork();
        vm.prank(attacker);
        vm.expectRevert("L1S: the `msg.sender` isn't `distributor`");
        IL1SenderV2D4(L1_SENDER_V2).sendMintMessage(attacker, 1_000_000 ether, attacker);
    }

    // ---- H4: MOROFT mint allowlist ----

    /// @notice MOROFT.mint is minter-gated on all three chains; the attacker
    ///         is not a minter anywhere. Total supply unchanged on each fork.
    function test_D4_4a_morMintGatedEth() public {
        _ethFork();
        uint256 supplyBefore = IERC20D4(MOR_ETH).totalSupply();
        vm.prank(attacker);
        vm.expectRevert("MOROFT: invalid caller");
        IMOROFTD4(MOR_ETH).mint(attacker, 1_000_000 ether);
        assertEq(IERC20D4(MOR_ETH).totalSupply(), supplyBefore);
        assertEq(IERC20D4(MOR_ETH).balanceOf(attacker), 0);
    }

    function test_D4_4b_morMintGatedArb() public {
        _arbFork();
        uint256 supplyBefore = IERC20D4(MOR_ARB).totalSupply();
        vm.prank(attacker);
        vm.expectRevert("MOROFT: invalid caller");
        IMOROFTD4(MOR_ARB).mint(attacker, 1_000_000 ether);
        assertEq(IERC20D4(MOR_ARB).totalSupply(), supplyBefore);
    }

    function test_D4_4c_morMintGatedBase() public {
        _baseFork();
        uint256 supplyBefore = IERC20D4(MOROFT_BASE).totalSupply();
        vm.prank(attacker);
        vm.expectRevert("MOROFT: invalid caller");
        IMOROFTD4(MOROFT_BASE).mint(attacker, 1_000_000 ether);
        assertEq(IERC20D4(MOROFT_BASE).totalSupply(), supplyBefore);
    }
}
