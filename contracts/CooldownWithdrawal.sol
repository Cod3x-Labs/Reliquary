// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IReliquary} from "contracts/interfaces/IReliquary.sol";
import {ICooldownWithdrawal} from "contracts/interfaces/ICooldownWithdrawal.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title CooldownWithdrawal
 * @dev Contract that delays withdrawals by a specific cooldown period
 * Other contracts call registerWithdrawal() to initiate a withdrawal request
 * After cooldown expires, users can call executeWithdrawal() to claim tokens
 */
contract CooldownWithdrawal is ReentrancyGuard, ICooldownWithdrawal, Ownable, Pausable {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_PENDING_WITHDRAWALS = 500;

    /// @inheritdoc ICooldownWithdrawal
    uint64 public cooldownPeriod;

    /// @inheritdoc ICooldownWithdrawal
    uint256 public withdrawalCounter;

    /// @inheritdoc ICooldownWithdrawal
    address public immutable reliquary;

    // Mapping: withdrawal ID => WithdrawalRequest
    mapping(uint256 => WithdrawalRequest) private withdrawalRequests;

    // Mapping: user => array of withdrawal IDs
    mapping(address => uint256[]) private userPendingWithdrawals;

    /**
     * @notice Initialize cooldown contract
     * @param _cooldownPeriod Cooldown period in seconds
     */
    constructor(uint64 _cooldownPeriod, address _reliquary) Ownable(msg.sender) {
        if (_reliquary == address(0)) revert WrongReliquaryAddress();
        reliquary = _reliquary;
        _setCooldownPeriod(_cooldownPeriod);
    }

    /**
     * @notice Pause all functions except `emergencyWithdraw()`.
     * @dev Restricted to the OWNER role.
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause.
     * @dev Restricted to the OWNER role.
     */
    function unpause() public onlyOwner {
        _unpause();
    }

    /// @inheritdoc ICooldownWithdrawal
    function registerWithdrawal(address _user, uint8 _poolId, uint256 _amount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        if (_amount == 0) revert ZeroAmount();
        if (_user == address(0)) revert InvalidUser();
        if (msg.sender != reliquary) revert OnlyReliquary();
        if (type(uint256).max - withdrawalCounter < 1) {
            revert InvalidWithdrawalCounter();
        }
        if (userPendingWithdrawals[_user].length >= MAX_PENDING_WITHDRAWALS) {
            revert TooManyPendingWithdrawals(); // Prevent spam
        }

        IERC20 _token = IERC20(IReliquary(reliquary).getPoolInfo(_poolId).poolToken);
        _token.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 withdrawalId = withdrawalCounter;
        uint64 readyTime = uint64(block.timestamp + cooldownPeriod); // cooldown period limited to 1000 days so not possible to overflow it

        WithdrawalRequest storage request = withdrawalRequests[withdrawalId];
        request.user = _user;
        request.token = address(_token);
        request.amount = _amount;
        request.readyTime = readyTime;
        request.poolId = _poolId;
        request.executed = false;

        // Track withdrawal ID for user
        userPendingWithdrawals[_user].push(withdrawalId);
        withdrawalCounter++;
        emit WithdrawalRegistered(withdrawalId, _user, address(_token), _amount, readyTime);

        return withdrawalId;
    }

    /// @inheritdoc ICooldownWithdrawal
    function executeWithdrawal(uint256 _withdrawalId) external nonReentrant whenNotPaused {
        WithdrawalRequest storage request = withdrawalRequests[_withdrawalId];

        // Validate withdrawal request
        if (request.user == address(0)) revert InvalidWithdrawalId();
        if (msg.sender != request.user) revert OnlyRequestOwner();
        if (request.executed) revert WithdrawalAlreadyExecuted();
        if (block.timestamp < request.readyTime) revert WithdrawalNotReady();

        request.executed = true;
        _removeWithdrawalId(request.user, _withdrawalId);

        // Transfer tokens to user
        IERC20(request.token).safeTransfer(request.user, request.amount);

        emit WithdrawalExecuted(_withdrawalId, request.user, request.token, request.amount);
    }

    /// @inheritdoc ICooldownWithdrawal
    function emergencyWithdrawal(uint256 _withdrawalId) external onlyOwner nonReentrant {
        WithdrawalRequest storage request = withdrawalRequests[_withdrawalId];

        // Validate withdrawal request
        if (request.user == address(0)) revert InvalidWithdrawalId();
        if (request.executed) revert WithdrawalAlreadyExecuted();

        request.executed = true;
        _removeWithdrawalId(request.user, _withdrawalId);

        // Transfer tokens to user
        IERC20(request.token).safeTransfer(request.user, request.amount);

        emit WithdrawalExecuted(_withdrawalId, request.user, request.token, request.amount);
    }

    /// @inheritdoc ICooldownWithdrawal
    function cancelWithdrawal(uint256 _withdrawalId) external nonReentrant whenNotPaused {
        WithdrawalRequest storage request = withdrawalRequests[_withdrawalId];

        if (request.user == address(0)) revert InvalidWithdrawalId();
        if (msg.sender != request.user) revert OnlyRequestOwner();
        if (request.executed) revert WithdrawalAlreadyExecuted();

        uint256 balanceBefore = IERC20(request.token).balanceOf(address(this));

        // Creeate new Relic without a cooldown
        IERC20(request.token).forceApprove(reliquary, request.amount);
        try IReliquary(reliquary)
            .createRelicAndDeposit(request.user, request.poolId, request.amount) {
            if (balanceBefore - request.amount != IERC20(request.token).balanceOf(address(this))) {
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
     * @dev Uses swap-and-pop to efficiently remove the ID from `userPendingWithdrawals[_user]`.
     * Emits `WithdrawalRemovedFromPending` when an ID is removed.
     * @param _user The owner of the withdrawal IDs array.
     * @param _withdrawalId The withdrawal ID to remove.
     */
    function _removeWithdrawalId(address _user, uint256 _withdrawalId) internal {
        uint256[] storage ids = userPendingWithdrawals[_user];
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == _withdrawalId) {
                ids[i] = ids[ids.length - 1]; // Swap with last
                ids.pop(); // Remove last
                emit WithdrawalRemovedFromPending(_withdrawalId, _user);
                return;
            }
        }
    }

    /// @inheritdoc ICooldownWithdrawal
    function setCooldownPeriod(uint64 _newCooldown) external onlyOwner {
        _setCooldownPeriod(_newCooldown);
    }

    function _setCooldownPeriod(uint64 _newCooldown) private onlyOwner {
        if (_newCooldown == 0 || _newCooldown > 1000 days) revert InvalidCooldown();

        cooldownPeriod = _newCooldown;
        emit CooldownPeriodUpdated(_newCooldown);
    }

    /// @inheritdoc ICooldownWithdrawal
    function isWithdrawalReady(uint256 _withdrawalId) external view returns (bool) {
        WithdrawalRequest memory request = withdrawalRequests[_withdrawalId];
        return block.timestamp >= request.readyTime && !request.executed;
    }

    /// @inheritdoc ICooldownWithdrawal
    function getWithdrawalDetails(uint256 _withdrawalId)
        external
        view
        returns (WithdrawalRequest memory)
    {
        return withdrawalRequests[_withdrawalId];
    }

    /// @inheritdoc ICooldownWithdrawal
    function getTimeRemaining(uint256 _withdrawalId) external view returns (uint256) {
        WithdrawalRequest memory request = withdrawalRequests[_withdrawalId];

        if (block.timestamp >= request.readyTime) {
            return 0;
        }
        return request.readyTime - block.timestamp;
    }

    /// @inheritdoc ICooldownWithdrawal
    function getUserPendingWithdrawals(address _user) external view returns (uint256[] memory) {
        return userPendingWithdrawals[_user];
    }

    /// @inheritdoc ICooldownWithdrawal
    function getUserPendingWithdrawalsLength(address _user) external view returns (uint256) {
        return userPendingWithdrawals[_user].length;
    }

    /// @inheritdoc ICooldownWithdrawal
    function getUserWithdrawalsDetails(address _user)
        external
        view
        returns (WithdrawalRequest[] memory userWithdrawalsDetails)
    {
        uint256[] memory userWithdrawalIds = userPendingWithdrawals[_user];
        userWithdrawalsDetails = new WithdrawalRequest[](userWithdrawalIds.length);
        for (uint256 idx = 0; idx < userWithdrawalIds.length; idx++) {
            userWithdrawalsDetails[idx] = withdrawalRequests[userWithdrawalIds[idx]];
        }
    }
}
