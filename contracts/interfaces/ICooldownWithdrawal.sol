// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ICooldownWithdrawal
 * @dev Interface for the CooldownWithdrawal contract that delays withdrawals by a cooldown period
 */
interface ICooldownWithdrawal {
    // ============ Struct ============
    // Withdrawal request structure
    struct WithdrawalRequest {
        address user;
        address token;
        uint256 amount;
        uint64 readyTime; // Timestamp when withdrawal can be executed
        uint8 poolId;
        bool executed;
    }

    // ============ Events ============
    event WithdrawalRegistered(
        uint256 indexed withdrawalId,
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 readyTime
    );

    event WithdrawalExecuted(
        uint256 indexed withdrawalId, address indexed user, address indexed token, uint256 amount
    );

    event WithdrawalCancelled(uint256 indexed withdrawalId, address indexed user);

    event CooldownPeriodUpdated(uint64 newCooldown);

    event WithdrawalRemovedFromPending(uint256 indexed withdrawalId, address indexed user);

    // ============ Errors ============

    error OnlyRequestOwner();
    error OnlyReliquary();
    error InvalidCooldown();
    error WrongReliquaryAddress();
    error WithdrawalNotReady();
    error WithdrawalAlreadyExecuted();
    error ReliquaryOperationFailed(string);
    error InvalidUser();
    error InvalidWithdrawalId();
    error InvalidWithdrawalCounter();
    error TooManyPendingWithdrawals();
    error InsufficientBalance();
    error TransferFailed();
    error ZeroAmount();
    error WrongBalances();

    // ============ State Variables ============

    /**
     * @notice Current cooldown period in seconds
     * @return cooldown period value
     */
    function cooldownPeriod() external view returns (uint64);

    /**
     * @notice Total number of withdrawal requests created (counter)
     * @return current withdrawal counter
     */
    function withdrawalCounter() external view returns (uint256);

    /**
     * @notice Address of the associated Reliquary contract
     * @return reliquary contract address
     */
    function reliquary() external view returns (address);

    // ============ Core Functions ============

    /**
     * @notice Register a withdrawal request (called by external contract)
     * @dev External contract sends tokens to this contract first, then calls registerWithdrawal
     * @param _user Address of user requesting withdrawal
     * @param _poolId Token to withdraw (ERC20)
     * @param _amount Amount to withdraw
     * @return withdrawalId ID of the withdrawal request
     */
    function registerWithdrawal(address _user, uint8 _poolId, uint256 _amount)
        external
        returns (uint256);

    /**
     * @notice Execute a withdrawal after cooldown has passed
     * @param _withdrawalId ID of withdrawal request
     */
    function executeWithdrawal(uint256 _withdrawalId) external;

    /**
     * @notice Cancel a withdrawal request before it's executed
     * @param _withdrawalId ID of withdrawal request
     * @dev Only the requester can cancel
     */
    function cancelWithdrawal(uint256 _withdrawalId) external;

    /**
     * @notice Update cooldown period (only owner)
     * @param _newCooldown New cooldown period in seconds
     */
    function setCooldownPeriod(uint64 _newCooldown) external;

    /**
     * @notice Emergency withdrawal by owner
     * @param _withdrawalId ID of withdrawal request
     */
    function emergencyWithdrawal(uint256 _withdrawalId) external;

    // ============ View Functions ============

    /**
     * @notice Check if withdrawal is ready to execute
     * @param _withdrawalId ID of withdrawal request
     * @return True if ready, false otherwise
     */
    function isWithdrawalReady(uint256 _withdrawalId) external view returns (bool);

    /**
     * @notice Get withdrawal details
     * @param _withdrawalId ID of withdrawal request
     */
    function getWithdrawalDetails(uint256 _withdrawalId)
        external
        view
        returns (WithdrawalRequest memory);

    /**
     * @notice Get time remaining until withdrawal is ready
     * @param _withdrawalId ID of withdrawal request
     * @return secondsLeft Seconds until withdrawal can be executed (0 if ready)
     */
    function getTimeRemaining(uint256 _withdrawalId) external view returns (uint256);

    /**
     * @notice Get all withdrawal IDs for a user
     * @param _user User address
     * @return Array of withdrawal IDs
     */
    function getUserPendingWithdrawals(address _user) external view returns (uint256[] memory);

    /**
     * @notice Get count of pending withdrawals for user
     * @param _user User address
     * @return Count of pending (not executed) withdrawals
     */
    function getUserPendingWithdrawalsLength(address _user) external view returns (uint256);

    /**
     * @notice Get full `WithdrawalRequest` structs for all pending withdrawals of a user
     * @param _user User address
     * @return userWithdrawalsDetails Array of `WithdrawalRequest` structs for the user
     */
    function getUserWithdrawalsDetails(address _user)
        external
        view
        returns (WithdrawalRequest[] memory userWithdrawalsDetails);
}
