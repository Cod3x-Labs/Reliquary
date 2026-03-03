// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20Mock} from "test/foundry/mocks/ERC20Mock.sol";
import {Reliquary} from "contracts/Reliquary.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PolynomialPlateauCurve} from "contracts/curves/PolynomialPlateauCurve.sol";
import {ParentRollingRewarder} from "contracts/rewarders/ParentRollingRewarder.sol";
import {NFTDescriptor} from "contracts/nft_descriptors/NFTDescriptor.sol";
import {ERC721Holder} from "openzeppelin-contracts/contracts/token/ERC721/utils/ERC721Holder.sol";
import {CooldownWithdrawal} from "contracts/CooldownWithdrawal.sol";
import {
    ReliquaryUIDataProvider,
    Pool,
    Position,
    ReliquaryInfo,
    UserSummary,
    PendingWithdrawal,
    Token,
    PoolIncentive,
    PositionPendingReward
} from "contracts/ReliquaryUIDataProvider.sol";

contract ReliquaryUIDataProviderTest is ERC721Holder, Test {
    ReliquaryUIDataProvider dataProvider;
    Reliquary reliquary;
    CooldownWithdrawal cooldownContract;
    ERC20Mock poolToken;
    ERC20Mock rewardToken;

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address multisig = makeAddr("multisig");

    uint256 user1RelicId;
    uint256 user2RelicId;
    uint256 thisRelicId;

    uint64 constant COOLDOWN_PERIOD = 3 days;
    uint256 constant DEPOSIT_AMOUNT = 1000e18;
    uint256 constant EMISSION_RATE = 1e17;

    int256[] public coeff = [
        int256(10000000e18),
        int256(0),
        int256(0.00000001508266362e18),
        int256(-0.00000000000000032e18),
        int256(0)
    ];

    function setUp() external {
        // Deploy tokens
        poolToken = new ERC20Mock(18);
        rewardToken = new ERC20Mock(18);

        // Deploy Reliquary
        Reliquary reliquaryImpl = new Reliquary();
        bytes memory data = abi.encodeWithSelector(
            Reliquary.initialize.selector,
            address(rewardToken),
            EMISSION_RATE,
            "Reliquary Deposit",
            "RELIC",
            uint256(0), // minStakingAmount (0 for test setup - addPool bootstraps with 1 wei)
            address(0)
        );
        reliquary = Reliquary(address(new ERC1967Proxy(address(reliquaryImpl), data)));

        // Deploy curve
        int256[] memory coeffDynamic = new int256[](5);
        for (uint256 i = 0; i < 5; i++) {
            coeffDynamic[i] = coeff[i];
        }
        PolynomialPlateauCurve curve = new PolynomialPlateauCurve(coeffDynamic, 365 days);

        // Deploy rewarder and descriptor
        ParentRollingRewarder parentRewarder = new ParentRollingRewarder();
        address nftDescriptor = address(new NFTDescriptor(address(reliquary)));

        // Mint tokens
        poolToken.mint(address(this), 100_000e18);
        poolToken.mint(user1, 100_000e18);
        poolToken.mint(user2, 100_000e18);
        rewardToken.mint(address(reliquary), 100_000_000e18);

        // Add pool
        poolToken.approve(address(reliquary), 1);
        reliquary.addPool(
            10000,
            address(poolToken),
            address(parentRewarder),
            curve,
            "Test Pool",
            nftDescriptor,
            true,
            multisig
        );

        // Create positions
        poolToken.approve(address(reliquary), type(uint256).max);
        thisRelicId = reliquary.createRelicAndDeposit(address(this), 0, DEPOSIT_AMOUNT);

        vm.startPrank(user1);
        poolToken.approve(address(reliquary), type(uint256).max);
        user1RelicId = reliquary.createRelicAndDeposit(user1, 0, DEPOSIT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(user2);
        poolToken.approve(address(reliquary), type(uint256).max);
        user2RelicId = reliquary.createRelicAndDeposit(user2, 0, DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Deploy cooldown contract
        cooldownContract = new CooldownWithdrawal(COOLDOWN_PERIOD, address(reliquary));
        reliquary.setCooldownWithdrawal(address(cooldownContract));

        // Deploy UI Data Provider
        dataProvider = new ReliquaryUIDataProvider(address(reliquary));
    }

    // ============ getReliquaryInfo Tests ============

    function test_getReliquaryInfo() external view {
        ReliquaryInfo memory info = dataProvider.getReliquaryInfo();

        assertEq(info.reliquaryAddress, address(reliquary));
        assertEq(info.rewardToken, address(rewardToken));
        assertEq(info.rewardTokenInfo.tokenAddress, address(rewardToken));
        assertEq(info.rewardTokenInfo.decimals, 18);
        assertEq(info.emissionRate, EMISSION_RATE);
        assertEq(info.totalAllocPoint, 10000);
        assertEq(info.minStakingAmount, 0);
        assertEq(info.cooldownWithdrawal, address(cooldownContract));
        assertEq(info.cooldownPeriod, COOLDOWN_PERIOD);
        assertFalse(info.paused);
        assertEq(info.poolCount, 1);
    }

    function test_getReliquaryInfo_WithoutCooldown() external {
        // Deploy provider for reliquary without cooldown
        Reliquary reliquaryImpl = new Reliquary();
        bytes memory data = abi.encodeWithSelector(
            Reliquary.initialize.selector,
            address(rewardToken),
            EMISSION_RATE,
            "Test",
            "TEST",
            uint256(0),
            address(0)
        );
        Reliquary reliquaryNoCooldown =
            Reliquary(address(new ERC1967Proxy(address(reliquaryImpl), data)));

        ReliquaryUIDataProvider providerNoCooldown =
            new ReliquaryUIDataProvider(address(reliquaryNoCooldown));

        ReliquaryInfo memory info = providerNoCooldown.getReliquaryInfo();
        assertEq(info.cooldownWithdrawal, address(0));
        assertEq(info.cooldownPeriod, 0);
    }

    // ============ getPoolLength Tests ============

    function test_getPoolLength() external view {
        assertEq(dataProvider.getPoolLength(), 1);
    }

    // ============ getPool Tests ============

    function test_getPool() external view {
        Pool memory pool = dataProvider.getPool(0);

        assertEq(pool.poolId, 0);
        assertEq(pool.allocPoint, 10000);
        assertEq(pool.name, "Test Pool");
        assertTrue(pool.allowPartialWithdrawals);
        assertEq(pool.token.tokenAddress, address(poolToken));
        assertEq(pool.token.decimals, 18);
        assertEq(pool.stakedTokens, 3 * DEPOSIT_AMOUNT + 1);
        assertGt(pool.poolIncentives.length, 0);
        assertEq(pool.poolIncentives[0].rewardPerSecond, EMISSION_RATE);
    }

    // ============ getAllPools Tests ============

    function test_getAllPools() external view {
        Pool[] memory pools = dataProvider.getAllPools();

        assertEq(pools.length, 1);
        assertEq(pools[0].poolId, 0);
        assertEq(pools[0].name, "Test Pool");
    }

    // ============ getPageOfPools Tests ============

    function test_getPageOfPools() external view {
        Pool[] memory pools = dataProvider.getPageOfPools(0, 10);

        assertEq(pools.length, 1);
        assertEq(pools[0].poolId, 0);
    }

    function test_getPageOfPools_PartialPage() external view {
        // Page size larger than pool count returns all available
        Pool[] memory pools = dataProvider.getPageOfPools(0, 100);
        assertEq(pools.length, 1);
    }

    // ============ getPosition Tests ============

    function test_getPosition() external view {
        Position memory position = dataProvider.getPosition(thisRelicId);

        assertEq(position.relicId, thisRelicId);
        assertEq(position.owner, address(this));
        assertEq(position.amount, DEPOSIT_AMOUNT);
        assertEq(position.poolId, 0);
        assertEq(position.level, 0);
        assertGt(position.maturityMultiplier, 0);
        assertEq(position.pool.poolId, 0);
        assertGt(position.pendingRewards.length, 0);
    }

    function test_getPosition_AfterTimePass() external {
        skip(30 days);

        Position memory position = dataProvider.getPosition(thisRelicId);

        assertEq(position.relicId, thisRelicId);
        assertEq(position.owner, address(this));
        assertGt(position.pendingRewards[0].pendingReward, 0);
    }

    // ============ getUserPositionLength Tests ============

    function test_getUserPositionLength() external view {
        assertEq(dataProvider.getUserPositionLength(address(this)), 1);
        assertEq(dataProvider.getUserPositionLength(user1), 1);
    }

    function test_getUserPositionLength_NoPositions() external {
        assertEq(dataProvider.getUserPositionLength(makeAddr("noPositions")), 0);
    }

    // ============ tokenOfOwnerByIndex Tests ============

    function test_tokenOfOwnerByIndex() external view {
        assertEq(dataProvider.tokenOfOwnerByIndex(address(this), 0), thisRelicId);
        assertEq(dataProvider.tokenOfOwnerByIndex(user1, 0), user1RelicId);
    }

    // ============ getAllUserRelicIds Tests ============

    function test_getAllUserRelicIds() external view {
        uint256[] memory relicIds = dataProvider.getAllUserRelicIds(address(this));

        assertEq(relicIds.length, 1);
        assertEq(relicIds[0], thisRelicId);
    }

    function test_getAllUserRelicIds_MultiplePositions() external {
        // Create another position for this address
        uint256 newRelicId = reliquary.createRelicAndDeposit(address(this), 0, DEPOSIT_AMOUNT);

        uint256[] memory relicIds = dataProvider.getAllUserRelicIds(address(this));

        assertEq(relicIds.length, 2);
        assertTrue(relicIds[0] == thisRelicId || relicIds[1] == thisRelicId);
        assertTrue(relicIds[0] == newRelicId || relicIds[1] == newRelicId);
    }

    function test_getAllUserRelicIds_NoPositions() external {
        uint256[] memory relicIds = dataProvider.getAllUserRelicIds(makeAddr("noPositions"));
        assertEq(relicIds.length, 0);
    }

    // ============ getAllUserPositions Tests ============

    function test_getAllUserPositions() external view {
        Position[] memory positions = dataProvider.getAllUserPositions(address(this));

        assertEq(positions.length, 1);
        assertEq(positions[0].relicId, thisRelicId);
        assertEq(positions[0].owner, address(this));
        assertEq(positions[0].amount, DEPOSIT_AMOUNT);
    }

    function test_getAllUserPositions_NoPositions() external {
        Position[] memory positions = dataProvider.getAllUserPositions(makeAddr("noPositions"));
        assertEq(positions.length, 0);
    }

    // ============ getPageOfPositions Tests ============

    function test_getPageOfPositions() external view {
        Position[] memory positions = dataProvider.getPageOfPositions(address(this), 0, 10);

        assertEq(positions.length, 1);
        assertEq(positions[0].relicId, thisRelicId);
    }

    function test_getPageOfPositions_PartialPage() external view {
        // Page size larger than position count returns all available
        Position[] memory positions = dataProvider.getPageOfPositions(address(this), 0, 100);
        assertEq(positions.length, 1);
    }

    // ============ getUserSummary Tests ============

    function test_getUserSummary() external view {
        UserSummary memory summary = dataProvider.getUserSummary(address(this));

        assertEq(summary.user, address(this));
        assertEq(summary.positionCount, 1);
        assertEq(summary.relicIds.length, 1);
        assertEq(summary.relicIds[0], thisRelicId);
    }

    function test_getUserSummary_WithPendingRewards() external {
        skip(30 days);
        reliquary.updatePool(0);

        UserSummary memory summary = dataProvider.getUserSummary(address(this));

        assertGt(summary.totalPendingReward, 0);
    }

    function test_getUserSummary_NoPositions() external {
        UserSummary memory summary = dataProvider.getUserSummary(makeAddr("noPositions"));

        assertEq(summary.positionCount, 0);
        assertEq(summary.relicIds.length, 0);
        assertEq(summary.totalPendingReward, 0);
    }

    // ============ getUserPendingWithdrawals Tests ============

    function test_getUserPendingWithdrawals_Empty() external view {
        PendingWithdrawal[] memory withdrawals =
            dataProvider.getUserPendingWithdrawals(address(this));
        assertEq(withdrawals.length, 0);
    }

    function test_getUserPendingWithdrawals_WithPending() external {
        // Create a withdrawal
        reliquary.withdraw(500e18, thisRelicId, address(0));

        PendingWithdrawal[] memory withdrawals =
            dataProvider.getUserPendingWithdrawals(address(this));

        assertEq(withdrawals.length, 1);
        assertEq(withdrawals[0].user, address(this));
        assertEq(withdrawals[0].token, address(poolToken));
        assertEq(withdrawals[0].amount, 500e18);
        assertEq(withdrawals[0].poolId, 0);
        assertFalse(withdrawals[0].executed);
        assertFalse(withdrawals[0].isReady);
        assertGt(withdrawals[0].timeRemaining, 0);
    }

    function test_getUserPendingWithdrawals_ReadyWithdrawal() external {
        reliquary.withdraw(500e18, thisRelicId, address(0));

        skip(COOLDOWN_PERIOD + 1);

        PendingWithdrawal[] memory withdrawals =
            dataProvider.getUserPendingWithdrawals(address(this));

        assertEq(withdrawals.length, 1);
        assertTrue(withdrawals[0].isReady);
        assertEq(withdrawals[0].timeRemaining, 0);
    }

    function test_getUserPendingWithdrawals_NoCooldownContract() external {
        // Deploy provider for reliquary without cooldown
        Reliquary reliquaryImpl = new Reliquary();
        bytes memory data = abi.encodeWithSelector(
            Reliquary.initialize.selector,
            address(rewardToken),
            EMISSION_RATE,
            "Test",
            "TEST",
            uint256(0),
            address(0)
        );
        Reliquary reliquaryNoCooldown =
            Reliquary(address(new ERC1967Proxy(address(reliquaryImpl), data)));

        ReliquaryUIDataProvider providerNoCooldown =
            new ReliquaryUIDataProvider(address(reliquaryNoCooldown));

        PendingWithdrawal[] memory withdrawals =
            providerNoCooldown.getUserPendingWithdrawals(address(this));
        assertEq(withdrawals.length, 0);
    }

    // ============ getChildRewardersForPool Tests ============

    function test_getChildRewardersForPool() external view {
        address[] memory rewarders = dataProvider.getChildRewardersForPool(0);
        // ParentRollingRewarder starts with empty children
        assertEq(rewarders.length, 0);
    }

    // ============ Integration Tests ============

    function test_fullUserFlow() external {
        // 1. Get initial reliquary info
        ReliquaryInfo memory info = dataProvider.getReliquaryInfo();
        assertEq(info.poolCount, 1);

        // 2. Get user summary before any action
        UserSummary memory summaryBefore = dataProvider.getUserSummary(user1);
        assertEq(summaryBefore.positionCount, 1);

        // 3. Get position details
        Position memory position = dataProvider.getPosition(user1RelicId);
        assertEq(position.amount, DEPOSIT_AMOUNT);

        // 4. Time passes, rewards accrue
        skip(30 days);

        // 5. Check pending rewards
        UserSummary memory summaryAfter = dataProvider.getUserSummary(user1);
        assertGt(summaryAfter.totalPendingReward, 0);

        // 6. User withdraws (creates pending withdrawal)
        vm.prank(user1);
        reliquary.withdraw(500e18, user1RelicId, address(0));

        // 7. Check pending withdrawals
        PendingWithdrawal[] memory withdrawals = dataProvider.getUserPendingWithdrawals(user1);
        assertEq(withdrawals.length, 1);
        assertFalse(withdrawals[0].isReady);

        // 8. Time passes, withdrawal becomes ready
        skip(COOLDOWN_PERIOD + 1);

        withdrawals = dataProvider.getUserPendingWithdrawals(user1);
        assertTrue(withdrawals[0].isReady);
    }

    function test_multipleUsersMultiplePositions() external {
        // Create additional positions
        reliquary.createRelicAndDeposit(address(this), 0, DEPOSIT_AMOUNT);

        vm.prank(user1);
        reliquary.createRelicAndDeposit(user1, 0, DEPOSIT_AMOUNT);

        // Verify user summaries
        UserSummary memory summary1 = dataProvider.getUserSummary(address(this));
        assertEq(summary1.positionCount, 2);

        UserSummary memory summary2 = dataProvider.getUserSummary(user1);
        assertEq(summary2.positionCount, 2);

        // Verify all positions
        Position[] memory positions1 = dataProvider.getAllUserPositions(address(this));
        assertEq(positions1.length, 2);

        Position[] memory positions2 = dataProvider.getAllUserPositions(user1);
        assertEq(positions2.length, 2);
    }
}
