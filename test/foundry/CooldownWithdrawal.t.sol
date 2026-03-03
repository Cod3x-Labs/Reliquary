// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "test/foundry/mocks/ERC20Mock.sol";
import {Pausable, Ownable, CooldownWithdrawal} from "contracts/CooldownWithdrawal.sol";
import {ICooldownWithdrawal} from "contracts/interfaces/ICooldownWithdrawal.sol";
import {Reliquary} from "contracts/Reliquary.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PolynomialPlateauCurve} from "contracts/curves/PolynomialPlateauCurve.sol";
import {ParentRollingRewarder} from "contracts/rewarders/ParentRollingRewarder.sol";
import {NFTDescriptor} from "contracts/nft_descriptors/NFTDescriptor.sol";
import {ERC721Holder} from "openzeppelin-contracts/contracts/token/ERC721/utils/ERC721Holder.sol";
import {
    PausableUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {console2} from "forge-std/console2.sol";

contract CooldownWithdrawalTest is ERC721Holder, Test {
    CooldownWithdrawal cooldownContract;
    Reliquary reliquary;
    ERC20Mock token;

    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address mainRewardToken;
    address multisig;

    uint256 relicId;
    uint256 user1RelicId;
    uint256 user2RelicId;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 private constant GUARDIAN = keccak256("GUARDIAN");
    uint64 constant COOLDOWN_PERIOD = 3 days;
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
        multisig = makeAddr("multisig");

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

        console2.log("Reliquary address: ", address(reliquary));

        // Deploy cooldown contract
        vm.prank(owner);
        cooldownContract = new CooldownWithdrawal(COOLDOWN_PERIOD, address(reliquary));

        reliquary.setCooldownWithdrawal(address(cooldownContract));
    }

    // ============ registerWithdrawal Tests ============

    function test_registerWithdrawal_Success() external {
        reliquary.withdraw(WITHDRAWAL_AMOUNT, relicId, address(this));
        assertEq(cooldownContract.getUserPendingWithdrawals(address(this)).length, 1);
        assertEq(cooldownContract.withdrawalCounter(), 1);

        CooldownWithdrawal.WithdrawalRequest memory req = cooldownContract.getWithdrawalDetails(0);

        assertEq(req.user, address(this));
        assertEq(req.token, address(token));
        assertEq(req.amount, WITHDRAWAL_AMOUNT);
        assertEq(req.readyTime, block.timestamp + COOLDOWN_PERIOD);
        assertEq(req.poolId, POOL_ID);
        assertFalse(req.executed);
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
        vm.expectRevert(ICooldownWithdrawal.ZeroAmount.selector);
        cooldownContract.registerWithdrawal(user1, POOL_ID, 0);
    }

    function test_registerWithdrawal_RevertZeroAddress() external {
        vm.prank(address(reliquary));
        vm.expectRevert(ICooldownWithdrawal.InvalidUser.selector);
        cooldownContract.registerWithdrawal(address(0), POOL_ID, WITHDRAWAL_AMOUNT);
    }

    function test_registerWithdrawal_RevertNotReliquary() external {
        vm.prank(user1);
        vm.expectRevert(ICooldownWithdrawal.OnlyReliquary.selector);
        cooldownContract.registerWithdrawal(user1, POOL_ID, WITHDRAWAL_AMOUNT);
    }

    function test_registerWithdrawal_TransfersTokens() external {
        uint256 balanceBefore = token.balanceOf(address(cooldownContract));
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 balanceAfter = token.balanceOf(address(cooldownContract));
        assertEq(balanceAfter - balanceBefore, WITHDRAWAL_AMOUNT);

        skip(3 days);

        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.prank(user1);
        cooldownContract.executeWithdrawal(withdrawalId);
        balanceBefore = balanceAfter;
        balanceAfter = token.balanceOf(address(cooldownContract));

        assertEq(balanceAfter, balanceBefore - WITHDRAWAL_AMOUNT);
    }

    function test_registerWithdrawal_TrackuserPendingWithdrawals() external {
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, relicId, address(this));
        vm.startPrank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, user1RelicId, user1);
        vm.stopPrank();
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, relicId, address(this));

        uint256[] memory withdrawals = cooldownContract.getUserPendingWithdrawals(address(this));
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

        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.prank(user1);
        cooldownContract.executeWithdrawal(withdrawalId);

        uint256 userBalanceAfter = token.balanceOf(user1);
        uint256 contractBalanceAfter = token.balanceOf(address(cooldownContract));

        assertEq(userBalanceAfter, userBalanceBefore + WITHDRAWAL_AMOUNT);
        assertEq(contractBalanceBefore - contractBalanceAfter, WITHDRAWAL_AMOUNT);

        CooldownWithdrawal.WithdrawalRequest memory req =
            cooldownContract.getWithdrawalDetails(withdrawalId);
        assertTrue(req.executed);
    }

    function test_executeWithdrawal_RevertNotReady() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.prank(user1);
        vm.expectRevert(ICooldownWithdrawal.WithdrawalNotReady.selector);
        cooldownContract.executeWithdrawal(withdrawalId);
    }

    function test_executeWithdrawal_RevertNotOwner() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.startPrank(user2);
        vm.expectRevert(ICooldownWithdrawal.OnlyRequestOwner.selector);
        cooldownContract.executeWithdrawal(withdrawalId);
        vm.stopPrank();
    }

    function test_executeWithdrawal_RevertAlreadyExecuted() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(user1);
        cooldownContract.executeWithdrawal(withdrawalId);

        vm.prank(user1);
        vm.expectRevert(ICooldownWithdrawal.WithdrawalAlreadyExecuted.selector);
        cooldownContract.executeWithdrawal(withdrawalId);
    }

    function test_executeWithdrawal_InvalidId() external {
        vm.expectRevert(ICooldownWithdrawal.InvalidWithdrawalId.selector);
        cooldownContract.executeWithdrawal(999);
    }

    function test_executeWithdrawal_EmitsEvent() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit ICooldownWithdrawal.WithdrawalExecuted(
            withdrawalId, user1, address(token), WITHDRAWAL_AMOUNT
        );
        cooldownContract.executeWithdrawal(withdrawalId);
    }

    // ============ cancelWithdrawal Tests ============

    function test_cancelWithdrawal_Success() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.prank(user1);
        cooldownContract.cancelWithdrawal(withdrawalId);

        CooldownWithdrawal.WithdrawalRequest memory req =
            cooldownContract.getWithdrawalDetails(withdrawalId);
        assertTrue(req.executed);
    }

    function test_cancelWithdrawal_RevertNotOwner() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.prank(user2);
        vm.expectRevert(ICooldownWithdrawal.OnlyRequestOwner.selector);
        cooldownContract.cancelWithdrawal(withdrawalId);
    }

    function test_cancelWithdrawal_RevertAlreadyExecuted() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(user1);
        cooldownContract.executeWithdrawal(withdrawalId);

        vm.prank(user1);
        vm.expectRevert(ICooldownWithdrawal.WithdrawalAlreadyExecuted.selector);
        cooldownContract.cancelWithdrawal(withdrawalId);

        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(user1);
        cooldownContract.cancelWithdrawal(withdrawalId);

        vm.prank(user1);
        vm.expectRevert(ICooldownWithdrawal.WithdrawalAlreadyExecuted.selector);
        cooldownContract.executeWithdrawal(withdrawalId);
    }

    function test_cancelWithdrawal_InvalidId() external {
        vm.prank(user1);
        vm.expectRevert(ICooldownWithdrawal.InvalidWithdrawalId.selector);
        cooldownContract.cancelWithdrawal(999);
    }

    function test_cancelWithdrawal_CallsReliquaryCreateRelicAndDeposit() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        // This test verifies the cancel calls createRelicAndDeposit on reliquary
        vm.prank(user1);
        cooldownContract.cancelWithdrawal(withdrawalId);

        // Verify execution flag is set
        CooldownWithdrawal.WithdrawalRequest memory req =
            cooldownContract.getWithdrawalDetails(withdrawalId);
        assertTrue(req.executed);
    }

    function test_cancelWithdrawal_EmitsEvent() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.prank(user1);
        vm.expectEmit(true, true, false, false);
        emit ICooldownWithdrawal.WithdrawalCancelled(withdrawalId, user1);
        cooldownContract.cancelWithdrawal(withdrawalId);
    }

    // ============ setCooldownPeriod Tests ============

    function test_setCooldownPeriod_Success() external {
        uint64 newCooldown = 7 days;

        vm.prank(owner);
        cooldownContract.setCooldownPeriod(newCooldown);

        assertEq(cooldownContract.cooldownPeriod(), newCooldown);
    }

    function test_setCooldownPeriod_RevertNotOwner() external {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                user1 // The actual caller address
            )
        );
        cooldownContract.setCooldownPeriod(7 days);
        vm.stopPrank();
    }

    function test_setCooldownPeriod_RevertZero() external {
        vm.prank(owner);
        vm.expectRevert(ICooldownWithdrawal.InvalidCooldown.selector);
        cooldownContract.setCooldownPeriod(0);
    }

    function test_setCooldownPeriod_EmitsEvent() external {
        uint64 newCooldown = 7 days;

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit ICooldownWithdrawal.CooldownPeriodUpdated(newCooldown);
        cooldownContract.setCooldownPeriod(newCooldown);
    }

    // ============ View Functions Tests ============

    function test_isWithdrawalReady_False() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        assertFalse(cooldownContract.isWithdrawalReady(withdrawalId));
    }

    function test_isWithdrawalReady_True() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        assertTrue(cooldownContract.isWithdrawalReady(withdrawalId));
    }

    function test_isWithdrawalReady_FalseIfExecuted() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(user1);
        cooldownContract.executeWithdrawal(withdrawalId);

        assertFalse(cooldownContract.isWithdrawalReady(withdrawalId));
    }

    function test_getTimeRemaining_BeforeCooldown() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        uint256 timeRemaining = cooldownContract.getTimeRemaining(withdrawalId);
        assertEq(timeRemaining, COOLDOWN_PERIOD);
    }

    function test_getTimeRemaining_AfterCooldown() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        uint256 timeRemaining = cooldownContract.getTimeRemaining(withdrawalId);
        assertEq(timeRemaining, 0);
    }

    function test_getTimeRemaining_PartialCooldown() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        uint256 elapsedTime = 1 days;
        vm.warp(block.timestamp + elapsedTime);

        uint256 timeRemaining = cooldownContract.getTimeRemaining(withdrawalId);
        assertEq(timeRemaining, COOLDOWN_PERIOD - elapsedTime);
    }

    function test_getWithdrawalDetails_ReturnsCorrectData() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        CooldownWithdrawal.WithdrawalRequest memory req =
            cooldownContract.getWithdrawalDetails(withdrawalId);

        assertEq(req.user, user1);
        assertEq(req.token, address(token));
        assertEq(req.amount, WITHDRAWAL_AMOUNT);
        assertEq(req.readyTime, block.timestamp + COOLDOWN_PERIOD);
        assertEq(req.poolId, POOL_ID);
        assertFalse(req.executed);
    }

    function test_getUserPendingWithdrawals_Empty() external {
        uint256[] memory withdrawals = cooldownContract.getUserPendingWithdrawals(user1);
        assertEq(withdrawals.length, 0);
    }

    function test_getUserPendingWithdrawals_Multiple() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        vm.prank(user2);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user2RelicId, user2);

        uint256[] memory user1Withdrawals = cooldownContract.getUserPendingWithdrawals(user1);
        uint256[] memory user2Withdrawals = cooldownContract.getUserPendingWithdrawals(user2);

        assertEq(user1Withdrawals.length, 2);
        assertEq(user2Withdrawals.length, 1);
        assertEq(user1Withdrawals[0], 0);
        assertEq(user1Withdrawals[1], 1);
        assertEq(user2Withdrawals[0], 2);
    }

    function test_getUserPendingWithdrawalsLength() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        uint256 id1 = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        uint256 id2 = cooldownContract.getUserPendingWithdrawals(user1)[1];

        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 2);

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(user1);
        cooldownContract.executeWithdrawal(id1);

        uint256 nid2 = cooldownContract.getUserPendingWithdrawals(user1)[0];

        assertEq(nid2, id2, "Wrong ids 2");

        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 1);

        vm.prank(user1);
        cooldownContract.cancelWithdrawal(id2);

        uint256[] memory arr = cooldownContract.getUserPendingWithdrawals(user1);

        assertEq(arr.length, 0, "Wrong ids after cancel");

        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 0);
    }

    // ============ Integration Tests ============

    function test_multipleWithdrawalsSequence() external {
        vm.prank(user1);
        reliquary.withdraw(100e18, user1RelicId, user1);
        uint256 id1 = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.prank(user1);
        reliquary.withdraw(200e18, user1RelicId, user1);
        uint256 id2 = cooldownContract.getUserPendingWithdrawals(user1)[1];

        vm.prank(user2);
        reliquary.withdraw(300e18, user2RelicId, user2);
        uint256 id3 = cooldownContract.getUserPendingWithdrawals(user2)[0];

        assertEq(cooldownContract.withdrawalCounter(), 3);
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 2);
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user2), 1);

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(user1);
        cooldownContract.executeWithdrawal(id1);

        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 1);

        vm.prank(user1);
        cooldownContract.cancelWithdrawal(id2);

        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 0);

        vm.prank(user2);
        cooldownContract.executeWithdrawal(id3);

        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user2), 0);
    }

    // ============ cancelWithdrawal Error Tests ============

    /// @notice Test that cancelWithdrawal reverts when Reliquary.createRelicAndDeposit fails
    function test_cancelWithdrawal_RevertReliquaryOperationFailed() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        // Pause reliquary to make createRelicAndDeposit fail

        reliquary.grantRole(GUARDIAN, multisig);
        vm.startPrank(multisig);
        reliquary.pause();
        vm.stopPrank();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        cooldownContract.cancelWithdrawal(withdrawalId);
    }

    // ============ MAX_PENDING_WITHDRAWALS Tests ============

    /// @notice Test that registerWithdrawal reverts when user reaches MAX_PENDING_WITHDRAWALS
    function test_registerWithdrawal_RevertTooManyPendingWithdrawals() external {
        // Create MAX_PENDING_WITHDRAWALS (200) withdrawals for user1
        uint256 maxPending = cooldownContract.MAX_PENDING_WITHDRAWALS();

        // Need to deposit more to user1 to allow 200 withdrawals
        uint256 smallAmount = 10e18;
        vm.startPrank(user1);
        token.approve(address(reliquary), type(uint256).max);

        // Deposit enough to make 200 withdrawals
        reliquary.deposit(smallAmount * maxPending, user1RelicId, address(0));

        // Create exactly MAX_PENDING_WITHDRAWALS withdrawals
        for (uint256 i = 0; i < maxPending; i++) {
            reliquary.withdraw(smallAmount, user1RelicId, user1);
        }
        vm.stopPrank();

        // Verify we have exactly MAX_PENDING_WITHDRAWALS
        assertEq(cooldownContract.getUserPendingWithdrawals(user1).length, maxPending);
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), maxPending);

        // Try to create one more withdrawal - should revert
        vm.prank(user1);
        vm.expectRevert(ICooldownWithdrawal.TooManyPendingWithdrawals.selector);
        reliquary.withdraw(smallAmount, user1RelicId, user1);
    }

    /// @notice Test that after executing a withdrawal, user can create new ones
    function test_registerWithdrawal_CanCreateAfterExecuting() external {
        uint256 maxPending = cooldownContract.MAX_PENDING_WITHDRAWALS();
        uint256 smallAmount = 10e18;

        vm.startPrank(user1);
        token.approve(address(reliquary), type(uint256).max);
        reliquary.deposit(smallAmount * (maxPending + 1), user1RelicId, address(0));

        // Create MAX_PENDING_WITHDRAWALS withdrawals
        for (uint256 i = 0; i < maxPending; i++) {
            reliquary.withdraw(smallAmount, user1RelicId, user1);
        }

        // Verify we're at the limit
        assertEq(cooldownContract.getUserPendingWithdrawals(user1).length, maxPending);

        // Can't create more
        vm.expectRevert(ICooldownWithdrawal.TooManyPendingWithdrawals.selector);
        reliquary.withdraw(smallAmount, user1RelicId, user1);

        // Execute one withdrawal
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);
        uint256 firstId = cooldownContract.getUserPendingWithdrawals(user1)[0];
        cooldownContract.executeWithdrawal(firstId);

        // Now we should be able to create a new one
        reliquary.withdraw(smallAmount, user1RelicId, user1);
        vm.stopPrank();

        // Verify count is still at max (199 pending + 1 new = 200)
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), maxPending);
    }

    /// @notice Test that after canceling a withdrawal, user can create new ones
    function test_registerWithdrawal_CanCreateAfterCanceling() external {
        uint256 maxPending = cooldownContract.MAX_PENDING_WITHDRAWALS();
        uint256 smallAmount = 10e18;

        vm.startPrank(user1);
        token.approve(address(reliquary), type(uint256).max);
        reliquary.deposit(smallAmount * (maxPending + 1), user1RelicId, address(0));

        // Create MAX_PENDING_WITHDRAWALS withdrawals
        for (uint256 i = 0; i < maxPending; i++) {
            reliquary.withdraw(smallAmount, user1RelicId, user1);
        }

        // Verify we're at the limit
        assertEq(cooldownContract.getUserPendingWithdrawals(user1).length, maxPending);

        // Cancel one withdrawal (no need to wait for cooldown)
        uint256 firstId = cooldownContract.getUserPendingWithdrawals(user1)[0];
        cooldownContract.cancelWithdrawal(firstId);
        vm.stopPrank();

        // Now we should be able to create a new one
        vm.prank(user1);
        reliquary.withdraw(smallAmount, user1RelicId, user1);

        // Verify count is back at max-1 (canceled doesn't count as pending)
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), maxPending);
    }

    /// @notice Test that different users can each have MAX_PENDING_WITHDRAWALS
    function test_registerWithdrawal_MaxPendingPerUser() external {
        uint256 maxPending = 10; // Use smaller number for gas efficiency in test
        uint256 smallAmount = 10e18;

        // Setup user1
        vm.startPrank(user1);
        token.approve(address(reliquary), type(uint256).max);
        reliquary.deposit(smallAmount * maxPending, user1RelicId, address(0));
        for (uint256 i = 0; i < maxPending; i++) {
            reliquary.withdraw(smallAmount, user1RelicId, user1);
        }
        vm.stopPrank();

        // Setup user2
        vm.startPrank(user2);
        token.approve(address(reliquary), type(uint256).max);
        reliquary.deposit(smallAmount * maxPending, user2RelicId, address(0));
        for (uint256 i = 0; i < maxPending; i++) {
            reliquary.withdraw(smallAmount, user2RelicId, user2);
        }
        vm.stopPrank();

        // Both users should have their max pending
        assertEq(cooldownContract.getUserPendingWithdrawals(user1).length, maxPending);
        assertEq(cooldownContract.getUserPendingWithdrawals(user2).length, maxPending);
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), maxPending);
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user2), maxPending);
    }

    /// @notice Test edge case: exactly at MAX_PENDING_WITHDRAWALS-1, then add one more
    function test_registerWithdrawal_EdgeCaseAtLimit() external {
        uint256 maxPending = cooldownContract.MAX_PENDING_WITHDRAWALS();
        uint256 smallAmount = 10e18;

        vm.startPrank(user1);
        token.approve(address(reliquary), type(uint256).max);
        reliquary.deposit(smallAmount * maxPending, user1RelicId, address(0));

        // Create MAX_PENDING_WITHDRAWALS - 1 withdrawals
        for (uint256 i = 0; i < maxPending - 1; i++) {
            reliquary.withdraw(smallAmount, user1RelicId, user1);
        }

        // Should have 199 pending
        assertEq(cooldownContract.getUserPendingWithdrawals(user1).length, maxPending - 1);

        // One more should work (reaching exactly 200)
        reliquary.withdraw(smallAmount, user1RelicId, user1);
        assertEq(cooldownContract.getUserPendingWithdrawals(user1).length, maxPending);

        // Now 201st should fail
        vm.expectRevert(ICooldownWithdrawal.TooManyPendingWithdrawals.selector);
        reliquary.withdraw(smallAmount, user1RelicId, user1);
        vm.stopPrank();
    }

    // ============ emergencyWithdrawal Tests ============

    /// @notice Test successful emergency withdrawal by owner
    function test_emergencyWithdrawal_Success() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        uint256 userBalanceBefore = token.balanceOf(user1);
        uint256 contractBalanceBefore = token.balanceOf(address(cooldownContract));

        // Owner can execute emergency withdrawal
        vm.prank(owner);
        cooldownContract.emergencyWithdrawal(withdrawalId);

        uint256 userBalanceAfter = token.balanceOf(user1);
        uint256 contractBalanceAfter = token.balanceOf(address(cooldownContract));

        // Verify tokens transferred
        assertEq(userBalanceAfter, userBalanceBefore + WITHDRAWAL_AMOUNT);
        assertEq(contractBalanceBefore - contractBalanceAfter, WITHDRAWAL_AMOUNT);

        // Verify withdrawal marked as executed
        CooldownWithdrawal.WithdrawalRequest memory req =
            cooldownContract.getWithdrawalDetails(withdrawalId);
        assertTrue(req.executed);

        // Verify removed from pending list
        assertEq(cooldownContract.getUserPendingWithdrawals(user1).length, 0);
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 0);
    }

    /// @notice Test that emergency withdrawal bypasses cooldown period (main feature)
    function test_emergencyWithdrawal_BypassesCooldown() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        // Immediately after withdrawal (NO cooldown wait)
        assertFalse(cooldownContract.isWithdrawalReady(withdrawalId));
        assertEq(cooldownContract.getTimeRemaining(withdrawalId), COOLDOWN_PERIOD);

        uint256 userBalanceBefore = token.balanceOf(user1);

        // Owner executes emergency withdrawal WITHOUT waiting
        vm.prank(owner);
        cooldownContract.emergencyWithdrawal(withdrawalId);

        // User receives tokens despite cooldown not being elapsed
        uint256 userBalanceAfter = token.balanceOf(user1);
        assertEq(userBalanceAfter, userBalanceBefore + WITHDRAWAL_AMOUNT);
    }

    /// @notice Test that non-owner cannot call emergencyWithdrawal
    function test_emergencyWithdrawal_RevertNotOwner() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        // User tries to call emergency withdrawal
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        cooldownContract.emergencyWithdrawal(withdrawalId);

        // Another user tries
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user2));
        cooldownContract.emergencyWithdrawal(withdrawalId);

        // Random address tries
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        cooldownContract.emergencyWithdrawal(withdrawalId);
    }

    /// @notice Test emergencyWithdrawal reverts on invalid withdrawal ID
    function test_emergencyWithdrawal_RevertInvalidId() external {
        vm.prank(owner);
        vm.expectRevert(ICooldownWithdrawal.InvalidWithdrawalId.selector);
        cooldownContract.emergencyWithdrawal(999);

        // Also test with ID 0 when no withdrawals exist
        vm.prank(owner);
        vm.expectRevert(ICooldownWithdrawal.InvalidWithdrawalId.selector);
        cooldownContract.emergencyWithdrawal(0);
    }

    /// @notice Test emergencyWithdrawal reverts if already executed
    function test_emergencyWithdrawal_RevertAlreadyExecuted() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        // Execute emergency withdrawal first time
        vm.prank(owner);
        cooldownContract.emergencyWithdrawal(withdrawalId);

        // Try to execute again - should revert
        vm.prank(owner);
        vm.expectRevert(ICooldownWithdrawal.WithdrawalAlreadyExecuted.selector);
        cooldownContract.emergencyWithdrawal(withdrawalId);
    }

    /// @notice Test emergency withdrawal after normal execution should fail
    function test_emergencyWithdrawal_RevertAfterNormalExecution() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        // Wait for cooldown and execute normally
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);
        vm.prank(user1);
        cooldownContract.executeWithdrawal(withdrawalId);

        // Owner tries emergency withdrawal on already executed withdrawal
        vm.prank(owner);
        vm.expectRevert(ICooldownWithdrawal.WithdrawalAlreadyExecuted.selector);
        cooldownContract.emergencyWithdrawal(withdrawalId);
    }

    /// @notice Test emergency withdrawal after cancellation should fail
    function test_emergencyWithdrawal_RevertAfterCancel() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        // User cancels the withdrawal
        vm.prank(user1);
        cooldownContract.cancelWithdrawal(withdrawalId);

        // Owner tries emergency withdrawal on canceled withdrawal
        vm.prank(owner);
        vm.expectRevert(ICooldownWithdrawal.WithdrawalAlreadyExecuted.selector);
        cooldownContract.emergencyWithdrawal(withdrawalId);
    }

    /// @notice Test that normal execution fails after emergency withdrawal
    function test_emergencyWithdrawal_BlocksNormalExecution() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        // Owner does emergency withdrawal
        vm.prank(owner);
        cooldownContract.emergencyWithdrawal(withdrawalId);

        // Wait for cooldown
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        // User tries to execute normally - should fail
        vm.prank(user1);
        vm.expectRevert(ICooldownWithdrawal.WithdrawalAlreadyExecuted.selector);
        cooldownContract.executeWithdrawal(withdrawalId);
    }

    /// @notice Test that cancellation fails after emergency withdrawal
    function test_emergencyWithdrawal_BlocksCancellation() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        // Owner does emergency withdrawal
        vm.prank(owner);
        cooldownContract.emergencyWithdrawal(withdrawalId);

        // User tries to cancel - should fail
        vm.prank(user1);
        vm.expectRevert(ICooldownWithdrawal.WithdrawalAlreadyExecuted.selector);
        cooldownContract.cancelWithdrawal(withdrawalId);
    }

    /// @notice Test emergency withdrawal emits correct event
    function test_emergencyWithdrawal_EmitsEvent() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit ICooldownWithdrawal.WithdrawalExecuted(
            withdrawalId, user1, address(token), WITHDRAWAL_AMOUNT
        );
        cooldownContract.emergencyWithdrawal(withdrawalId);
    }

    /// @notice Test emergency withdrawal on multiple withdrawals
    function test_emergencyWithdrawal_MultipleWithdrawals() external {
        // Create 3 withdrawals for user1
        vm.startPrank(user1);
        reliquary.withdraw(100e18, user1RelicId, user1);
        uint256 id1 = cooldownContract.getUserPendingWithdrawals(user1)[0];

        reliquary.withdraw(200e18, user1RelicId, user1);
        uint256 id2 = cooldownContract.getUserPendingWithdrawals(user1)[1];

        reliquary.withdraw(300e18, user1RelicId, user1);
        uint256 id3 = cooldownContract.getUserPendingWithdrawals(user1)[2];
        vm.stopPrank();

        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 3);

        uint256 userBalanceBefore = token.balanceOf(user1);

        // Owner emergency withdraws the middle one
        vm.prank(owner);
        cooldownContract.emergencyWithdrawal(id2);

        // Check balance increased by 200e18
        assertEq(token.balanceOf(user1), userBalanceBefore + 200e18);

        // Check pending count decreased
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 2);

        // Check the other two are still valid
        CooldownWithdrawal.WithdrawalRequest memory req1 =
            cooldownContract.getWithdrawalDetails(id1);
        CooldownWithdrawal.WithdrawalRequest memory req3 =
            cooldownContract.getWithdrawalDetails(id3);
        assertFalse(req1.executed);
        assertFalse(req3.executed);

        // Owner can emergency withdraw the others
        vm.startPrank(owner);
        cooldownContract.emergencyWithdrawal(id1);
        cooldownContract.emergencyWithdrawal(id3);
        vm.stopPrank();

        // All should be executed now
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 0);
        assertEq(token.balanceOf(user1), userBalanceBefore + 600e18);
    }

    /// @notice Test emergency withdrawal for different users
    function test_emergencyWithdrawal_DifferentUsers() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 id1 = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.prank(user2);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user2RelicId, user2);
        uint256 id2 = cooldownContract.getUserPendingWithdrawals(user2)[0];

        uint256 user1BalanceBefore = token.balanceOf(user1);
        uint256 user2BalanceBefore = token.balanceOf(user2);

        // Owner emergency withdraws both
        vm.startPrank(owner);
        cooldownContract.emergencyWithdrawal(id1);
        cooldownContract.emergencyWithdrawal(id2);
        vm.stopPrank();

        // Check both users received their tokens
        assertEq(token.balanceOf(user1), user1BalanceBefore + WITHDRAWAL_AMOUNT);
        assertEq(token.balanceOf(user2), user2BalanceBefore + WITHDRAWAL_AMOUNT / 2);

        // Check both pending counts are 0
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 0);
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user2), 0);
    }

    /// @notice Test emergency withdrawal immediately after registration (0 seconds elapsed)
    function test_emergencyWithdrawal_ImmediatelyAfterRegistration() external {
        uint256 timestampBefore = block.timestamp;

        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        // Verify we're at the exact same timestamp (no time passed)
        assertEq(block.timestamp, timestampBefore);
        assertEq(cooldownContract.getTimeRemaining(withdrawalId), COOLDOWN_PERIOD);

        // Owner can immediately emergency withdraw
        vm.prank(owner);
        cooldownContract.emergencyWithdrawal(withdrawalId);

        // Verify success
        CooldownWithdrawal.WithdrawalRequest memory req =
            cooldownContract.getWithdrawalDetails(withdrawalId);
        assertTrue(req.executed);
    }

    /// @notice Test emergency withdrawal updates isWithdrawalReady status
    function test_emergencyWithdrawal_UpdatesReadyStatus() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);
        uint256 withdrawalId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        // Before emergency withdrawal - not ready (cooldown not elapsed)
        assertFalse(cooldownContract.isWithdrawalReady(withdrawalId));

        // Owner does emergency withdrawal
        vm.prank(owner);
        cooldownContract.emergencyWithdrawal(withdrawalId);

        // After emergency withdrawal - still not "ready" (because executed = true)
        assertFalse(cooldownContract.isWithdrawalReady(withdrawalId));

        // Even after cooldown period passes
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);
        assertFalse(cooldownContract.isWithdrawalReady(withdrawalId));
    }

    /// @notice Test emergency withdrawal with exact balance check
    function test_emergencyWithdrawal_ExactBalanceTransfer() external {
        // Create multiple withdrawals to test exact amounts
        vm.startPrank(user1);
        reliquary.withdraw(123e18, user1RelicId, user1);
        uint256 id1 = cooldownContract.getUserPendingWithdrawals(user1)[0];

        reliquary.withdraw(456e18, user1RelicId, user1);
        uint256 id2 = cooldownContract.getUserPendingWithdrawals(user1)[1];
        vm.stopPrank();

        uint256 user1Balance = token.balanceOf(user1);
        uint256 contractBalance = token.balanceOf(address(cooldownContract));

        // Emergency withdraw first one
        vm.prank(owner);
        cooldownContract.emergencyWithdrawal(id1);

        // Check exact amounts
        assertEq(token.balanceOf(user1), user1Balance + 123e18);
        assertEq(token.balanceOf(address(cooldownContract)), contractBalance - 123e18);

        user1Balance = token.balanceOf(user1);
        contractBalance = token.balanceOf(address(cooldownContract));

        // Emergency withdraw second one
        vm.prank(owner);
        cooldownContract.emergencyWithdrawal(id2);

        // Check exact amounts again
        assertEq(token.balanceOf(user1), user1Balance + 456e18);
        assertEq(token.balanceOf(address(cooldownContract)), contractBalance - 456e18);
    }

    function testOnlyOwnerCanPauseUnpause() public {
        address attacker = address(0xCAFE);
        // non-owner cannot pause
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                attacker // The actual caller address
            )
        );
        cooldownContract.pause();

        // owner can pause/unpause
        vm.startPrank(owner);
        cooldownContract.pause();
        assertTrue(cooldownContract.paused());
        cooldownContract.unpause();
        assertFalse(cooldownContract.paused());
        vm.stopPrank();
    }

    function testRegisterAndExecuteRevertWhenPaused() public {
        // approve cooldown contract to pull tokens from mockReliquary
        vm.startPrank(user1);
        token.approve(address(reliquary), type(uint256).max);
        user1RelicId = reliquary.createRelicAndDeposit(user1, 0, WITHDRAWAL_AMOUNT);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);

        vm.stopPrank();

        // fast forward to after cooldown
        skip(1 days + 1);

        // pause the contract
        vm.prank(owner);
        cooldownContract.pause();

        // executeWithdrawal should revert while paused
        uint256 wid = cooldownContract.getUserPendingWithdrawals(user1)[0];
        vm.prank(user1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        cooldownContract.executeWithdrawal(wid);

        // emergencyWithdrawal by owner should succeed even when paused
        uint256 userBalBefore = token.balanceOf(user1);
        vm.prank(owner);
        cooldownContract.emergencyWithdrawal(wid);
        assertEq(token.balanceOf(user1), userBalBefore + WITHDRAWAL_AMOUNT);
    }

    function testRegisterRevertsWhenPaused() public {
        // pause first
        vm.prank(owner);
        cooldownContract.pause();

        // attempt to register should revert with Pausable
        vm.prank(address(reliquary));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        cooldownContract.registerWithdrawal(user1, 0, 1 ether);
    }

    /// @notice Test getUserWithdrawalsDetails returns empty array for user with no withdrawals
    function test_getUserWithdrawalsDetails_EmptyArray() external {
        CooldownWithdrawal.WithdrawalRequest[] memory details =
            cooldownContract.getUserWithdrawalsDetails(user1);

        assertEq(details.length, 0);
    }

    /// @notice Test getUserWithdrawalsDetails returns correct details for single withdrawal
    function test_getUserWithdrawalsDetails_SingleWithdrawal() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT, user1RelicId, user1);

        CooldownWithdrawal.WithdrawalRequest[] memory details =
            cooldownContract.getUserWithdrawalsDetails(user1);

        assertEq(details.length, 1);
        assertEq(details[0].user, user1);
        assertEq(address(details[0].token), address(token));
        assertEq(details[0].amount, WITHDRAWAL_AMOUNT);
        assertEq(details[0].readyTime, block.timestamp + COOLDOWN_PERIOD);
        assertEq(details[0].poolId, POOL_ID);
        assertFalse(details[0].executed);
    }

    /// @notice Test getUserWithdrawalsDetails returns correct details for multiple withdrawals
    function test_getUserWithdrawalsDetails_MultipleWithdrawals(uint256 amount1, uint256 amount2)
        external
    {
        amount1 = bound(amount1, 1, WITHDRAWAL_AMOUNT / 3);
        amount2 = bound(amount1, 1, WITHDRAWAL_AMOUNT / 3);
        uint256 amount3 = WITHDRAWAL_AMOUNT / 3;

        vm.startPrank(user1);
        reliquary.withdraw(amount1, user1RelicId, user1);
        uint256 timestamp1 = block.timestamp;

        skip(1 hours);
        reliquary.withdraw(amount2, user1RelicId, user1);
        uint256 timestamp2 = block.timestamp;

        skip(2 hours);
        reliquary.withdraw(amount3, user1RelicId, user1);
        uint256 timestamp3 = block.timestamp;
        vm.stopPrank();

        CooldownWithdrawal.WithdrawalRequest[] memory details =
            cooldownContract.getUserWithdrawalsDetails(user1);

        assertEq(details.length, 3);

        // Check first withdrawal
        assertEq(details[0].user, user1);
        assertEq(details[0].amount, amount1);
        assertEq(details[0].readyTime, timestamp1 + COOLDOWN_PERIOD);
        assertFalse(details[0].executed);

        // Check second withdrawal
        assertEq(details[1].user, user1);
        assertEq(details[1].amount, amount2);
        assertEq(details[1].readyTime, timestamp2 + COOLDOWN_PERIOD);
        assertFalse(details[1].executed);

        // Check third withdrawal
        assertEq(details[2].user, user1);
        assertEq(details[2].amount, amount3);
        assertEq(details[2].readyTime, timestamp3 + COOLDOWN_PERIOD);
        assertFalse(details[2].executed);
    }

    /// @notice Test getUserWithdrawalsDetails excludes executed withdrawals
    function test_getUserWithdrawalsDetails_ExcludesExecuted() external {
        vm.startPrank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 5, user1RelicId, user1);
        uint256 id1 = cooldownContract.getUserPendingWithdrawals(user1)[0];

        reliquary.withdraw(WITHDRAWAL_AMOUNT / 4, user1RelicId, user1);
        uint256 id2 = cooldownContract.getUserPendingWithdrawals(user1)[1];

        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, user1RelicId, user1);
        vm.stopPrank();

        // Initially 3 withdrawals
        CooldownWithdrawal.WithdrawalRequest[] memory detailsBefore =
            cooldownContract.getUserWithdrawalsDetails(user1);
        assertEq(detailsBefore.length, 3);

        // Execute first withdrawal
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);
        vm.prank(user1);
        cooldownContract.executeWithdrawal(id1);

        // Should now have 2 withdrawals
        CooldownWithdrawal.WithdrawalRequest[] memory detailsAfterExecute =
            cooldownContract.getUserWithdrawalsDetails(user1);
        assertEq(detailsAfterExecute.length, 2);

        // The remaining should be id2 and id3 (with amounts 200 and 300)
        // Note: order might change due to swap-and-pop
        bool found2 = false;
        bool found3 = false;
        for (uint256 i = 0; i < detailsAfterExecute.length; i++) {
            if (detailsAfterExecute[i].amount == WITHDRAWAL_AMOUNT / 4) found2 = true;
            if (detailsAfterExecute[i].amount == WITHDRAWAL_AMOUNT / 3) found3 = true;
        }
        assertTrue(found2, "Should still have 2 withdrawal");
        assertTrue(found3, "Should still have 3 withdrawal");
    }

    /// @notice Test getUserWithdrawalsDetails excludes cancelled withdrawals
    function test_getUserWithdrawalsDetails_ExcludesCancelled() external {
        vm.startPrank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, user1RelicId, user1);
        uint256 id1 = cooldownContract.getUserPendingWithdrawals(user1)[0];

        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        vm.stopPrank();

        // Initially 2 withdrawals
        CooldownWithdrawal.WithdrawalRequest[] memory detailsBefore =
            cooldownContract.getUserWithdrawalsDetails(user1);
        assertEq(detailsBefore.length, 2);

        // Cancel first withdrawal
        vm.prank(user1);
        cooldownContract.cancelWithdrawal(id1);

        // Should now have 1 withdrawal
        CooldownWithdrawal.WithdrawalRequest[] memory detailsAfterCancel =
            cooldownContract.getUserWithdrawalsDetails(user1);
        assertEq(detailsAfterCancel.length, 1);
        assertEq(detailsAfterCancel[0].amount, WITHDRAWAL_AMOUNT / 2);
    }

    /// @notice Test getUserWithdrawalsDetails for different users returns correct data
    function test_getUserWithdrawalsDetails_DifferentUsers() external {
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);

        vm.prank(user2);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, user2RelicId, user2);

        CooldownWithdrawal.WithdrawalRequest[] memory details1 =
            cooldownContract.getUserWithdrawalsDetails(user1);
        CooldownWithdrawal.WithdrawalRequest[] memory details2 =
            cooldownContract.getUserWithdrawalsDetails(user2);

        assertEq(details1.length, 1);
        assertEq(details2.length, 1);

        assertEq(details1[0].user, user1);
        assertEq(details1[0].amount, WITHDRAWAL_AMOUNT / 2);

        assertEq(details2[0].user, user2);
        assertEq(details2[0].amount, WITHDRAWAL_AMOUNT / 3);
    }

    /// @notice Test getUserWithdrawalsDetails with mix of ready and not-ready withdrawals
    function test_getUserWithdrawalsDetails_MixedReadyStatus() external {
        vm.startPrank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, user1RelicId, user1);
        uint256 timestamp1 = block.timestamp;

        // Move time forward
        skip(COOLDOWN_PERIOD + 1);

        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        uint256 timestamp2 = block.timestamp;
        vm.stopPrank();

        CooldownWithdrawal.WithdrawalRequest[] memory details =
            cooldownContract.getUserWithdrawalsDetails(user1);

        assertEq(details.length, 2);

        // First should be ready (cooldown elapsed)
        assertEq(details[0].readyTime, timestamp1 + COOLDOWN_PERIOD);
        assertTrue(block.timestamp >= details[0].readyTime);

        // Second should NOT be ready
        assertEq(details[1].readyTime, timestamp2 + COOLDOWN_PERIOD);
        assertFalse(block.timestamp >= details[1].readyTime);
    }

    /// @notice Test getUserWithdrawalsDetails after emergency withdrawal
    function test_getUserWithdrawalsDetails_AfterEmergencyWithdrawal() external {
        vm.startPrank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, user1RelicId, user1);
        uint256 id1 = cooldownContract.getUserPendingWithdrawals(user1)[0];

        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        vm.stopPrank();

        // Initially 2 withdrawals
        assertEq(cooldownContract.getUserWithdrawalsDetails(user1).length, 2);

        // Owner does emergency withdrawal
        vm.prank(owner);
        cooldownContract.emergencyWithdrawal(id1);

        // Should now have 1 withdrawal
        CooldownWithdrawal.WithdrawalRequest[] memory details =
            cooldownContract.getUserWithdrawalsDetails(user1);
        assertEq(details.length, 1);
        assertEq(details[0].amount, WITHDRAWAL_AMOUNT / 2);
    }

    /// @notice Test getUserWithdrawalsDetails with maximum pending withdrawals
    function test_getUserWithdrawalsDetails_MaxPendingWithdrawals() external {
        uint256 maxPending = 500; // Use smaller number for gas efficiency
        uint256 smallAmount = 10e18;

        vm.startPrank(user1);
        token.approve(address(reliquary), type(uint256).max);
        reliquary.deposit(smallAmount * maxPending, user1RelicId, address(0));

        for (uint256 i = 0; i < maxPending; i++) {
            reliquary.withdraw(smallAmount, user1RelicId, user1);
        }
        vm.stopPrank();

        CooldownWithdrawal.WithdrawalRequest[] memory details =
            cooldownContract.getUserWithdrawalsDetails(user1);

        assertEq(details.length, maxPending);

        // Verify all have correct amount
        for (uint256 i = 0; i < details.length; i++) {
            assertEq(details[i].amount, smallAmount);
            assertEq(details[i].user, user1);
            assertFalse(details[i].executed);
        }
    }

    /// @notice Test successfully executes all matured withdrawals
    function test_executeAllMaturedWithdrawals_Success_AllMatured() external {
        // user1 creates 3 withdrawals
        vm.startPrank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 6, user1RelicId, user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 4, user1RelicId, user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        vm.stopPrank();

        uint256[] memory ids = cooldownContract.getUserPendingWithdrawals(user1);
        assertEq(ids.length, 3, "user1 should have 3 withdrawals");

        // Verify all are not ready yet
        for (uint256 i = 0; i < ids.length; i++) {
            assertFalse(
                cooldownContract.isWithdrawalReady(ids[i]),
                "Withdrawal should not be ready before cooldown"
            );
        }

        // Warp time so all are matured
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        // Verify all are now ready
        for (uint256 i = 0; i < ids.length; i++) {
            assertTrue(
                cooldownContract.isWithdrawalReady(ids[i]),
                "Withdrawal should be ready after cooldown"
            );
        }

        uint256 userBalanceBefore = token.balanceOf(user1);
        uint256 contractBalanceBefore = token.balanceOf(address(cooldownContract));
        uint256 expectedTotal = 11 * WITHDRAWAL_AMOUNT / 12;

        // Execute all matured
        vm.prank(user1);
        cooldownContract.executeAllMaturedWithdrawals();

        uint256 userBalanceAfter = token.balanceOf(user1);
        uint256 contractBalanceAfter = token.balanceOf(address(cooldownContract));

        // Verify all 3 executed
        assertEq(
            userBalanceAfter - userBalanceBefore,
            expectedTotal,
            "Should receive sum of all withdrawals"
        );
        assertEq(
            contractBalanceBefore - contractBalanceAfter,
            expectedTotal,
            "Contract should send all tokens"
        );
        assertEq(
            cooldownContract.getUserPendingWithdrawalsLength(user1),
            0,
            "All withdrawals should be executed"
        );

        // Verify each is marked executed
        for (uint256 i = 0; i < ids.length; i++) {
            CooldownWithdrawal.WithdrawalRequest memory req =
                cooldownContract.getWithdrawalDetails(ids[i]);
            assertTrue(req.executed);
        }
    }

    /// @notice Test skips non-matured withdrawals
    function test_executeAllMaturedWithdrawals_SkipsNonMatured() external {
        // user1 creates first withdrawal
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 4, user1RelicId, user1);
        uint256 id1 = cooldownContract.getUserPendingWithdrawals(user1)[0];

        // Warp time so first is matured
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        // user1 creates second withdrawal (NOT matured yet)
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        uint256 id2 = cooldownContract.getUserPendingWithdrawals(user1)[1];

        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 2);

        // First should be ready, second should not
        assertTrue(cooldownContract.isWithdrawalReady(id1), "First should be ready");
        assertFalse(cooldownContract.isWithdrawalReady(id2), "Second should NOT be ready");

        uint256 userBalanceBefore = token.balanceOf(user1);

        // Execute all matured (should only execute id1, skip id2)
        vm.prank(user1);
        cooldownContract.executeAllMaturedWithdrawals();

        uint256 userBalanceAfter = token.balanceOf(user1);

        // Should receive only the first withdrawal
        assertEq(
            userBalanceAfter - userBalanceBefore,
            WITHDRAWAL_AMOUNT / 4,
            "Should only receive matured withdrawal"
        );

        // id1 should be executed, id2 should still be pending
        CooldownWithdrawal.WithdrawalRequest memory req1 =
            cooldownContract.getWithdrawalDetails(id1);
        CooldownWithdrawal.WithdrawalRequest memory req2 =
            cooldownContract.getWithdrawalDetails(id2);

        assertTrue(req1.executed, "First withdrawal should be executed");
        assertFalse(req2.executed, "Second withdrawal should NOT be executed");

        assertEq(
            cooldownContract.getUserPendingWithdrawalsLength(user1),
            1,
            "One withdrawal should remain pending"
        );

        // Now warp time and execute the second one
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);
        assertTrue(cooldownContract.isWithdrawalReady(id2), "Second should now be ready");

        uint256 userBalanceBefore2 = token.balanceOf(user1);

        vm.prank(user1);
        cooldownContract.executeAllMaturedWithdrawals();

        assertEq(
            token.balanceOf(user1) - userBalanceBefore2,
            WITHDRAWAL_AMOUNT / 2,
            "Should now receive second withdrawal"
        );
        assertEq(
            cooldownContract.getUserPendingWithdrawalsLength(user1),
            0,
            "All withdrawals should be executed"
        );
    }

    /// @notice Test all withdrawals are non-matured - nothing executes
    function test_executeAllMaturedWithdrawals_AllNonMatured() external {
        // user1 creates 3 withdrawals but doesn't wait
        vm.startPrank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, user1RelicId, user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, user1RelicId, user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, user1RelicId, user1);
        vm.stopPrank();

        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 3);

        uint256 userBalanceBefore = token.balanceOf(user1);

        // Try to execute all (none are ready)
        vm.prank(user1);
        cooldownContract.executeAllMaturedWithdrawals();

        // No tokens transferred
        assertEq(token.balanceOf(user1), userBalanceBefore, "User should not receive any tokens");

        // All still pending
        assertEq(
            cooldownContract.getUserPendingWithdrawalsLength(user1),
            3,
            "All withdrawals should still be pending"
        );
    }

    /// @notice Test isolation: only affects caller's withdrawals
    function test_executeAllMaturedWithdrawals_OnlyCallerWithdrawals() external {
        // user1: 2 withdrawals
        vm.startPrank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        vm.stopPrank();

        // user2: 3 withdrawals
        vm.startPrank(user2);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, user2RelicId, user2);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, user2RelicId, user2);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, user2RelicId, user2);
        vm.stopPrank();

        uint256[] memory user1Ids = cooldownContract.getUserPendingWithdrawals(user1);
        uint256[] memory user2Ids = cooldownContract.getUserPendingWithdrawals(user2);

        assertEq(user1Ids.length, 2);
        assertEq(user2Ids.length, 3);

        // Warp so all are matured
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        uint256 user1BalanceBefore = token.balanceOf(user1);
        uint256 user2BalanceBefore = token.balanceOf(user2);

        // user1 executes their withdrawals
        vm.prank(user1);
        cooldownContract.executeAllMaturedWithdrawals();

        // user1 should receive their tokens
        assertEq(
            token.balanceOf(user1) - user1BalanceBefore,
            WITHDRAWAL_AMOUNT,
            "user1 should receive their withdrawals"
        );
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 0);

        // user2 should NOT be affected
        assertEq(token.balanceOf(user2), user2BalanceBefore, "user2 balance should not change");
        assertEq(
            cooldownContract.getUserPendingWithdrawalsLength(user2),
            3,
            "user2 withdrawals should still be pending"
        );

        // Verify user2 withdrawals are still not executed
        for (uint256 i = 0; i < user2Ids.length; i++) {
            CooldownWithdrawal.WithdrawalRequest memory req =
                cooldownContract.getWithdrawalDetails(user2Ids[i]);
            assertFalse(req.executed, "user2 withdrawals should NOT be executed");
        }
    }

    /// @notice Test mix of matured and already executed withdrawals
    function test_executeAllMaturedWithdrawals_MixOfMaturedAndExecuted() external {
        // user1 creates 3 withdrawals
        vm.startPrank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, user1RelicId, user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, user1RelicId, user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 3, user1RelicId, user1);
        vm.stopPrank();

        uint256[] memory ids = cooldownContract.getUserPendingWithdrawals(user1);

        // Warp time
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        // Manually execute first withdrawal
        vm.prank(user1);
        cooldownContract.executeWithdrawal(ids[0]);

        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 2);

        uint256 userBalanceBefore = token.balanceOf(user1);

        // Execute all matured (should skip already executed, execute remaining 2)
        vm.prank(user1);
        cooldownContract.executeAllMaturedWithdrawals();

        // Should receive 2 withdrawals (not 3)
        assertEq(
            token.balanceOf(user1) - userBalanceBefore,
            2 * WITHDRAWAL_AMOUNT / 3,
            "Should only execute remaining withdrawals"
        );
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 0);
    }

    /// @notice Test sequential execution: some mature at different times
    function test_executeAllMaturedWithdrawals_SequentialMaturity() external {
        // Create 3 withdrawals with time gaps
        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 5, user1RelicId, user1);
        uint256 id1 = cooldownContract.getUserPendingWithdrawals(user1)[0];

        vm.warp(block.timestamp + 1 days);

        vm.prank(user1);
        reliquary.withdraw(200e18, user1RelicId, user1);
        uint256 id2 = cooldownContract.getUserPendingWithdrawals(user1)[1];

        vm.warp(block.timestamp + 1 days);

        vm.prank(user1);
        reliquary.withdraw(WITHDRAWAL_AMOUNT / 2, user1RelicId, user1);
        uint256 id3 = cooldownContract.getUserPendingWithdrawals(user1)[2];

        // Warp to when only first is matured (created + 3 days)
        vm.warp(block.timestamp + 1 days);

        assertTrue(cooldownContract.isWithdrawalReady(id1));
        assertFalse(cooldownContract.isWithdrawalReady(id2));
        assertFalse(cooldownContract.isWithdrawalReady(id3));

        // Execute - should only get first
        vm.prank(user1);
        cooldownContract.executeAllMaturedWithdrawals();
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 2);

        // Warp to when first and second are matured
        vm.warp(block.timestamp + 1 days);

        assertTrue(cooldownContract.isWithdrawalReady(id2));
        assertFalse(cooldownContract.isWithdrawalReady(id3));

        // Execute - should only get second
        vm.prank(user1);
        cooldownContract.executeAllMaturedWithdrawals();
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 1);

        // Warp to when all are matured
        vm.warp(block.timestamp + 1 days);

        assertTrue(cooldownContract.isWithdrawalReady(id3));

        // Execute - should get third
        vm.prank(user1);
        cooldownContract.executeAllMaturedWithdrawals();
        assertEq(cooldownContract.getUserPendingWithdrawalsLength(user1), 0);
    }

    // ============ M-14: executeAllMaturedWithdrawals swap-and-pop bug ============

    /// @notice Demonstrates that executeAllMaturedWithdrawals may fail to execute
    /// the last withdrawal due to memory snapshot vs storage mutation interaction.
    /// The function takes a memory snapshot of userPendingWithdrawals, then iterates
    /// over it while _removeWithdrawalId modifies the underlying storage array via
    /// swap-and-pop. This test checks whether all matured withdrawals are executed.
    function test_M14_executeAllMaturedWithdrawals_LastNotExecuted() external {
        // Give user1 enough balance for many withdrawals
        token.mint(user1, 10000e18);
        vm.startPrank(user1);
        token.approve(address(reliquary), type(uint256).max);
        reliquary.deposit(5000e18, user1RelicId, user1);
        vm.stopPrank();

        // Create 4 withdrawals for user1 (even number to test swap-and-pop edge cases)
        uint256 smallAmount = 100e18;
        vm.startPrank(user1);
        reliquary.withdraw(smallAmount, user1RelicId, user1); // withdrawal ID 0
        reliquary.withdraw(smallAmount * 2, user1RelicId, user1); // withdrawal ID 1
        reliquary.withdraw(smallAmount * 3, user1RelicId, user1); // withdrawal ID 2
        reliquary.withdraw(smallAmount * 4, user1RelicId, user1); // withdrawal ID 3
        vm.stopPrank();

        uint256[] memory idsBefore = cooldownContract.getUserPendingWithdrawals(user1);
        assertEq(idsBefore.length, 4, "Should have 4 pending withdrawals");

        // Record the exact IDs
        uint256 id0 = idsBefore[0];
        uint256 id1 = idsBefore[1];
        uint256 id2 = idsBefore[2];
        uint256 id3 = idsBefore[3];

        console2.log("Withdrawal IDs before execution:");
        console2.log("  id0:", id0);
        console2.log("  id1:", id1);
        console2.log("  id2:", id2);
        console2.log("  id3:", id3);

        // Warp past cooldown so ALL 4 are matured
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        // Verify all 4 are ready
        assertTrue(cooldownContract.isWithdrawalReady(id0), "id0 should be ready");
        assertTrue(cooldownContract.isWithdrawalReady(id1), "id1 should be ready");
        assertTrue(cooldownContract.isWithdrawalReady(id2), "id2 should be ready");
        assertTrue(cooldownContract.isWithdrawalReady(id3), "id3 should be ready");

        uint256 userBalanceBefore = token.balanceOf(user1);
        uint256 contractBalanceBefore = token.balanceOf(address(cooldownContract));
        uint256 expectedTotal = smallAmount + smallAmount * 2 + smallAmount * 3 + smallAmount * 4;

        // Execute all matured withdrawals
        vm.prank(user1);
        cooldownContract.executeAllMaturedWithdrawals();

        uint256 userBalanceAfter = token.balanceOf(user1);
        uint256 contractBalanceAfter = token.balanceOf(address(cooldownContract));
        uint256 actualReceived = userBalanceAfter - userBalanceBefore;

        console2.log("Expected total:", expectedTotal);
        console2.log("Actual received:", actualReceived);
        console2.log("Pending remaining:", cooldownContract.getUserPendingWithdrawalsLength(user1));

        // Check if ALL withdrawals were executed
        // M-14 claims the last withdrawal is skipped
        bool id0Executed = cooldownContract.getWithdrawalDetails(id0).executed;
        bool id1Executed = cooldownContract.getWithdrawalDetails(id1).executed;
        bool id2Executed = cooldownContract.getWithdrawalDetails(id2).executed;
        bool id3Executed = cooldownContract.getWithdrawalDetails(id3).executed;

        console2.log("id0 executed:", id0Executed);
        console2.log("id1 executed:", id1Executed);
        console2.log("id2 executed:", id2Executed);
        console2.log("id3 executed:", id3Executed);

        // Assert all should be executed - if M-14 bug exists, last one won't be
        assertEq(actualReceived, expectedTotal, "User should receive ALL withdrawal amounts");
        assertEq(
            cooldownContract.getUserPendingWithdrawalsLength(user1),
            0,
            "No pending withdrawals should remain"
        );
        assertTrue(id0Executed, "Withdrawal 0 should be executed");
        assertTrue(id1Executed, "Withdrawal 1 should be executed");
        assertTrue(id2Executed, "Withdrawal 2 should be executed");
        assertTrue(id3Executed, "Withdrawal 3 should be executed");
    }

    /// @notice Test with 5 withdrawals where first is matured, last is matured,
    /// and middle ones are NOT matured. Tests the swap-and-pop interaction when
    /// matured withdrawals are at array boundaries.
    function test_M14_executeAllMatured_BoundaryMatured() external {
        token.mint(user1, 10000e18);
        vm.startPrank(user1);
        token.approve(address(reliquary), type(uint256).max);
        reliquary.deposit(5000e18, user1RelicId, user1);
        vm.stopPrank();

        // Create first withdrawal (will be matured)
        vm.prank(user1);
        reliquary.withdraw(100e18, user1RelicId, user1);
        uint256 firstId = cooldownContract.getUserPendingWithdrawals(user1)[0];

        // Warp forward half the cooldown
        vm.warp(block.timestamp + COOLDOWN_PERIOD / 2);

        // Create 3 middle withdrawals (NOT yet matured when we execute)
        vm.startPrank(user1);
        reliquary.withdraw(200e18, user1RelicId, user1);
        reliquary.withdraw(300e18, user1RelicId, user1);
        reliquary.withdraw(400e18, user1RelicId, user1);
        vm.stopPrank();

        // Warp so first is matured but middle 3 are NOT
        vm.warp(block.timestamp + COOLDOWN_PERIOD / 2 + 1);

        // Create last withdrawal at this time
        vm.prank(user1);
        reliquary.withdraw(500e18, user1RelicId, user1);

        uint256[] memory ids = cooldownContract.getUserPendingWithdrawals(user1);
        assertEq(ids.length, 5, "Should have 5 pending withdrawals");

        // Only the first should be matured at this point
        assertTrue(cooldownContract.isWithdrawalReady(ids[0]), "First should be ready");
        assertFalse(cooldownContract.isWithdrawalReady(ids[1]), "Second should NOT be ready");
        assertFalse(cooldownContract.isWithdrawalReady(ids[2]), "Third should NOT be ready");
        assertFalse(cooldownContract.isWithdrawalReady(ids[3]), "Fourth should NOT be ready");
        assertFalse(cooldownContract.isWithdrawalReady(ids[4]), "Fifth should NOT be ready");

        uint256 balBefore = token.balanceOf(user1);

        // Execute all matured - should only execute the first one
        vm.prank(user1);
        cooldownContract.executeAllMaturedWithdrawals();

        // After executing, the storage array has been modified via swap-and-pop
        // First was removed: storage was [first, 2nd, 3rd, 4th, 5th]
        // swap-and-pop: [5th, 2nd, 3rd, 4th]
        uint256 balAfter = token.balanceOf(user1);
        assertEq(balAfter - balBefore, 100e18, "Should only receive first withdrawal");
        assertEq(
            cooldownContract.getUserPendingWithdrawalsLength(user1),
            4,
            "4 withdrawals should remain"
        );

        // Now warp so ALL remaining are matured
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        uint256[] memory remainingIds = cooldownContract.getUserPendingWithdrawals(user1);
        console2.log("Remaining pending IDs after first batch:");
        for (uint256 i = 0; i < remainingIds.length; i++) {
            console2.log("  id:", remainingIds[i]);
            assertTrue(
                cooldownContract.isWithdrawalReady(remainingIds[i]), "All remaining should be ready"
            );
        }

        uint256 balBefore2 = token.balanceOf(user1);
        uint256 expectedRemaining = 200e18 + 300e18 + 400e18 + 500e18;

        // Execute all remaining matured
        vm.prank(user1);
        cooldownContract.executeAllMaturedWithdrawals();

        uint256 balAfter2 = token.balanceOf(user1);
        uint256 actualRemaining = balAfter2 - balBefore2;

        console2.log("Expected remaining:", expectedRemaining);
        console2.log("Actual remaining:", actualRemaining);
        console2.log("Pending after:", cooldownContract.getUserPendingWithdrawalsLength(user1));

        // If M-14 bug exists, the last remaining withdrawal won't be executed
        assertEq(actualRemaining, expectedRemaining, "Should receive all remaining withdrawals");
        assertEq(
            cooldownContract.getUserPendingWithdrawalsLength(user1),
            0,
            "No pending withdrawals should remain"
        );
    }

    /// @notice Test with larger number of withdrawals to stress-test the
    /// swap-and-pop interaction during batch execution.
    function test_M14_executeAllMatured_ManyWithdrawals() external {
        token.mint(user1, 100000e18);
        vm.startPrank(user1);
        token.approve(address(reliquary), type(uint256).max);
        reliquary.deposit(50000e18, user1RelicId, user1);
        vm.stopPrank();

        // Create 10 withdrawals
        uint256 totalExpected = 0;
        vm.startPrank(user1);
        for (uint256 i = 1; i <= 10; i++) {
            uint256 amount = i * 50e18;
            reliquary.withdraw(amount, user1RelicId, user1);
            totalExpected += amount;
        }
        vm.stopPrank();

        assertEq(
            cooldownContract.getUserPendingWithdrawalsLength(user1), 10, "Should have 10 pending"
        );

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        uint256[] memory allIds = cooldownContract.getUserPendingWithdrawals(user1);
        uint256 balBefore = token.balanceOf(user1);

        // Execute all
        vm.prank(user1);
        cooldownContract.executeAllMaturedWithdrawals();

        uint256 balAfter = token.balanceOf(user1);
        uint256 pendingAfter = cooldownContract.getUserPendingWithdrawalsLength(user1);

        console2.log("10 withdrawals test:");
        console2.log("  Expected:", totalExpected);
        console2.log("  Received:", balAfter - balBefore);
        console2.log("  Pending after:", pendingAfter);

        // Verify ALL were executed
        for (uint256 i = 0; i < allIds.length; i++) {
            assertTrue(
                cooldownContract.getWithdrawalDetails(allIds[i]).executed,
                string.concat("Withdrawal ", vm.toString(allIds[i]), " should be executed")
            );
        }

        assertEq(balAfter - balBefore, totalExpected, "Should receive total of all withdrawals");
        assertEq(pendingAfter, 0, "No pending withdrawals should remain");
    }
}
