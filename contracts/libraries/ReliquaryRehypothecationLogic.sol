// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IReliquary.sol";
import "../interfaces/IRehypothecation.sol";

library ReliquaryRehypothecationLogic {
    using SafeERC20 for IERC20;

    function _enableRehypothecation(PoolInfo storage pool, address _rehypothecation) internal {
        if (_rehypothecation != address(0)) {
            IERC20(pool.poolToken).approve(_rehypothecation, type(uint256).max);
            pool.rehypothecation = _rehypothecation;
            _deposit(pool);
        }
    }

    function _disableRehypothecation(
        PoolInfo storage pool,
        address _rewardReceiver,
        bool _claimRewards
    ) internal {
        address rehypothecation_ = pool.rehypothecation;
        if (rehypothecation_ != address(0)) {
            uint256 balance_ = IRehypothecation(rehypothecation_).balance();
            _withdraw(pool, balance_);

            if (_claimRewards) _claim(pool, _rewardReceiver);

            pool.rehypothecation = address(0);
        }
    }

    function _deposit(PoolInfo storage pool) internal {
        address rehypothecation_ = pool.rehypothecation;
        if (rehypothecation_ != address(0)) {
            uint256 balance_ = IERC20(pool.poolToken).balanceOf(address(this));
            if (balance_ != 0) {
                IRehypothecation(rehypothecation_).deposit(balance_);
            }
        }
    }

    function _withdraw(PoolInfo storage pool, uint256 _amount) internal {
        address rehypothecation_ = pool.rehypothecation;
        if (rehypothecation_ != address(0) && _amount != 0) {
            IRehypothecation(rehypothecation_).withdraw(_amount);
        }
    }

    function _claim(PoolInfo storage pool, address _rewardReceiver) internal {
        address rehypothecation_ = pool.rehypothecation;
        if (rehypothecation_ != address(0)) {
            IRehypothecation(rehypothecation_).claim(_rewardReceiver);
        }
    }
}
