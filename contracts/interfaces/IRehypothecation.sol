// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

/// @notice All functions in this contract must be restricted to Reliquary.
interface IRehypothecation {
    /**
     * Rehypothecation deposit function. must be approved first.
     * @param _amt amount to deposit.
     */
    function deposit(uint256 _amt) external;

    /**
     * Rehypothecation withdraw function and send it to `msg.sender`.
     * @param _amt amount to withdraw.
     */
    function withdraw(uint256 _amt) external;

    /**
     * Claim all rewards and send it to `msg.sender`.
     * @param _receiver token receiver.
     */
    function claim(address _receiver) external;

    /**
     * Get the amount rehypothecated of `address(this)`.
     */
    function balance() external returns (uint256);
}
