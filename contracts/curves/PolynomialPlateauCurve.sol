// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "contracts/interfaces/ICurves.sol";

contract PolynomialPlateauCurve is ICurves {
    uint256 private constant WAD = 1e18;

    int256[] public coefficients;
    uint256 public immutable plateauLevel = type(uint256).max;
    uint256 public immutable plateauMultiplier;

    /// @dev coefficients calculator helper: https://www.desmos.com/calculator/nic7esjsbe
    //  ex: [100e18, 1e18, 5e15, -1e13, 5e9]
    //!  We allow int coefficients, but developers must make sure that ∀x > 0 => getFunction(x) > 0
    constructor(int256[] memory _coefficients, uint256 _plateauLevel) {
        coefficients = _coefficients; // Coefficients must be expressed in WAD.
        plateauMultiplier = getFunction(_plateauLevel);
        plateauLevel = _plateauLevel;
    }

    function getFunction(uint256 _level) public view returns (uint256) {
        if (_level >= plateauLevel) return plateauMultiplier;

        int256 result_ = coefficients[0];
        for (uint256 i = 1; i < coefficients.length; i++) {
            result_ += coefficients[i] * int256(_level ** i);
        }
        return uint256(result_) / WAD;
    }
}
