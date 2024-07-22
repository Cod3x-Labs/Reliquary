// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface ICurves {
    function getFunction(uint256 _maturity) external view returns (uint256);
}
