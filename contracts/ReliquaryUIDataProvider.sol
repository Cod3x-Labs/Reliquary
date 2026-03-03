// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "./interfaces/IReliquaryData.sol";
import "./interfaces/ICooldownWithdrawal.sol";

interface IERC20 {
    function decimals() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function symbol() external view returns (string memory);
}

interface IParentRewarder {
    function getChildrenRewarders() external view returns (address[] memory childRewarders);
}

interface IChildRewarder {
    function rewardPerSecond() external view returns (uint256 rewardPerSecond);
    function lastDistributionTime() external view returns (uint256 lastDistributionTime);
    function rewardToken() external view returns (address rewardToken);
    function pendingToken(uint256 positionId) external view returns (uint256 pendingReward);
}

struct Token {
    uint256 decimals;
    address tokenAddress;
    string symbol;
}

struct PoolIncentive {
    uint256 rewardPerSecond;
    uint256 lastDistributionTime;
    Token token;
}

struct Pool {
    uint256 poolId;
    uint256 accRewardPerShare;
    uint256 lastRewardTime;
    uint256 allocPoint;
    uint256 allocPointShare;
    uint256 stakedTokens;
    string name;
    bool allowPartialWithdrawals;
    Token token;
    address rewarder;
    address nftDescriptor;
    address curve;
    PoolIncentive[] poolIncentives;
}

struct PositionPendingReward {
    uint256 pendingReward;
    Token token;
}

struct Position {
    uint256 relicId;
    address owner;
    uint256 amount;
    uint256 rewardDebt;
    uint256 rewardCredit;
    uint256 entry;
    uint256 poolId;
    uint256 level;
    uint256 maturityMultiplier;
    Pool pool;
    PositionPendingReward[] pendingRewards;
}

struct ReliquaryInfo {
    address reliquaryAddress;
    address rewardToken;
    Token rewardTokenInfo;
    uint256 emissionRate;
    uint256 totalAllocPoint;
    uint256 minStakingAmount;
    address cooldownWithdrawal;
    uint64 cooldownPeriod;
    bool paused;
    uint256 poolCount;
}

struct UserSummary {
    address user;
    uint256 positionCount;
    uint256[] relicIds;
    uint256 totalPendingReward;
}

struct PendingWithdrawal {
    uint256 withdrawalId;
    address user;
    address token;
    uint256 amount;
    uint64 readyTime;
    uint8 poolId;
    bool executed;
    uint256 timeRemaining;
    bool isReady;
}

/**
 * @dev A utility contract to get all the necessary data for the UI without repeated calls
 */
contract ReliquaryUIDataProvider {
    address public reliquaryAddress;
    uint256 public constant REWARD_PER_SECOND_PRECISION = 10_000;

    constructor(address _reliquaryAddress) {
        reliquaryAddress = _reliquaryAddress;
    }

    function getDecimals(address tokenAddress) internal view returns (uint256) {
        IERC20 token = IERC20(tokenAddress);
        return token.decimals();
    }

    function getTokenInfo(address tokenAddress) internal view returns (Token memory) {
        IERC20 token = IERC20(tokenAddress);
        return Token(token.decimals(), tokenAddress, token.symbol());
    }

    function getChildRewardersForPool(uint256 poolId)
        public
        view
        returns (address[] memory childRewarders)
    {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);
        PoolInfo memory poolInfo = reliquary.getPoolInfo(uint8(poolId));
        address parentRewarderAddress = poolInfo.rewarder;
        IParentRewarder parentRewarder = IParentRewarder(parentRewarderAddress);
        childRewarders = parentRewarder.getChildrenRewarders();
    }

    function getChildIncentiveDetails(address childRewarderAddress)
        public
        view
        returns (PoolIncentive memory childIncentive)
    {
        IChildRewarder childRewarderContract = IChildRewarder(childRewarderAddress);
        uint256 rewardPerSecond = childRewarderContract.rewardPerSecond();
        uint256 lastDistributionTime = childRewarderContract.lastDistributionTime();
        address rewardToken = childRewarderContract.rewardToken();

        childIncentive = PoolIncentive(
            rewardPerSecond / REWARD_PER_SECOND_PRECISION,
            lastDistributionTime,
            getTokenInfo(rewardToken)
        );
    }

    function getChildRewarderPendingRewardDetails(address childRewarderAddress, uint256 positionId)
        public
        view
        returns (PositionPendingReward memory childReward)
    {
        IChildRewarder childRewarderContract = IChildRewarder(childRewarderAddress);
        uint256 pendingReward = childRewarderContract.pendingToken(positionId);
        address rewardTokenAddress = childRewarderContract.rewardToken();
        childReward = PositionPendingReward(pendingReward, getTokenInfo(rewardTokenAddress));
    }

    /**
     *
     * ----------------------------------- External --------------------------------------
     *
     */
    function getPageOfPools(uint256 page, uint256 pageSize)
        external
        view
        returns (Pool[] memory pools)
    {
        uint256 poolLength = getPoolLength();
        uint256 start = page * pageSize;
        uint256 end = start + pageSize;
        if (end > poolLength) {
            end = poolLength;
        }
        pools = new Pool[](end - start);
        for (uint256 i = start; i < end; i++) {
            pools[i - start] = getPool(i);
        }
    }

    function getPageOfPositions(address user, uint256 page, uint256 pageSize)
        external
        view
        returns (Position[] memory positions)
    {
        uint256 userPositionLength = getUserPositionLength(user);
        uint256 start = page * pageSize;
        uint256 end = start + pageSize;
        if (end > userPositionLength) {
            end = userPositionLength;
        }
        positions = new Position[](end - start);
        for (uint256 i = start; i < end; i++) {
            positions[i - start] = getPosition(tokenOfOwnerByIndex(user, i));
        }
    }

    function getPool(uint256 poolId) public view returns (Pool memory pool) {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);

        PoolInfo memory poolInfo = reliquary.getPoolInfo(uint8(poolId));

        address underlyingTokenAddress = poolInfo.poolToken;
        address reliquaryRewardTokenAddress = reliquary.rewardToken();

        uint256 rate = reliquary.emissionRate();

        address[] memory childRewarders = getChildRewardersForPool(poolId);
        PoolIncentive[] memory incentives = new PoolIncentive[](childRewarders.length + 1);

        incentives[0] =
            PoolIncentive(rate, type(uint256).max, getTokenInfo(reliquaryRewardTokenAddress));

        for (uint256 i = 0; i < childRewarders.length; i++) {
            incentives[i + 1] = getChildIncentiveDetails(childRewarders[i]);
        }

        uint256 stakedTokens = IERC20(underlyingTokenAddress).balanceOf(reliquaryAddress);

        pool = Pool(
            poolId,
            poolInfo.accRewardPerShare,
            poolInfo.lastRewardTime,
            poolInfo.allocPoint,
            poolInfo.allocPoint / reliquary.totalAllocPoint(),
            stakedTokens,
            poolInfo.name,
            poolInfo.allowPartialWithdrawals,
            getTokenInfo(underlyingTokenAddress),
            poolInfo.rewarder,
            poolInfo.nftDescriptor,
            address(poolInfo.curve),
            incentives
        );
    }

    function getPoolLength() public view returns (uint256) {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);
        return reliquary.poolLength();
    }

    function getPosition(uint256 relicId) public view returns (Position memory position) {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);
        PositionInfo memory positionInfo = reliquary.getPositionForId(relicId);

        position.relicId = relicId;
        position.owner = reliquary.ownerOf(relicId);
        position.amount = positionInfo.amount;
        position.rewardDebt = positionInfo.rewardDebt;
        position.rewardCredit = positionInfo.rewardCredit;
        position.entry = positionInfo.entry;
        position.poolId = positionInfo.poolId;
        position.level = positionInfo.level;
        position.maturityMultiplier =
            _getMaturityMultiplier(positionInfo.poolId, positionInfo.level);
        position.pool = getPool(positionInfo.poolId);
        position.pendingRewards = _getPendingRewards(reliquary, relicId, positionInfo.poolId);
    }

    function _getMaturityMultiplier(uint8 poolId, uint256 level) internal view returns (uint256) {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);
        PoolInfo memory poolInfo = reliquary.getPoolInfo(poolId);
        ICurvesData curve = poolInfo.curve;
        return curve.getFunction(level) * REWARD_PER_SECOND_PRECISION / curve.minMultiplier();
    }

    function _getPendingRewards(IReliquaryData reliquary, uint256 relicId, uint256 poolId)
        internal
        view
        returns (PositionPendingReward[] memory pendingRewards)
    {
        address[] memory childRewarders = getChildRewardersForPool(poolId);
        pendingRewards = new PositionPendingReward[](childRewarders.length + 1);

        pendingRewards[0] = PositionPendingReward(
            reliquary.pendingReward(relicId), getTokenInfo(reliquary.rewardToken())
        );

        for (uint256 i = 0; i < childRewarders.length; i++) {
            pendingRewards[i + 1] = getChildRewarderPendingRewardDetails(childRewarders[i], relicId);
        }
    }

    function getUserPositionLength(address user) public view returns (uint256 userPositionLength) {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);
        userPositionLength = reliquary.balanceOf(user);
    }

    function tokenOfOwnerByIndex(address owner, uint256 index)
        public
        view
        returns (uint256 userPositionLength)
    {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);
        userPositionLength = reliquary.tokenOfOwnerByIndex(owner, index);
    }

    function getReliquaryInfo() external view returns (ReliquaryInfo memory info) {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);
        address rewardTokenAddress = reliquary.rewardToken();
        address cooldownWithdrawalAddress = reliquary.cooldownWithdrawal();

        uint64 cooldownPeriod = 0;
        if (cooldownWithdrawalAddress != address(0)) {
            cooldownPeriod = ICooldownWithdrawal(cooldownWithdrawalAddress).cooldownPeriod();
        }

        info = ReliquaryInfo(
            reliquaryAddress,
            rewardTokenAddress,
            getTokenInfo(rewardTokenAddress),
            reliquary.emissionRate(),
            reliquary.totalAllocPoint(),
            reliquary.minStakingAmount(),
            cooldownWithdrawalAddress,
            cooldownPeriod,
            reliquary.paused(),
            reliquary.poolLength()
        );
    }

    function getUserSummary(address user) external view returns (UserSummary memory summary) {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);
        uint256 positionCount = reliquary.balanceOf(user);

        uint256[] memory relicIds = new uint256[](positionCount);
        uint256 totalPendingReward = 0;

        for (uint256 i = 0; i < positionCount; i++) {
            uint256 relicId = reliquary.tokenOfOwnerByIndex(user, i);
            relicIds[i] = relicId;
            totalPendingReward += reliquary.pendingReward(relicId);
        }

        summary = UserSummary(user, positionCount, relicIds, totalPendingReward);
    }

    function getAllUserRelicIds(address user) external view returns (uint256[] memory relicIds) {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);
        uint256 positionCount = reliquary.balanceOf(user);
        relicIds = new uint256[](positionCount);

        for (uint256 i = 0; i < positionCount; i++) {
            relicIds[i] = reliquary.tokenOfOwnerByIndex(user, i);
        }
    }

    function getAllUserPositions(address user) external view returns (Position[] memory positions) {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);
        uint256 positionCount = reliquary.balanceOf(user);
        positions = new Position[](positionCount);

        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = getPosition(reliquary.tokenOfOwnerByIndex(user, i));
        }
    }

    function getUserPendingWithdrawals(address user)
        external
        view
        returns (PendingWithdrawal[] memory withdrawals)
    {
        IReliquaryData reliquary = IReliquaryData(reliquaryAddress);
        address cooldownWithdrawalAddress = reliquary.cooldownWithdrawal();

        if (cooldownWithdrawalAddress == address(0)) {
            return new PendingWithdrawal[](0);
        }

        ICooldownWithdrawal cooldown = ICooldownWithdrawal(cooldownWithdrawalAddress);
        uint256[] memory withdrawalIds = cooldown.getUserPendingWithdrawals(user);

        withdrawals = new PendingWithdrawal[](withdrawalIds.length);

        for (uint256 i = 0; i < withdrawalIds.length; i++) {
            uint256 withdrawalId = withdrawalIds[i];
            ICooldownWithdrawal.WithdrawalRequest memory request =
                cooldown.getWithdrawalDetails(withdrawalId);

            withdrawals[i] = PendingWithdrawal(
                withdrawalId,
                request.user,
                request.token,
                request.amount,
                request.readyTime,
                request.poolId,
                request.executed,
                cooldown.getTimeRemaining(withdrawalId),
                cooldown.isWithdrawalReady(withdrawalId)
            );
        }
    }

    function getAllPools() external view returns (Pool[] memory pools) {
        uint256 poolLength = getPoolLength();
        pools = new Pool[](poolLength);

        for (uint256 i = 0; i < poolLength; i++) {
            pools[i] = getPool(i);
        }
    }
}
