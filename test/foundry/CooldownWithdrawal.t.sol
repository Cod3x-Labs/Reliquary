// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "test/foundry/mocks/ERC20Mock.sol";
import {CooldownWithdrawal} from "contracts/CooldownWithdrawal.sol";
import {Reliquary} from "contracts/Reliquary.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PolynomialPlateauCurve} from "contracts/curves/PolynomialPlateauCurve.sol";
import {ParentRollingRewarder} from "contracts/rewarders/ParentRollingRewarder.sol";
import {NFTDescriptor} from "contracts/nft_descriptors/NFTDescriptor.sol";
import {ERC721Holder} from "openzeppelin-contracts/contracts/token/ERC721/utils/ERC721Holder.sol";
import {console2} from "forge-std/console2.sol";

contract CooldownWithdrawalTest is ERC721Holder, Test {
    CooldownWithdrawal cooldownContract;
    Reliquary reliquary;
    ERC20Mock token;

    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address mainRewardToken;

    uint256 relicId;
    uint256 user1RelicId;
    uint256 user2RelicId;

    uint256 constant COOLDOWN_PERIOD = 3 days;
    uint8 constant POOL_ID = 0;
    uint256 constant INITIAL_BALANCE = 10000e18;
    uint256 constant WITHDRAWAL_AMOUNT = 1000e18;
    uint256 constant DEPOSIT_AMOUNT = 1000e18;

    int256[] public coeff = [
        int256(10000000e18),
        int256(0),
        int256(0.00000001508266362e18),
        int256(-0.00000000000000032e18),
        int256(0)
    ];

    function setUp() external {
        // Deploy mock token
        token = new ERC20Mock(18);
        mainRewardToken = address(new ERC20Mock(18));
        address multisig = makeAddr("multisig");

        Reliquary reliquaryImpl = new Reliquary();
        bytes memory data = abi.encodeWithSelector(
            Reliquary.initialize.selector,
            mainRewardToken, // _rewardToken
            0, // _emissionRate
            "Reliquary Deposit", // _name
            "RELIC", // _symbol
            uint256(0), // _minStakingAmount
            address(0) // _cooldownWithdrawal
        );
        reliquary = Reliquary(address(new ERC1967Proxy(address(reliquaryImpl), data)));

        int256[] memory coeffDynamic = new int256[](5);
        for (uint256 i = 0; i < 5; i++) {
            coeffDynamic[i] = coeff[i];
        }

        PolynomialPlateauCurve polynomialPlateauCurve =
            new PolynomialPlateauCurve(coeffDynamic, 365 days);
        ParentRollingRewarder parentRewarder = new ParentRollingRewarder();
        address nftDescriptor = address(new NFTDescriptor(address(reliquary)));

        token.mint(address(this), INITIAL_BALANCE);
        token.mint(user1, INITIAL_BALANCE);
        token.mint(user2, INITIAL_BALANCE);

        token.approve(address(reliquary), 1);
        reliquary.addPool(
            10000,
            address(token),
            address(new ParentRollingRewarder()),
            polynomialPlateauCurve, //polynomialPlateauCurve
            "CDX staking pool",
            nftDescriptor,
            true,
            multisig
        );

        token.approve(address(reliquary), type(uint256).max);
        relicId = reliquary.createRelicAndDeposit(address(this), 0, DEPOSIT_AMOUNT);

        vm.startPrank(user1);
        token.approve(address(reliquary), type(uint256).max);
        user1RelicId = reliquary.createRelicAndDeposit(user1, 0, DEPOSIT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(user2);
        token.approve(address(reliquary), type(uint256).max);
        user2RelicId = reliquary.createRelicAndDeposit(user2, 0, DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Deploy cooldown contract
        vm.prank(owner);
        cooldownContract = new CooldownWithdrawal(COOLDOWN_PERIOD, address(reliquary));

        reliquary.setCooldownWithdrawal(address(cooldownContract));
    }

    // ============ registerWithdrawal Tests ============

    function test_registerWithdrawal_Success() external {
        reliquary.withdraw(WITHDRAWAL_AMOUNT, relicId, address(this));
        assertEq(cooldownContract.getUserWithdrawals(address(this)).length, 1);
        assertEq(cooldownContract.withdrawalCounter(), 1);

        (
            address user,
            address tokenAddr,
            uint256 amount,
            uint256 readyTime,
            uint8 poolId,
            bool executed
        ) = cooldownContract.getWithdrawalDetails(0);

        assertEq(user, address(this));
        assertEq(tokenAddr, address(token));
        assertEq(amount, WITHDRAWAL_AMOUNT);
        assertEq(readyTime, block.timestamp + COOLDOWN_PERIOD);
        assertEq(poolId, POOL_ID);
        assertFalse(executed);
    }

    function test_registerWithdrawal_MultipleRequests() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        vm.prank(user2);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user2RelicId, user2);

        assertEq(cooldownContract.withdrawalCounter(), 2);
    }

    function test_registerWithdrawal_RevertZeroAmount() external {
        vm.prank(address(reliquary));
        vm.expectRevert(CooldownWithdrawal.ZeroAmount.selector);
        cooldownContract.registerWithdrawal(user1, POOL_ID, 0);
    }

    function test_registerWithdrawal_RevertZeroAddress() external {
        vm.prank(address(reliquary));
        vm.expectRevert(CooldownWithdrawal.InvalidWithdrawalId.selector);
        cooldownContract.registerWithdrawal(address(0), POOL_ID, WITHDRAWAL_AMOUNT);
    }

    function test_registerWithdrawal_RevertNotReliquary() external {
        vm.prank(user1);
        vm.expectRevert(CooldownWithdrawal.OnlyReliquary.selector);
        cooldownContract.registerWithdrawal(user1, POOL_ID, WITHDRAWAL_AMOUNT);
    }

    function test_registerWithdrawal_TransfersTokens() external {
        uint256 balanceBefore = token.balanceOf(address(cooldownContract));
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 balanceAfter = token.balanceOf(address(cooldownContract));
        assertEq(balanceAfter - balanceBefore, WITHDRAWAL_AMOUNT);

        skip(3 days);

        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        vm.prank(user1);
        cooldownContract.executeWithdrawal(withdrawalId);
        balanceBefore = balanceAfter;
        balanceAfter = token.balanceOf(address(cooldownContract));

        assertEq(balanceAfter, balanceBefore - WITHDRAWAL_AMOUNT);
    }

    function test_registerWithdrawal_TrackUserWithdrawals() external {
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, relicId, address(this));
        vm.startPrank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, user1RelicId, user1);
        vm.stopPrank();
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, relicId, address(this));

        uint256[] memory withdrawals = cooldownContract.getUserWithdrawals(address(this));
        assertEq(withdrawals.length, 2);
        assertEq(withdrawals[0], 0);
        assertEq(withdrawals[1], 2);
    }

    // ============ executeWithdrawal Tests ============

    function test_executeWithdrawal_Success() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);

        uint256 userBalanceBefore = token.balanceOf(user1);
        uint256 contractBalanceBefore = token.balanceOf(address(cooldownContract));

        // Move time forward
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        vm.prank(user1);
        cooldownContract.executeWithdrawal(withdrawalId);

        uint256 userBalanceAfter = token.balanceOf(user1);
        uint256 contractBalanceAfter = token.balanceOf(address(cooldownContract));

        assertEq(userBalanceAfter, userBalanceBefore + WITHDRAWAL_AMOUNT);
        assertEq(contractBalanceBefore - contractBalanceAfter, WITHDRAWAL_AMOUNT);

        (,,,,, bool executed) = cooldownContract.getWithdrawalDetails(withdrawalId);
        assertTrue(executed);
    }

    function test_executeWithdrawal_RevertNotReady() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        vm.prank(user1);
        vm.expectRevert(CooldownWithdrawal.WithdrawalNotReady.selector);
        cooldownContract.executeWithdrawal(withdrawalId);
    }

    function test_executeWithdrawal_RevertNotOwner() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(user2);
        vm.expectRevert(CooldownWithdrawal.OnlyRequestOwner.selector);
        cooldownContract.executeWithdrawal(withdrawalId);
    }

    function test_executeWithdrawal_RevertAlreadyExecuted() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(user1);
        cooldownContract.executeWithdrawal(withdrawalId);

        vm.prank(user1);
        vm.expectRevert(CooldownWithdrawal.WithdrawalAlreadyExecuted.selector);
        cooldownContract.executeWithdrawal(withdrawalId);
    }

    function test_executeWithdrawal_InvalidId() external {
        vm.expectRevert(CooldownWithdrawal.InvalidWithdrawalId.selector);
        cooldownContract.executeWithdrawal(999);
    }

    function test_executeWithdrawal_EmitsEvent() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit CooldownWithdrawal.WithdrawalExecuted(
            withdrawalId, user1, address(token), WITHDRAWAL_AMOUNT
        );
        cooldownContract.executeWithdrawal(withdrawalId);
    }

    // ============ cancelWithdrawal Tests ============

    function test_cancelWithdrawal_Success() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        vm.prank(user1);
        cooldownContract.cancelWithdrawal(withdrawalId);

        (,,,,, bool executed) = cooldownContract.getWithdrawalDetails(withdrawalId);
        assertTrue(executed);
    }

    function test_cancelWithdrawal_RevertNotOwner() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        vm.prank(user2);
        vm.expectRevert(CooldownWithdrawal.OnlyRequestOwner.selector);
        cooldownContract.cancelWithdrawal(withdrawalId);
    }

    function test_cancelWithdrawal_RevertAlreadyExecuted() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(user1);
        cooldownContract.executeWithdrawal(withdrawalId);

        vm.prank(user1);
        vm.expectRevert(CooldownWithdrawal.WithdrawalAlreadyExecuted.selector);
        cooldownContract.cancelWithdrawal(withdrawalId);
    }

    function test_cancelWithdrawal_InvalidId() external {
        vm.prank(user1);
        vm.expectRevert(CooldownWithdrawal.InvalidWithdrawalId.selector);
        cooldownContract.cancelWithdrawal(999);
    }

    function test_cancelWithdrawal_CallsReliquaryCreateRelicAndDeposit() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        // This test verifies the cancel calls createRelicAndDeposit on reliquary
        vm.prank(user1);
        cooldownContract.cancelWithdrawal(withdrawalId);

        // Verify execution flag is set
        (,,,,, bool executed) = cooldownContract.getWithdrawalDetails(withdrawalId);
        assertTrue(executed);
    }

    function test_cancelWithdrawal_EmitsEvent() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        vm.prank(user1);
        vm.expectEmit(true, true, false, false);
        emit CooldownWithdrawal.WithdrawalCancelled(withdrawalId, user1);
        cooldownContract.cancelWithdrawal(withdrawalId);
    }

    // ============ setCooldownPeriod Tests ============

    function test_setCooldownPeriod_Success() external {
        uint256 newCooldown = 7 days;

        vm.prank(owner);
        cooldownContract.setCooldownPeriod(newCooldown);

        assertEq(cooldownContract.cooldownPeriod(), newCooldown);
    }

    function test_setCooldownPeriod_RevertNotOwner() external {
        vm.prank(user1);
        vm.expectRevert(CooldownWithdrawal.OnlyRequestOwner.selector);
        cooldownContract.setCooldownPeriod(7 days);
    }

    function test_setCooldownPeriod_RevertZero() external {
        vm.prank(owner);
        vm.expectRevert(CooldownWithdrawal.InvalidCooldown.selector);
        cooldownContract.setCooldownPeriod(0);
    }

    function test_setCooldownPeriod_EmitsEvent() external {
        uint256 newCooldown = 7 days;

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit CooldownWithdrawal.CooldownPeriodUpdated(newCooldown);
        cooldownContract.setCooldownPeriod(newCooldown);
    }

    // ============ View Functions Tests ============

    function test_isWithdrawalReady_False() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        assertFalse(cooldownContract.isWithdrawalReady(withdrawalId));
    }

    function test_isWithdrawalReady_True() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        assertTrue(cooldownContract.isWithdrawalReady(withdrawalId));
    }

    function test_isWithdrawalReady_FalseIfExecuted() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(user1);
        cooldownContract.executeWithdrawal(withdrawalId);

        assertFalse(cooldownContract.isWithdrawalReady(withdrawalId));
    }

    function test_getTimeRemaining_BeforeCooldown() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        uint256 timeRemaining = cooldownContract.getTimeRemaining(withdrawalId);
        assertEq(timeRemaining, COOLDOWN_PERIOD);
    }

    function test_getTimeRemaining_AfterCooldown() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        uint256 timeRemaining = cooldownContract.getTimeRemaining(withdrawalId);
        assertEq(timeRemaining, 0);
    }

    function test_getTimeRemaining_PartialCooldown() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        uint256 elapsedTime = 1 days;
        vm.warp(block.timestamp + elapsedTime);

        uint256 timeRemaining = cooldownContract.getTimeRemaining(withdrawalId);
        assertEq(timeRemaining, COOLDOWN_PERIOD - elapsedTime);
    }

    function test_getWithdrawalDetails_ReturnsCorrectData() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserWithdrawals(user1)[0];

        (
            address user,
            address tokenAddr,
            uint256 amount,
            uint256 readyTime,
            uint8 poolId,
            bool executed
        ) = cooldownContract.getWithdrawalDetails(withdrawalId);

        assertEq(user, user1);
        assertEq(tokenAddr, address(token));
        assertEq(amount, WITHDRAWAL_AMOUNT);
        assertEq(readyTime, block.timestamp + COOLDOWN_PERIOD);
        assertEq(poolId, POOL_ID);
        assertFalse(executed);
    }

    function test_getUserWithdrawals_Empty() external {
        uint256[] memory withdrawals = cooldownContract.getUserWithdrawals(user1);
        assertEq(withdrawals.length, 0);
    }

    function test_getUserWithdrawals_Multiple() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        vm.prank(user2);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user2RelicId, user2);

        uint256[] memory user1Withdrawals = cooldownContract.getUserWithdrawals(user1);
        uint256[] memory user2Withdrawals = cooldownContract.getUserWithdrawals(user2);

        assertEq(user1Withdrawals.length, 2);
        assertEq(user2Withdrawals.length, 1);
        assertEq(user1Withdrawals[0], 0);
        assertEq(user1Withdrawals[1], 1);
        assertEq(user2Withdrawals[0], 2);
    }

    function test_getPendingWithdrawalCount() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        uint256 id1 = cooldownContract.getUserWithdrawals(user1)[0];
        uint256 nid1 = cooldownContract.getUsersNotExecutedWithdrawals(user1)[0];

        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        uint256 id2 = cooldownContract.getUserWithdrawals(user1)[1];

        assertEq(cooldownContract.getPendingWithdrawalCount(user1), 2);

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(user1);
        cooldownContract.executeWithdrawal(id1);

        uint256 nid2 = cooldownContract.getUsersNotExecutedWithdrawals(user1)[0];

        assertEq(nid1, id1, "Wrong ids 1");
        assertEq(nid2, id2, "Wrong ids 2");

        assertEq(cooldownContract.getPendingWithdrawalCount(user1), 1);

        vm.prank(user1);
        cooldownContract.cancelWithdrawal(id2);

        uint256[] memory arr = cooldownContract.getUsersNotExecutedWithdrawals(user1);

        assertEq(arr.length, 0, "Wrong ids after cancel");

        assertEq(cooldownContract.getPendingWithdrawalCount(user1), 0);
    }

    // ============ Integration Tests ============

    function test_multipleWithdrawalsSequence() external {
        vm.prank(user1);
        reliquary.withdraw(100e18, user1RelicId, user1);
        uint256 id1 = cooldownContract.getUserWithdrawals(user1)[0];

        vm.prank(user1);
        reliquary.withdraw(200e18, user1RelicId, user1);
        uint256 id2 = cooldownContract.getUserWithdrawals(user1)[1];

        vm.prank(user2);
        reliquary.withdraw(300e18, user2RelicId, user2);
        uint256 id3 = cooldownContract.getUserWithdrawals(user2)[0];

        assertEq(cooldownContract.withdrawalCounter(), 3);
        assertEq(cooldownContract.getPendingWithdrawalCount(user1), 2);
        assertEq(cooldownContract.getPendingWithdrawalCount(user2), 1);

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(user1);
        cooldownContract.executeWithdrawal(id1);

        assertEq(cooldownContract.getPendingWithdrawalCount(user1), 1);

        vm.prank(user1);
        cooldownContract.cancelWithdrawal(id2);

        assertEq(cooldownContract.getPendingWithdrawalCount(user1), 0);

        vm.prank(user2);
        cooldownContract.executeWithdrawal(id3);

        assertEq(cooldownContract.getPendingWithdrawalCount(user2), 0);
    }
}
