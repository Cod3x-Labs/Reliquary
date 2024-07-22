// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "../interfaces/IRehypothecation.sol";
import "../interfaces/IReliquary.sol";
import "../interfaces/IBalancerGauge.sol";
import "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

// TODO needs to be perfectly adapted depending on the gauge version.
//! this version of `GaugeBalancer` may not be able to claim BAL tokens.
/// @dev `GaugeBalancer` is for Ethereum.
contract GaugeBalancer is IRehypothecation, Ownable {
    using SafeERC20 for IERC20;

    IReliquary public immutable reliquary;
    IBalancerGauge public immutable gauge;
    IERC20 public immutable token;

    constructor(address _reliquary, address _gauge, address _token) Ownable(_reliquary) {
        reliquary = IReliquary(_reliquary);
        gauge = IBalancerGauge(_gauge);
        token = IERC20(_token);

        // Approvals
        token.approve(_gauge, type(uint256).max);
    }

    /// ============= Externals =============

    function deposit(uint256 _amt) external onlyOwner {
        token.safeTransferFrom(msg.sender, address(this), _amt);
        gauge.deposit(_amt);
    }

    function withdraw(uint256 _amt) external onlyOwner {
        gauge.withdraw(_amt);
        token.safeTransfer(msg.sender, _amt);
    }

    function claim(address _receiver) external onlyOwner {
        gauge.claim_rewards();

        for (uint256 i = 0; i < gauge.reward_count(); i++) {
            IERC20 tokenToClaim_ = gauge.reward_tokens(i);
            uint256 amtToClaim_ = tokenToClaim_.balanceOf(address(this));
            if (amtToClaim_ != 0) tokenToClaim_.safeTransfer(_receiver, amtToClaim_);
        }
    }

    /// ============= Views =============

    function balance() external returns (uint256) {
        return gauge.balanceOf(address(this));
    }
}
