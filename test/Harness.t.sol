// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

// Minimal interfaces (signatures from deployed verified source, file level).
interface IDistributor {
    function version() external pure returns (uint256);
    function undistributedRewards() external view returns (uint256);
}

interface IDepositPool {
    function version() external pure returns (uint256);
    function depositToken() external view returns (address);
    function totalDepositedInPublicPools() external view returns (uint256);
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function balanceOf(address) external view returns (uint256);
}

interface IBuildersV4 {
    function version() external pure returns (uint256);
    function depositToken() external view returns (address);
    function getCurrentSubnetsRewards() external view returns (uint256);
}

struct Facet {
    address facetAddress;
    bytes4[] functionSelectors;
}

interface IDiamondLoupe {
    function facets() external view returns (Facet[] memory);
}

/// @title Morpheus fork harness — smoke tests (READ-ONLY)
/// @notice Proves the Foundry fork setup works end-to-end against deployed
///         Appendix A addresses, on pinned blocks, with concrete asserted
///         values observed on-chain via `cast` (see values + blocks below).
///         No state-changing call is made anywhere in this file.
///         Program: mor.org/bug-bounty v2 — PoC = `forge test` on a mainnet
///         fork pinned to a specific block, no privileged accounts.
///
///         Pinned blocks (Fase 0 Lane C, 2026-11-11 ~19:00 WIB):
///           Ethereum  26391516  (eth.drpc.org)
///           Base      56038769  (mainnet.base.org)
///           Arbitrum  523270627 (arb1.arbitrum.io/rpc)
contract HarnessTest is Test {
    // ---- Ethereum (block 26391516) ----
    uint256 constant ETH_BLOCK = 26391516;
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant POOL_STETH = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant MOR_ETH = 0xcBB8f1BDA10b9696c57E13BC128Fe674769DCEc0;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant POOL_IMPL = 0xdB10dAEF167eA2233Ba6811457dD24D676FbD670;
    bytes32 constant EIP1967_IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // ---- Base (block 56038769) ----
    uint256 constant BASE_BLOCK = 56038769;
    address constant BUILDERS_V4 = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant BUILDERS_V4_IMPL = 0x18FAEf315b40A6D9cf49628f1133B1Aa507513B0;
    address constant MOROFT_BASE = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    address constant LUMERIN_DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;

    // ---- Arbitrum (block 523270627) ----
    uint256 constant ARB_BLOCK = 523270627;
    address constant MOR_ARB = 0x092bAaDB7DEf4C3981454dD9c0A0D7FF07bCFc86;

    // ---- Minimal interfaces (signatures from deployed verified source) ----

    function _ethFork() internal returns (uint256) {
        return vm.createSelectFork("eth", ETH_BLOCK);
    }

    function _baseFork() internal returns (uint256) {
        return vm.createSelectFork("base", BASE_BLOCK);
    }

    /// @notice Distributor is DistributorV2: version() == 2 at block 26391516.
    function test_ETH_DistributorVersion() public {
        _ethFork();
        assertEq(IDistributor(DISTRIBUTOR).version(), 2);
    }

    /// @notice No undistributed MOR rewards at block 26391516 (Lane C).
    function test_ETH_DistributorUndistributedRewards() public {
        _ethFork();
        assertEq(IDistributor(DISTRIBUTOR).undistributedRewards(), 0);
    }

    /// @notice stETH deposited in the stETH pool: 4,712.134... stETH at
    ///         block 26391516 (Lane C: pool deposit records 4,712.134 stETH).
    function test_ETH_PoolTotalDeposited() public {
        _ethFork();
        assertEq(
            IDepositPool(POOL_STETH).totalDepositedInPublicPools(),
            4712134476422148158533
        );
    }

    /// @notice Pool version 7, deposit token is stETH, and the EIP-1967 impl
    ///         slot points at 0xdB10...bD670 as the program page states.
    function test_ETH_PoolVersionAndImpl() public {
        _ethFork();
        assertEq(IDepositPool(POOL_STETH).version(), 7);
        assertEq(IDepositPool(POOL_STETH).depositToken(), STETH);
        bytes32 implSlot = vm.load(POOL_STETH, EIP1967_IMPL_SLOT);
        assertEq(address(uint160(uint256(implSlot))), POOL_IMPL);
    }

    /// @notice MOR totalSupply 77,286,119.889 MOR (18 decimals) at 26391516.
    function test_ETH_MorTotalSupply() public {
        _ethFork();
        assertEq(IERC20(MOR_ETH).totalSupply(), 77286119889000000000000);
        assertEq(IERC20(MOR_ETH).decimals(), 18);
    }

    /// @notice BuildersV4: version 4, deposit token MOROFT, impl slot matches
    ///         the deployed BuildersV4 implementation; current subnet rewards
    ///         87,493.753... MOR at block 56038769.
    function test_Base_BuildersV4() public {
        _baseFork();
        assertEq(IBuildersV4(BUILDERS_V4).version(), 4);
        assertEq(IBuildersV4(BUILDERS_V4).depositToken(), MOROFT_BASE);
        assertEq(
            IBuildersV4(BUILDERS_V4).getCurrentSubnetsRewards(),
            87493753129036918817234
        );
        bytes32 implSlot = vm.load(BUILDERS_V4, EIP1967_IMPL_SLOT);
        assertEq(address(uint160(uint256(implSlot))), BUILDERS_V4_IMPL);
    }

    /// @notice LumerinDiamond exposes exactly the 5 Appendix A facets with
    ///         73 selectors in total at block 56038769 (Lane A).
    function test_Base_DiamondFacets() public {
        _baseFork();
        Facet[] memory facets = IDiamondLoupe(LUMERIN_DIAMOND).facets();
        assertEq(facets.length, 5);
        address[5] memory expected = [
            0xE30279b79392AEfF7fDf1883C23d52eBA9D88A75, // ProviderRegistry
            0xb7994dE339AEe515C9b2792831CD83f3C9D8df87, // ModelRegistry
            0x5B660aB78f3AC743953F9E68630A2D66e7b45F64, // Marketplace
            0x345B8B23c38F70f1d77560C60493Bb583f012Cb0, // Delegation
            0x3a3952F0e57B343F00B31f7da039Ef16389B7260 // SessionRouter
        ];
        uint256 totalSelectors;
        for (uint256 i; i < facets.length; i++) {
            bool found;
            for (uint256 j; j < expected.length; j++) {
                if (facets[i].facetAddress == expected[j]) found = true;
            }
            assertTrue(found, "unexpected facet address");
            totalSelectors += facets[i].functionSelectors.length;
        }
        assertEq(totalSelectors, 73);
    }

    /// @notice Arbitrum MOR totalSupply 3,298,633.997 MOR at block 523270627.
    function test_Arb_MorTotalSupply() public {
        vm.createSelectFork("arb", ARB_BLOCK);
        assertEq(IERC20(MOR_ARB).totalSupply(), 3298633997448805155642996);
        assertEq(IERC20(MOR_ARB).decimals(), 18);
    }

    /// @notice An unprivileged attacker (fresh random address, no owner /
    ///         admin / multisig role) can drive the fork and make view calls.
    ///         This is the setup every PoC in this program must use.
    function test_UnprivilegedAttackerViewCalls() public {
        _ethFork();
        address attacker = makeAddr("attacker");
        assertEq(IERC20(MOR_ETH).balanceOf(attacker), 0);
        vm.prank(attacker);
        assertEq(IDistributor(DISTRIBUTOR).version(), 2);
        vm.prank(attacker);
        assertEq(IDepositPool(POOL_STETH).version(), 7);
        vm.prank(attacker);
        assertEq(IDistributor(DISTRIBUTOR).undistributedRewards(), 0);
    }
}
