// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {SimpleStablecoin} from "../../src/SimpleStablecoin.sol";
import {Vault} from "../../src/Vault.sol";

contract LoopTasksTest is Test {
    MockUSDC internal usdc;
    SimpleStablecoin internal stable;
    Vault internal vault;

    address internal admin = address(this);
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        usdc = new MockUSDC();
        stable = new SimpleStablecoin(admin);
        vault = new Vault(usdc, stable);
        stable.grantRole(stable.MINTER_ROLE(), address(vault));
    }

    // Ex2

    function test_Ex2_DepositIncreasesSupplyByExactly(uint96 raw) public {
        uint256 amount = uint256(raw) % 1_000_000e6;
        vm.assume(amount > 0);

        usdc.faucet(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 supplyBefore = stable.totalSupply();
        vault.deposit(amount);
        vm.stopPrank();

        assertEq(stable.totalSupply(), supplyBefore + amount);
    }

    function test_Ex2_DecimalsTrap() public {
        uint256 wrong = 1000e18;
        uint256 intended = 1000e6;

        usdc.faucet(alice, wrong);
        vm.startPrank(alice);
        usdc.approve(address(vault), wrong);
        vault.deposit(wrong);
        vm.stopPrank();

        assertEq(stable.balanceOf(alice), wrong);
        assertEq(vault.totalCollateral(), stable.totalSupply());
        assertEq(stable.totalSupply() / intended, 1e12);
        assertEq(stable.totalSupply() / (10 ** stable.decimals()), 1e15);
    }

    // Ex4

    function test_Ex4_Mint_RevertsForNonMinter() public {
        bytes32 minterRole = stable.MINTER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                attacker,
                minterRole
            )
        );
        vm.prank(attacker);
        stable.mint(attacker, 1000e6);
    }

    function _aliceDeposits(uint256 amount) internal {
        usdc.faucet(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function test_Ex4_Pause_BlocksTransfers() public {
        _aliceDeposits(1000e6);
        stable.pause();

        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vm.prank(alice);
        stable.transfer(attacker, 1e6);
    }

    function test_Ex4_Pause_BlocksRedeem() public {
        _aliceDeposits(1000e6);
        stable.pause();

        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vm.prank(alice);
        vault.redeem(1000e6);

        assertEq(stable.balanceOf(alice), 1000e6);
        assertEq(vault.totalCollateral(), 1000e6);
    }

    function test_Ex4_AttackerCannotBurnOthersBalance() public {
        _aliceDeposits(1000e6);
        bytes32 minterRole = stable.MINTER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                attacker,
                minterRole
            )
        );
        vm.prank(attacker);
        stable.burn(alice, 1000e6);

        assertEq(stable.balanceOf(alice), 1000e6);
    }

    /// @dev Extra: admin key compromise scenario.
    function test_Extra_BriberyAttack_DrainsVault() public {
        _aliceDeposits(1000e6);

        stable.grantRole(stable.MINTER_ROLE(), attacker);

        vm.startPrank(attacker);
        stable.mint(attacker, 1_000_000e6);
        vault.redeem(1000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(attacker), 1000e6);
        assertEq(vault.totalCollateral(), 0);
        assertEq(stable.balanceOf(alice), 1000e6);
        assertGt(stable.totalSupply(), vault.totalCollateral());
    }

    function test_Ex4_VaultHoldsTheKey_CanBurnAnyonesBalance() public {
        _aliceDeposits(1000e6);

        vm.prank(address(vault));
        stable.burn(alice, 1000e6);

        assertEq(stable.balanceOf(alice), 0);
        assertEq(vault.totalCollateral(), 1000e6);
        assertGt(vault.totalCollateral(), stable.totalSupply());
    }
}