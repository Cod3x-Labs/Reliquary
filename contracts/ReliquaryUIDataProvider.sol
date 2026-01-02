// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "./interfaces/IReliquaryData.sol";

interface IERC20 {
    function decimals() external view returns (uint);
    function balanceOf(address account) external view returns (uint256);
}

interface IParentRewarder {
    function getChildrenRewarders() external view returns (address[] memory childRewarders);
}

interface IChildRewarder {
    function rewardPerSecond() external view returns (uint rewardPerSecond);
    function lastDistributionTime() external view returns (uint lastDistributionTime);
    function rewardToken() external view returns (address rewardToken);
    function pendingToken(uint positionId) external view returns (uint pendingReward);
}

struct Token {
    uint decimals;
    address tokenAddress;
}

struct PoolIncentive {
    uint rewardPerSecond;
    uint lastDistributionTime;
    Token token;
}

struct Pool {
    uint poolId;
    uint accRewardPerShare;
    uint lastRewardTime;
    uint allocPoint;
    uint allocPointShare;
    uint stakedTokens;
    string name;
    bool allowPartialWithdrawals;
    Token token;
    PoolIncentive[] poolIncentives;
}

struct PositionPendingReward {
    uint pendingReward;
    Token token;
}

struct Position {
    uint relicId;
    uint amount;
    uint rewardDebt;
    uint rewardCredit;
    uint entry;
    uint poolId;
    uint level;
    uint maturityMultiplier;
    Pool pool;
    PositionPendingReward[] pendingRewards;
}


/**
* @dev A utility contract to get all the necessary data for the UI without repeated calls
*/
contract ReliquaryUIDataProvider {
    address public reliquaryAddress;
    uint public constant REWARD_PER_SECOND_PRECISION = 10_000;

    constructor(address _reliquaryAddress) {
        reliquaryAddress = _reliquaryAddress;
    }

    function getDecimals(address tokenAddress) internal view returns (uint) {
        IERC20 token = IERC20(tokenAddress);
        return token.decimals();
    }

    function getChildRewardersForPool(uint poolId) public view returns (address[] memory childRewarders) {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);
        PoolInfo memory poolInfo = reliquary.getPoolInfo(uint8(poolId));
        address parentRewarderAddress = poolInfo.rewarder;
        IParentRewarder parentRewarder = IParentRewarder(parentRewarderAddress);
        childRewarders = parentRewarder.getChildrenRewarders();
    }

    function getChildIncentiveDetails(address childRewarderAddress) public view returns (PoolIncentive memory childIncentive) {
        IChildRewarder childRewarderContract = IChildRewarder(childRewarderAddress);
        uint rewardPerSecond = childRewarderContract.rewardPerSecond();
        uint lastDistributionTime = childRewarderContract.lastDistributionTime();
        address rewardToken = childRewarderContract.rewardToken();
        uint decimals = getDecimals(rewardToken);

        childIncentive = PoolIncentive(
            rewardPerSecond / REWARD_PER_SECOND_PRECISION,
            lastDistributionTime,
            Token(decimals, rewardToken)
        );
    }

    function getChildRewarderPendingRewardDetails(address childRewarderAddress, uint positionId) public view returns (PositionPendingReward memory childReward) {
        IChildRewarder childRewarderContract = IChildRewarder(childRewarderAddress);
        uint pendingReward = childRewarderContract.pendingToken(positionId);
        address rewardToken = childRewarderContract.rewardToken();
        uint decimals = getDecimals(rewardToken);
        childReward = PositionPendingReward(
            pendingReward,
            Token(decimals, rewardToken)
        );
    }

    /**
    *
    * ----------------------------------- External --------------------------------------
    *
    */
    function getPageOfPools(uint page, uint pageSize) external view returns (Pool[] memory pools) {
        uint poolLength = getPoolLength();
        uint start = page * pageSize;
        uint end = start + pageSize;
        if (end > poolLength) {
            end = poolLength;
        }
        pools = new Pool[](end - start);
        for (uint i = start; i < end; i++) {
            pools[i - start] = getPool(i);
        }
    }

    function getPageOfPositions(address user, uint page, uint pageSize) external view returns (Position[] memory positions) {
        uint userPositionLength = getUserPositionLength(user);
        uint start = page * pageSize;
        uint end = start + pageSize;
        if (end > userPositionLength) {
            end = userPositionLength;
        }
        positions = new Position[](end - start);
        for (uint i = start; i < end; i++) {
            positions[i - start] = getPosition(tokenOfOwnerByIndex(user, i));
        }
    }

    function getPool(uint poolId) public view returns (Pool memory pool) {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);

        PoolInfo memory poolInfo = reliquary.getPoolInfo(uint8(poolId));

        address underlyingTokenAddress = poolInfo.poolToken;
        address reliquaryRewardTokenAddress = reliquary.rewardToken();

        uint rate = reliquary.emissionRate();

        address[] memory childRewarders = getChildRewardersForPool(poolId);
        PoolIncentive[] memory incentives = new PoolIncentive[](childRewarders.length + 1);

        incentives[0] = PoolIncentive(
            rate,
            type(uint256).max,
            Token(getDecimals(reliquaryRewardTokenAddress), reliquaryRewardTokenAddress)
        );

        for (uint i = 0; i < childRewarders.length; i++) {
            incentives[i + 1] = getChildIncentiveDetails(childRewarders[i]);
        }

        uint stakedTokens = IERC20(underlyingTokenAddress).balanceOf(reliquaryAddress);

        pool = Pool(
            poolId,
            poolInfo.accRewardPerShare,
            poolInfo.lastRewardTime,
            poolInfo.allocPoint,
            poolInfo.allocPoint / reliquary.totalAllocPoint(),
            stakedTokens,
            poolInfo.name,
            poolInfo.allowPartialWithdrawals,
            Token(getDecimals(underlyingTokenAddress), underlyingTokenAddress),
            incentives
        );
    }

    function getPoolLength() public view returns (uint) {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);
        return reliquary.poolLength();
    }

    function getPosition(uint relicId) public view returns (Position memory position) {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);
        PositionInfo memory positionInfo = reliquary.getPositionForId(relicId);
        PoolInfo memory poolInfo = reliquary.getPoolInfo(uint8(positionInfo.poolId));

        ICurvesData curve = poolInfo.curve;
        uint maturityMultiplier = curve.getFunction(positionInfo.level) * REWARD_PER_SECOND_PRECISION / curve.minMultiplier();

        address reliquaryRewardTokenAddress = reliquary.rewardToken();
        uint reliquaryPendingRewardAmount = reliquary.pendingReward(relicId);

        uint reliquaryRewardTokenDecimals = getDecimals(reliquaryRewardTokenAddress);

        PositionPendingReward memory reliquaryPendingReward = PositionPendingReward(
            reliquaryPendingRewardAmount,
            Token(reliquaryRewardTokenDecimals, reliquaryRewardTokenAddress)
        );

        address[] memory childRewarders = getChildRewardersForPool(positionInfo.poolId);
        PositionPendingReward[] memory pendingRewards = new PositionPendingReward[](childRewarders.length + 1);
        pendingRewards[0] = reliquaryPendingReward;
        for (uint i = 0; i < childRewarders.length; i++) {
            pendingRewards[i + 1] = getChildRewarderPendingRewardDetails(childRewarders[i], relicId);
        }

        Pool memory pool = getPool(positionInfo.poolId);

        position = Position(
            relicId,
            positionInfo.amount,
            positionInfo.rewardDebt,
            positionInfo.rewardCredit,
            positionInfo.entry,
            positionInfo.poolId,
            positionInfo.level,
            maturityMultiplier,
            pool,
            pendingRewards
        );
    }

    function getUserPositionLength(address user) public view returns (uint userPositionLength) {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);
        userPositionLength = reliquary.balanceOf(user);
    }

    function tokenOfOwnerByIndex(address owner, uint index) public view returns (uint userPositionLength) {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);
        userPositionLength = reliquary.tokenOfOwnerByIndex(owner, index);
    }

}