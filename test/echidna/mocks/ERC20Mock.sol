// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { ERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract ERC20Mock is ERC20 {
    uint8 public immutable dec;

    constructor(uint8 _dec)  ERC20("ERC20Mock", "E20M") {
        dec = _dec;
    }

    function mint(address _to, uint256 _amount) public {
        _mint(_to, _amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    /// @dev usdc and usdt have 6 decimals
    function decimals() public view override returns (uint8) {
        return dec;
    }

}
