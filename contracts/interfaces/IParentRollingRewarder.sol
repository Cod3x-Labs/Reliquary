// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./IRewarder.sol";

interface IParentRollingRewarder is IRewarder {
    function initialize(uint8 _poolId) external;
}
