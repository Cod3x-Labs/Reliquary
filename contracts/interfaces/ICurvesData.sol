// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface ICurvesData {
    function getFunction(uint256 _maturity) external view returns (uint256);
    function minMultiplier() external view returns (uint256);
}
