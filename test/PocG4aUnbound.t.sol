// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import "./PocD3Lumerin.t.sol";

// ---- shared minimal interfaces (ETH side) ----
interface IERC20G4a {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function burnFrom(address, uint256) external;
}

interface IDistributorG4a {
    function withdrawYield(uint256, address) external;
}

interface IPreCrimeG4a {
    function isPeer(uint32, bytes32) external view returns (bool);
    function lzReceiveAndRevert(InboundPacketG4a[] calldata) external payable;
}

struct OriginG4a {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

struct InboundPacketG4a {
    OriginG4a origin;
    uint32 dstEid;
    address receiver;
    bytes32 guid;
    uint256 value;
    address executor;
    bytes message;
    bytes extraData;
}

/// @title Fase 3 Gap G4-A — unbound trusted-address sweep, fork DISPROOF tests (ETH)
/// @notice Every test asserts an unprivileged attacker CANNOT divert funds
///         through an address parameter. A PASS means the attack fails.
///         Fork: ETH block 26391516. Attacker = fresh address, no roles.
contract PocG4aEthTest is Test {
    address constant MOR_ETH = 0xcBB8f1BDA10b9696c57E13BC128Fe674769DCEc0;
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant L1_SENDER = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant MOR_BASE = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    address internal attacker;
    address internal victim;

    function setUp() public {
        vm.createSelectFork("eth", 26391516);
        attacker = makeAddr("g4a-attacker");
        victim = makeAddr("g4a-victim");
        deal(MOR_ETH, victim, 1_000 ether);
    }

    // Required so lzReceiveAndRevert's final `revert SimulationResult(...)`
    // evaluates through the intended path instead of a missing-function revert.
    function buildSimulationResult() external view returns (bytes memory) {
        return "";
    }

    // ---- S1: Distributor.withdrawYield(pool, address) ----
    // OUTCOME: the address param is validated by _onlyExistedDepositPool
    // (DistributorV2.deployed.sol:248) and the yield goes to the FIXED
    // l1Sender (L513-541), never to the caller. DEAD.
    function test_G4a_withdrawYieldArbitraryAddressReverts() public {
        vm.prank(attacker);
        vm.expectRevert("DR: deposit pool doesn't exist");
        IDistributorG4a(DISTRIBUTOR).withdrawYield(0, attacker);
    }

    function test_G4a_withdrawYieldValidPoolPaysOnlyL1Sender() public {
        uint256 attackerStethBefore = IERC20G4a(STETH).balanceOf(attacker);
        uint256 attackerMorBefore = IERC20G4a(MOR_ETH).balanceOf(attacker);
        uint256 l1SenderStethBefore = IERC20G4a(STETH).balanceOf(L1_SENDER);
        // Permissionless keeper trigger with the REAL pool address succeeds...
        vm.prank(attacker);
        IDistributorG4a(DISTRIBUTOR).withdrawYield(0, STETH_POOL);
        // ...but the attacker gains nothing; any yield went to l1Sender.
        assertEq(IERC20G4a(STETH).balanceOf(attacker), attackerStethBefore);
        assertEq(IERC20G4a(MOR_ETH).balanceOf(attacker), attackerMorBefore);
        assertGe(IERC20G4a(STETH).balanceOf(L1_SENDER), l1SenderStethBefore);
    }

    // ---- S4: MOROFT.burnFrom(account_, amount_) ----
    // OUTCOME: _spendAllowance(account_, msg.sender, amount_) (MOROFT.sol:82)
    // — burns only with the victim's allowance. DEAD.
    function test_G4a_burnFromNeedsAllowance() public {
        vm.prank(attacker);
        vm.expectRevert();
        IERC20G4a(MOR_ETH).burnFrom(victim, 1 ether);
        assertEq(IERC20G4a(MOR_ETH).balanceOf(victim), 1_000 ether);
    }

    function test_G4a_burnFromWithAllowanceWorksControl() public {
        vm.prank(victim);
        IERC20G4a(MOR_ETH).approve(attacker, 1 ether);
        vm.prank(attacker);
        IERC20G4a(MOR_ETH).burnFrom(victim, 1 ether);
        assertEq(IERC20G4a(MOR_ETH).balanceOf(victim), 999 ether);
    }

    // ---- S2: OFT lzReceiveAndRevert (pre-crime simulation) ----
    // OUTCOME: the function simulates packets from TRUSTED peers only, then
    // ALWAYS reverts with SimulationResult (OAppPreCrimeSimulator.sol:45-70),
    // wiping any simulated state (incl. a mint). The packet below is
    // well-formed (trusted Base peer, OFT message crediting 1 MOR to the
    // attacker) — the simulation would mint, then the revert undoes it. DEAD.
    function test_G4a_lzReceiveAndRevertCannotMint() public {
        // Self-validating: the peer MUST be trusted or the packet is skipped.
        assertTrue(
            IPreCrimeG4a(MOR_ETH).isPeer(30184, bytes32(uint256(uint160(MOR_BASE)))),
            "Base MOR must be a trusted peer of ETH MOR"
        );
        uint256 supplyBefore = IERC20G4a(MOR_ETH).totalSupply();
        uint256 attackerBefore = IERC20G4a(MOR_ETH).balanceOf(attacker);

        bytes memory message = abi.encodePacked(
            bytes32(uint256(uint160(attacker))),
            uint64(1_000_000) // 1 MOR in shared decimals (6)
        );
        InboundPacketG4a[] memory packets = new InboundPacketG4a[](1);
        packets[0] = InboundPacketG4a({
            origin: OriginG4a({
                srcEid: 30184,
                sender: bytes32(uint256(uint160(MOR_BASE))),
                nonce: 1
            }),
            dstEid: 30101,
            receiver: MOR_ETH,
            guid: bytes32(uint256(0x1234)),
            value: 0,
            executor: address(0),
            message: message,
            extraData: ""
        });

        vm.prank(attacker);
        vm.expectRevert();
        IPreCrimeG4a(MOR_ETH).lzReceiveAndRevert(packets);

        // The revert wiped the simulation: no mint persisted.
        assertEq(IERC20G4a(MOR_ETH).totalSupply(), supplyBefore);
        assertEq(IERC20G4a(MOR_ETH).balanceOf(attacker), attackerBefore);
    }
}

/// @title Fase 3 Gap G4-A — unbound trusted-address sweep, fork DISPROOF tests (Lumerin)
/// @notice The Lumerin facets gate every subject address through
///         _validateDelegatee (caller == subject, or a delegation the
///         SUBJECT created in the immutable foobar DelegateRegistry V2).
///         These tests prove an attacker cannot act as another subject.
///         Inherits the proven D3 harness (Base fork 56038769, provider +
///         model registered in setUp).
contract PocG4aLumerinGateTest is PocD3LumerinTest {
    error InsufficientRightsForOperation(address delegator, address delegatee);

    // ---- S3: registry / marketplace subject gates ----
    // OUTCOME: every call reverts InsufficientRightsForOperation(provider,
    // attacker) at the _validateDelegatee gate, before any state is touched.
    // The gate reads the external DelegateRegistry, whose delegations only
    // the delegator themself can create — an attacker cannot self-grant. DEAD.
    function test_G4a_providerRegisterAsOtherReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(InsufficientRightsForOperation.selector, provider, attacker));
        diamond.providerRegister(provider, 0, "https://evil.example");
    }

    function test_G4a_providerDeregisterAsOtherReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(InsufficientRightsForOperation.selector, provider, attacker));
        diamond.providerDeregister(provider);
    }

    function test_G4a_modelRegisterAsOtherReverts() public {
        bytes32 baseModelId = keccak256("d3-test-model");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(InsufficientRightsForOperation.selector, provider, attacker));
        diamond.modelRegister(provider, baseModelId, keccak256("cid"), 0, 0, "spoof", new string[](0));
    }

    function test_G4a_postModelBidAsOtherReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(InsufficientRightsForOperation.selector, provider, attacker));
        diamond.postModelBid(provider, modelId, PRICE);
    }

    function test_G4a_openSessionAsOtherReverts() public {
        // Gate fires before any approval/signature validation: the caller
        // must be the session user (or their delegatee).
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(InsufficientRightsForOperation.selector, provider, attacker));
        diamond.openSession(provider, 1 ether, false, "", "");
    }

    function test_G4a_withdrawUserStakesAsOtherReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(InsufficientRightsForOperation.selector, provider, attacker));
        diamond.withdrawUserStakes(provider, 1);
    }
}
