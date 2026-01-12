// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IReliquary} from "contracts/interfaces/IReliquary.sol";
import {ICooldownWithdrawal} from "contracts/interfaces/ICooldownWithdrawal.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title CooldownWithdrawal
 * @dev Contract that delays withdrawals by a specific cooldown period
 * Other contracts call registerWithdrawal() to initiate a withdrawal request
 * After cooldown expires, users can call executeWithdrawal() to claim tokens
 */
contract CooldownWithdrawal is ReentrancyGuard, ICooldownWithdrawal, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_PENDING_WITHDRAWALS = 200;

    // Cooldown period in seconds
    uint256 public cooldownPeriod;

    // Withdrawal request structure
    struct WithdrawalRequest {
        address user;
        IERC20 token;
        uint256 amount;
        uint256 readyTime; // Timestamp when withdrawal can be executed
        uint8 poolId;
        bool executed;
    }

    // Mapping: withdrawal ID => WithdrawalRequest
    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;

    // Counter for withdrawal IDs
    uint256 public withdrawalCounter;

    address public immutable reliquary;

    // Mapping: user => array of withdrawal IDs
    mapping(address => uint256[]) private userWithdrawals;

    /**
     * @notice Initialize cooldown contract
     * @param _cooldownPeriod Cooldown period in seconds
     */
    constructor(uint256 _cooldownPeriod, address _reliquary) Ownable(msg.sender) {
        if (_cooldownPeriod == 0) revert InvalidCooldown();
        if (_reliquary == address(0)) revert WrongReliquaryAddress();
        cooldownPeriod = _cooldownPeriod;
        reliquary = _reliquary;
    }

    /**
     * @notice Register a withdrawal request (called by external contract - reliquary)
     * @dev External contract sends tokens to this contract first, then calls registerWithdrawal
     * @param _user Address of user requesting withdrawal
     * @param _poolId Token to withdraw (ERC20)
     * @param _amount Amount to withdraw
     * @return withdrawalId ID of the withdrawal request
     */
    function registerWithdrawal(address _user, uint8 _poolId, uint256 _amount)
        external
        nonReentrant
        returns (uint256)
    {
        if (_amount == 0) revert ZeroAmount();
        if (_user == address(0)) revert InvalidWithdrawalId();
        if (msg.sender != reliquary) revert OnlyReliquary();
        if (type(uint256).max - withdrawalCounter < 1) {
            revert InvalidWithdrawalCounter();
        }
        if (userWithdrawals[_user].length >= MAX_PENDING_WITHDRAWALS) {
            revert TooManyPendingWithdrawals(); // Prevent spam
        }

        IERC20 _token = IERC20(IReliquary(reliquary).getPoolInfo(_poolId).poolToken);
        _token.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 withdrawalId = withdrawalCounter;
        uint256 readyTime = block.timestamp + cooldownPeriod;

        WithdrawalRequest storage request = withdrawalRequests[withdrawalId];
        request.user = _user;
        request.token = _token;
        request.amount = _amount;
        request.readyTime = readyTime;
        request.poolId = _poolId;
        request.executed = false;

        // Track withdrawal ID for user
        userWithdrawals[_user].push(withdrawalId);
        withdrawalCounter++;
        emit WithdrawalRegistered(withdrawalId, _user, address(_token), _amount, readyTime);

        return withdrawalId;
    }

    /**
     * @notice Execute a withdrawal after cooldown has passed
     * @param _withdrawalId ID of withdrawal request
     */
    function executeWithdrawal(uint256 _withdrawalId) external nonReentrant {
        WithdrawalRequest storage request = withdrawalRequests[_withdrawalId];

        // Validate withdrawal request
        if (request.user == address(0)) revert InvalidWithdrawalId();
        if (msg.sender != request.user) revert OnlyRequestOwner();
        if (request.executed) revert WithdrawalAlreadyExecuted();
        if (block.timestamp < request.readyTime) revert WithdrawalNotReady();

        request.executed = true;
        _removeWithdrawalId(request.user, _withdrawalId);

        // Transfer tokens to user
        request.token.safeTransfer(request.user, request.amount);

        emit WithdrawalExecuted(_withdrawalId, request.user, address(request.token), request.amount);
    }

    /**
     * @notice Execute a withdrawal without cooldown but only by the owner
     * @param _withdrawalId ID of withdrawal request
     */
    function emergencyWithdrawal(uint256 _withdrawalId) external onlyOwner {
        WithdrawalRequest storage request = withdrawalRequests[_withdrawalId];

        // Validate withdrawal request
        if (request.user == address(0)) revert InvalidWithdrawalId();
        if (request.executed) revert WithdrawalAlreadyExecuted();

        request.executed = true;
        _removeWithdrawalId(request.user, _withdrawalId);

        // Transfer tokens to user
        request.token.safeTransfer(request.user, request.amount);

        emit WithdrawalExecuted(_withdrawalId, request.user, address(request.token), request.amount);
    }

    /**
     * @notice Cancel a withdrawal request before it's executed
     * @param _withdrawalId ID of withdrawal request
     * @dev Only the requester can cancel
     */
    function cancelWithdrawal(uint256 _withdrawalId) external nonReentrant {
        WithdrawalRequest storage request = withdrawalRequests[_withdrawalId];

        if (request.user == address(0)) revert InvalidWithdrawalId();
        if (msg.sender != request.user) revert OnlyRequestOwner();
        if (request.executed) revert WithdrawalAlreadyExecuted();

        uint256 balanceBefore = request.token.balanceOf(address(this));

        // Creeate new Relic without a cooldown
        if (request.token.allowance(address(this), reliquary) > 0) {
            request.token.forceApprove(reliquary, 0);
        }
        request.token.forceApprove(reliquary, request.amount);
        try IReliquary(reliquary)
            .createRelicAndDeposit(request.user, request.poolId, request.amount) {
            if (balanceBefore - request.amount != request.token.balanceOf(address(this))) {
                revert WrongBalances();
            }
        } catch Error(string memory reason) {
            revert ReliquaryOperationFailed(reason);
        }

        request.executed = true;
        _removeWithdrawalId(request.user, _withdrawalId);

        emit WithdrawalCancelled(_withdrawalId, request.user);
    }

    /**
     * @notice Remove a withdrawal ID from a user's pending list.
     * @dev Uses swap-and-pop to efficiently remove the ID from `userWithdrawals[_user]`.
     * Emits `WithdrawalRemovedFromPending` when an ID is removed.
     * @param _user The owner of the withdrawal IDs array.
     * @param _withdrawalId The withdrawal ID to remove.
     */
    function _removeWithdrawalId(address _user, uint256 _withdrawalId) internal {
        uint256[] storage ids = userWithdrawals[_user];
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == _withdrawalId) {
                ids[i] = ids[ids.length - 1]; // Swap with last
                ids.pop(); // Remove last
                emit WithdrawalRemovedFromPending(_withdrawalId, _user);
                return;
            }
        }
    }

    /**
     * @notice Update cooldown period (only owner)
     * @param _newCooldown New cooldown period in seconds
     */
    function setCooldownPeriod(uint256 _newCooldown) external onlyOwner {
        if (_newCooldown == 0) revert InvalidCooldown();

        cooldownPeriod = _newCooldown;
        emit CooldownPeriodUpdated(_newCooldown);
    }

    /**
     * @notice Check if withdrawal is ready to execute
     * @param _withdrawalId ID of withdrawal request
     * @return True if ready, false otherwise
     */
    function isWithdrawalReady(uint256 _withdrawalId) external view returns (bool) {
        WithdrawalRequest memory request = withdrawalRequests[_withdrawalId];
        return block.timestamp >= request.readyTime && !request.executed;
    }

    /**
     * @notice Get withdrawal details
     * @param _withdrawalId ID of withdrawal request
     */
    function getWithdrawalDetails(uint256 _withdrawalId)
        external
        view
        returns (
            address user,
            address token,
            uint256 amount,
            uint256 readyTime,
            uint8 poolId,
            bool executed
        )
    {
        WithdrawalRequest memory request = withdrawalRequests[_withdrawalId];
        return (
            request.user,
            address(request.token),
            request.amount,
            request.readyTime,
            request.poolId,
            request.executed
        );
    }

    /**
     * @notice Get time remaining until withdrawal is ready
     * @param _withdrawalId ID of withdrawal request
     * @return secondsLeft Seconds until withdrawal can be executed (0 if ready)
     */
    function getTimeRemaining(uint256 _withdrawalId) external view returns (uint256) {
        WithdrawalRequest memory request = withdrawalRequests[_withdrawalId];

        if (block.timestamp >= request.readyTime) {
            return 0;
        }

        return request.readyTime - block.timestamp;
    }

    /**
     * @notice Get all withdrawal IDs for a user
     * @param _user User address
     * @return Array of withdrawal IDs
     */
    function getUserWithdrawals(address _user) external view returns (uint256[] memory) {
        return userWithdrawals[_user];
    }

    /**
     * @notice Get count of pending withdrawals for user
     * @param _user User address
     * @return Count of pending (not executed) withdrawals
     */
    function getPendingWithdrawalCount(address _user) external view returns (uint256) {
        uint256[] memory withdrawalIds = userWithdrawals[_user];
        uint256 pendingCount = 0;

        for (uint256 i = 0; i < withdrawalIds.length; i++) {
            if (!withdrawalRequests[withdrawalIds[i]].executed) {
                pendingCount++;
            }
        }
        return pendingCount;
    }
}
