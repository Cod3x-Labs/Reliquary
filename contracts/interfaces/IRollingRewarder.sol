// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "./IRewarder.sol";

interface IRollingRewarder is IRewarder {
    function fund(uint256 _amount) external;
}
