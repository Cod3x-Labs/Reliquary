// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "openzeppelin-contracts/contracts/interfaces/IERC20.sol";

interface IBalancerGauge {
    function deposit(uint256 _value) external;

    function withdraw(uint256 _value) external;

    function lp_token() external view returns (IERC20);

    function reward_tokens(uint256 _index) external view returns (IERC20);

    function claim_rewards() external;

    function get_rewards() external;

    function claimable_reward(address _rewardToken, address _user)
        external
        view
        returns (uint256);

    function claimable_tokens(address _user) external view returns (uint256);

    function is_killed() external view returns (bool);

    function reward_count() external returns (uint256);

    function MAX_REWARDS() external returns (uint256);

    function balanceOf(address _user) external returns (uint256);
}
