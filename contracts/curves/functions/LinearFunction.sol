// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "contracts/interfaces/IFunction.sol";

contract LinearFunction is IFunction {
    uint256 public slope;
    uint256 public minMultiplier; // getFunction(0) = minMultiplier

    error LinearFunction__MIN_MULTIPLIER_MUST_GREATER_THAN_ZERO();

    constructor(uint256 _slope, uint256 _minMultiplier) {
        if (_minMultiplier == 0)
            revert LinearFunction__MIN_MULTIPLIER_MUST_GREATER_THAN_ZERO();
        slope = _slope; // uint256 force the "strictly increasing" rule
        minMultiplier = _minMultiplier;
    }

    function getFunction(uint256 _maturity) external view returns (uint256) {
        return _maturity * slope + minMultiplier;
    }
}
