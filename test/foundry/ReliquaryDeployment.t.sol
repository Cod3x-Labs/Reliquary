// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "contracts/Reliquary.sol";
import "contracts/interfaces/IReliquary.sol";
import "contracts/nft_descriptors/NFTDescriptor.sol";
import "contracts/curves/LinearCurve.sol";
import "contracts/curves/LinearPlateauCurve.sol";
import "openzeppelin-contracts/contracts/token/ERC721/utils/ERC721Holder.sol";
import "contracts/curves/PolynomialPlateauCurve.sol";
import "./mocks/ERC20Mock.sol";
import "contracts/rewarders/RollingRewarder.sol";
import "contracts/rewarders/ParentRollingRewarder.sol";
import "contracts/interfaces/ICurvesData.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ReliquaryDeploymentTest is ERC721Holder, Test {
    using Strings for address;
    using Strings for uint256;

    address constant CDX = 0xC0D3700000c0e32716863323bFd936b54a1633d1;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    bytes32 private constant EMISSION_RATE = keccak256("EMISSION_RATE");

    // Params
    string name = "Reliquary Deposit";
    string symbol = "RELIC";
    address weth = 0x4200000000000000000000000000000000000006;
    address multisig = 0xfEfcb2fb19b9A70B30646Fdc1A0860Eb12F7ff8b; // to confirm !!
    address mainRewardToken; // = 0xB22a793a81ff5b6Ad37F40d5FE1E0AC4184d52F3; // TONY
    uint256 emissionRate = 0; //Desired value = 0

    // Pool#1
    uint256 allocPoints = 100;

    // Linear function config (to config)
    uint256 slope = 1; // Increase of multiplier every second
    uint256 minMultiplier = 730 days; // 365 days / 2; // from previous deployment
    uint256 plateau = 365 days; // from previous deployment

    uint256 cooldownPeriod = 604800;

    // int256[] public coeff = [
    //     int256(100e18),
    //     int256(1e18),
    //     int256(5e15),
    //     int256(-1e13),
    //     int256(5e9)
    // ];
    int256[] public coeff = [
        int256(10000000e18),
        int256(0),
        int256(0.00000001508266362e18),
        int256(-0.00000000000000032e18),
        int256(0)
    ];

    // Contracts
    RollingRewarder[] public childRewarders;
    ParentRollingRewarder public parentRewarder;
    Reliquary reliquary;
    LinearCurve linearCurve;
    LinearPlateauCurve linearPlateauCurve;
    PolynomialPlateauCurve polynomialPlateauCurve;
    // ERC20Mock oath;
    ERC20Mock testToken;
    address nftDescriptor;
    CooldownWithdrawal cooldownWithdrawal;

    function setUp() public {
        vm.createSelectFork("base");
        int256[] memory coeffDynamic = new int256[](5);
        for (uint256 i = 0; i < 5; i++) {
            coeffDynamic[i] = coeff[i];
        }

        testToken = new ERC20Mock(6);

        // testToken.approve(address(reliquary), 1);

        mainRewardToken = address(testToken);

        Reliquary reliquaryImpl = new Reliquary();
        bytes memory data = abi.encodeWithSelector(
            Reliquary.initialize.selector,
            mainRewardToken, // _rewardToken
            emissionRate, // _emissionRate
            "Reliquary Deposit", // _name
            "RELIC", // _symbol
            uint256(0), // _minStakingAmount
            address(0) // _cooldownWithdrawal
        );
        reliquary = Reliquary(address(new ERC1967Proxy(address(reliquaryImpl), data)));

        cooldownWithdrawal = new CooldownWithdrawal(cooldownPeriod, address(reliquary));

        linearPlateauCurve = new LinearPlateauCurve(slope, minMultiplier, plateau);
        linearCurve = new LinearCurve(slope, minMultiplier);
        polynomialPlateauCurve = new PolynomialPlateauCurve(coeffDynamic, 365 days);

        vm.startPrank(multisig);
        // ERC20Mock(CDX).mint(address(reliquary), 100_000 ether);
        ERC20Mock(CDX).mint(address(this), 2000 ether);
        vm.stopPrank();

        nftDescriptor = address(new NFTDescriptor(address(reliquary)));

        parentRewarder = new ParentRollingRewarder();

        reliquary.grantRole(keccak256("OPERATOR"), address(this));

        deal(USDC, address(this), 2000 ether);
        ERC20Mock(CDX).approve(address(reliquary), 1);
        reliquary.addPool(
            allocPoints,
            CDX,
            address(parentRewarder),
            polynomialPlateauCurve, //polynomialPlateauCurve
            "CDX staking pool",
            nftDescriptor,
            true,
            multisig
        );
        reliquary.setCooldownWithdrawal(address(cooldownWithdrawal));

        ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
    }

    function testDistributionPeriodWorking(uint256 amount, uint256 time) public {
        MultipleUsers memory multipleUsers;
        multipleUsers.mainUser = makeAddr("mainUser");
        multipleUsers.user1 = makeAddr("User1");
        multipleUsers.user2 = makeAddr("User2");
        deal(CDX, multipleUsers.mainUser, 1000 ether);
        deal(CDX, multipleUsers.user1, 1000 ether);
        deal(CDX, multipleUsers.user2, 1000 ether);

        amount = 5e18; //bound(amount, 1, IERC20(CDX).balanceOf(address(this)));

        testToken.mint(address(reliquary), 10000 ether);
        time = 1 days; //bound(time, 0, 365 days);
        childRewarders.push(RollingRewarder(parentRewarder.createChild(USDC)));
        childRewarders[0].updateDistributionPeriod(10 days);

        vm.startPrank(multipleUsers.mainUser);
        ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
        multipleUsers.mainUserRelic =
            reliquary.createRelicAndDeposit(multipleUsers.mainUser, 0, amount);
        vm.stopPrank();

        skip(10 days);

        vm.prank(multipleUsers.mainUser);
        reliquary.update(multipleUsers.mainUserRelic, multipleUsers.mainUser);

        console2.log("1. User balance: %6e", IERC20(USDC).balanceOf(multipleUsers.mainUser));
        console2.log("1. User1 balance: %6e", IERC20(USDC).balanceOf(multipleUsers.user1));
        console2.log("1. User2 balance: %6e", IERC20(USDC).balanceOf(multipleUsers.user2));

        vm.startPrank(multipleUsers.user1);
        ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
        multipleUsers.user1Relic = reliquary.createRelicAndDeposit(multipleUsers.user1, 0, amount);
        vm.stopPrank();

        ERC20Mock(USDC).approve(address(childRewarders[0]), type(uint256).max);
        childRewarders[0].fund(3e6);

        skip(5 days);

        vm.prank(multipleUsers.mainUser);
        reliquary.update(multipleUsers.mainUserRelic, multipleUsers.mainUser);

        vm.prank(multipleUsers.user1);
        reliquary.update(multipleUsers.user1Relic, multipleUsers.user1);

        vm.startPrank(multipleUsers.user2);
        ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
        multipleUsers.user2Relic = reliquary.createRelicAndDeposit(multipleUsers.user2, 0, amount);
        vm.stopPrank();

        console2.log("2. User balance: %6e", IERC20(USDC).balanceOf(multipleUsers.mainUser));
        console2.log("2. User1 balance: %6e", IERC20(USDC).balanceOf(multipleUsers.user1));
        console2.log("2. User2 balance: %6e", IERC20(USDC).balanceOf(multipleUsers.user2));

        skip(5 days);

        vm.prank(multipleUsers.mainUser);
        reliquary.update(multipleUsers.mainUserRelic, multipleUsers.mainUser);

        vm.prank(multipleUsers.user1);
        reliquary.update(multipleUsers.user1Relic, multipleUsers.user1);

        vm.prank(multipleUsers.user2);
        reliquary.update(multipleUsers.user2Relic, multipleUsers.user2);

        console2.log("3. User balance: %6e", IERC20(USDC).balanceOf(multipleUsers.mainUser));
        console2.log("3. User1 balance: %6e", IERC20(USDC).balanceOf(multipleUsers.user1));
        console2.log("3. User2 balance: %6e", IERC20(USDC).balanceOf(multipleUsers.user2));

        skip(5 days);

        vm.prank(multipleUsers.mainUser);
        reliquary.update(multipleUsers.mainUserRelic, multipleUsers.mainUser);

        vm.prank(multipleUsers.user1);
        reliquary.update(multipleUsers.user1Relic, multipleUsers.user1);

        vm.prank(multipleUsers.user2);
        reliquary.update(multipleUsers.user2Relic, multipleUsers.user2);

        console2.log("4. User balance: %6e", IERC20(USDC).balanceOf(multipleUsers.mainUser));
        console2.log("4. User1 balance: %6e", IERC20(USDC).balanceOf(multipleUsers.user1));
        console2.log("4. User2 balance: %6e", IERC20(USDC).balanceOf(multipleUsers.user2));

        // assert(false);
    }

    function testPendingSingleReward(uint256 amount, uint256 time) public {
        testToken.mint(address(reliquary), 10000 ether);
        time = bound(time, 0, 365 days);
        amount = bound(amount, 1, IERC20(CDX).balanceOf(address(this)));
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, amount);
        skip(time);
        reliquary.update(relicId, address(0));
        console2.log("Relic id: ", relicId);
        // reliquary.pendingReward(1) is the bootstrapped relic.
        assertApproxEqAbs(
            reliquary.pendingReward(relicId) + reliquary.pendingReward(1),
            time * emissionRate,
            (time * emissionRate) / 100000
        ); // max 0,0001%

        console2.log("Balance before: %18e", testToken.balanceOf(address(this)));
        reliquary.update(relicId, address(this));
        console2.log("Balance after: %18e", testToken.balanceOf(address(this)));
        // assert(false);
    }

    function testPendingMultipleRewards(uint256 amount, uint256 time) public {
        reliquary.grantRole(EMISSION_RATE, address(this));
        reliquary.setEmissionRate(100);
        testToken.mint(address(reliquary), 10000 ether);
        time = 1 days; //bound(time, 0, 365 days);
        childRewarders.push(RollingRewarder(parentRewarder.createChild(CDX)));
        childRewarders[0].updateDistributionPeriod(365 days / 2);
        ERC20Mock(CDX).approve(address(childRewarders[0]), type(uint256).max);
        childRewarders[0].fund(3 ether);
        amount = 5e18; //bound(amount, 1, IERC20(CDX).balanceOf(address(this)));
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, amount);

        skip(time);
        reliquary.update(relicId, address(0));
        console2.log("Relic id: ", relicId);
        // reliquary.pendingReward(1) is the bootstrapped relic.
        assertApproxEqAbs(
            reliquary.pendingReward(relicId) + reliquary.pendingReward(1),
            time * reliquary.emissionRate(),
            (time * reliquary.emissionRate()) / 100000,
            "Wrong pending rewards"
        ); // max 0,0001%
        uint256 initialBalanceOfCdx = IERC20(CDX).balanceOf(address(this));
        uint256 childPendingRewards = childRewarders[0].pendingToken(relicId);
        console2.log("1. Pending rewards: ", reliquary.pendingReward(relicId));
        console2.log("1. Balance of testToken: ", testToken.balanceOf(address(this)));
        console2.log("1. Balance of CDX: ", initialBalanceOfCdx);
        reliquary.withdraw(amount, relicId, address(this));
        assertEq(reliquary.pendingReward(relicId), 0, "Pending rewards shall be 0");
        assertApproxEqAbs(
            testToken.balanceOf(address(this)),
            time * reliquary.emissionRate(),
            (time * reliquary.emissionRate()) / 100000,
            "Wrong main rewards balance"
        );
        assertEq(
            initialBalanceOfCdx + childPendingRewards,
            IERC20(CDX).balanceOf(address(this)),
            "Wrong child pending rewards"
        );
        skip(7 days);
        uint256 withdrawalId = cooldownWithdrawal.getUserWithdrawals(address(this))[0];
        cooldownWithdrawal.executeWithdrawal(withdrawalId);
        console2.log("2. Pending rewards: ", reliquary.pendingReward(relicId));
        console2.log("2. Balance of testToken: ", testToken.balanceOf(address(this)));
        console2.log("2. Balance of CDX: ", IERC20(CDX).balanceOf(address(this)));
        assertEq(
            initialBalanceOfCdx + childPendingRewards + amount,
            IERC20(CDX).balanceOf(address(this)),
            "Wrong child pending rewards 2"
        );
    }

    struct MultipleUsers {
        address mainUser;
        uint256 mainUserRelic;
        uint256 mainUserPrevBalance;
        address user1;
        uint256 user1Relic;
        uint256 user1PrevBalance;
        address user2;
        uint256 user2Relic;
        uint256 user2PrevBalance;
        address user3;
        uint256 user3Relic;
        uint256 user3PrevBalance;
    }

    function testPendingUsdcRewardFromChild_1YearPolynomial(uint256 amount, uint256 time) public {
        MultipleUsers memory multipleUsers;
        multipleUsers.mainUser = makeAddr("mainUser");
        multipleUsers.user1 = makeAddr("User1");
        multipleUsers.user2 = makeAddr("User2");
        multipleUsers.user3 = makeAddr("User3");

        deal(CDX, multipleUsers.mainUser, 1000 ether);
        deal(CDX, multipleUsers.user1, 1000 ether);
        deal(CDX, multipleUsers.user2, 1000 ether);
        deal(CDX, multipleUsers.user3, 1000 ether);

        testToken.mint(address(reliquary), 0); // 0 main reward from parent
        time = 3 days; //bound(time, 0, 365 days);
        childRewarders.push(RollingRewarder(parentRewarder.createChild(USDC)));
        childRewarders[0].updateDistributionPeriod(400 days);
        ERC20Mock(USDC).approve(address(childRewarders[0]), type(uint256).max);
        childRewarders[0].fund(1000e6);
        amount = 1000e18; //bound(amount, 1, IERC20(CDX).balanceOf(address(this)));

        vm.startPrank(multipleUsers.mainUser);
        ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
        multipleUsers.mainUserRelic =
            reliquary.createRelicAndDeposit(multipleUsers.mainUser, 0, amount);
        vm.stopPrank();

        multipleUsers.mainUserPrevBalance = IERC20(USDC).balanceOf(multipleUsers.mainUser);
        for (uint256 idx = 0; idx < 400 days; idx += time) {
            if (idx == 90 days) {
                vm.startPrank(multipleUsers.user1);
                ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
                multipleUsers.user1Relic =
                    reliquary.createRelicAndDeposit(multipleUsers.user1, 0, amount);
                vm.stopPrank();
            }
            if (idx == 180 days) {
                vm.startPrank(multipleUsers.user2);
                ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
                multipleUsers.user2Relic =
                    reliquary.createRelicAndDeposit(multipleUsers.user2, 0, amount);
                vm.stopPrank();
                // childRewarders[0].fund(1000e6);
            }
            if (idx == 270 days) {
                vm.startPrank(multipleUsers.user3);
                ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
                multipleUsers.user3Relic =
                    reliquary.createRelicAndDeposit(multipleUsers.user3, 0, amount);
                vm.stopPrank();
            }
            skip(time);

            /* Main user */
            PositionInfo memory positionInfo =
                reliquary.getPositionForId(multipleUsers.mainUserRelic);
            ICurvesData curve =
                ICurvesData(address(reliquary.getPoolInfo(uint8(positionInfo.poolId)).curve));
            uint256 multiplier =
                (curve.getFunction(uint256(positionInfo.level)) * 10_000) / curve.minMultiplier();

            console2.log(
                "Main user Day %s. Pending USDC: %6e",
                idx / 1 days,
                childRewarders[0].pendingToken(multipleUsers.mainUserRelic)
            );
            multipleUsers.mainUserPrevBalance += childRewarders[0].pendingToken(
                multipleUsers.mainUserRelic
            );
            console2.log("Main user multiplier: ", multiplier);
            console2.log(
                "Main user function for level %s : %s",
                positionInfo.level,
                curve.getFunction(uint256(positionInfo.level))
            );
            console2.log("MainUser balance for level: %s", multipleUsers.mainUserPrevBalance);

            /* User1 */
            positionInfo = reliquary.getPositionForId(multipleUsers.user1Relic);
            curve = ICurvesData(address(reliquary.getPoolInfo(uint8(positionInfo.poolId)).curve));
            multiplier =
                (curve.getFunction(uint256(positionInfo.level)) * 10_000) / curve.minMultiplier();
            console2.log(
                "User1 Day %s. Pending USDC: %6e",
                idx / 1 days,
                childRewarders[0].pendingToken(multipleUsers.user1Relic)
            );
            multipleUsers.user1PrevBalance += childRewarders[0].pendingToken(
                multipleUsers.user1Relic
            );
            console2.log("User1 multiplier: ", multiplier);
            console2.log(
                "User1 function for level %s : %s",
                positionInfo.level,
                curve.getFunction(uint256(positionInfo.level))
            );
            console2.log("User1 balance for level: %s", multipleUsers.user1PrevBalance);

            /* User2 */
            positionInfo = reliquary.getPositionForId(multipleUsers.user2Relic);
            curve = ICurvesData(address(reliquary.getPoolInfo(uint8(positionInfo.poolId)).curve));
            multiplier =
                (curve.getFunction(uint256(positionInfo.level)) * 10_000) / curve.minMultiplier();
            console2.log(
                "User2 Day %s. Pending USDC: %6e",
                idx / 1 days,
                childRewarders[0].pendingToken(multipleUsers.user2Relic)
            );
            multipleUsers.user2PrevBalance += childRewarders[0].pendingToken(
                multipleUsers.user2Relic
            );
            console2.log(
                "User2 Day %s. Pending USDC: %6e",
                idx / 1 days,
                childRewarders[0].pendingToken(multipleUsers.user2Relic)
            );
            console2.log("User2 multiplier: ", multiplier);
            console2.log(
                "User2 function for level %s : %s",
                positionInfo.level,
                curve.getFunction(uint256(positionInfo.level))
            );
            console2.log("User2 balance for level: %s", multipleUsers.user2PrevBalance);

            /* User3 */
            positionInfo = reliquary.getPositionForId(multipleUsers.user3Relic);
            curve = ICurvesData(address(reliquary.getPoolInfo(uint8(positionInfo.poolId)).curve));
            multiplier =
                (curve.getFunction(uint256(positionInfo.level)) * 10_000) / curve.minMultiplier();
            console2.log(
                "User3 Day %s. Pending USDC: %6e",
                idx / 1 days,
                childRewarders[0].pendingToken(multipleUsers.user3Relic)
            );
            console2.log(
                "User3 Day %s. Pending USDC: %6e",
                idx / 1 days,
                childRewarders[0].pendingToken(multipleUsers.user3Relic)
            );
            multipleUsers.user3PrevBalance += childRewarders[0].pendingToken(
                multipleUsers.user3Relic
            );
            console2.log("User3 multiplier: ", multiplier);
            console2.log(
                "User3 function for level %s : %s",
                positionInfo.level,
                curve.getFunction(uint256(positionInfo.level))
            );
            console2.log("User3 balance for level: %s", multipleUsers.user3PrevBalance);

            vm.prank(multipleUsers.mainUser);
            reliquary.update(multipleUsers.mainUserRelic, multipleUsers.mainUser);
            if (idx >= 90 days) {
                vm.prank(multipleUsers.user1);
                reliquary.update(multipleUsers.user1Relic, multipleUsers.user1);
            }
            if (idx >= 180 days) {
                vm.prank(multipleUsers.user2);
                reliquary.update(multipleUsers.user2Relic, multipleUsers.user2);
            }
            if (idx >= 270 days) {
                vm.prank(multipleUsers.user3);
                reliquary.update(multipleUsers.user3Relic, multipleUsers.user3);
            }

            // console2.log("2. Pending rewards: ", reliquary.pendingReward(relicId));
        }
        vm.prank(multipleUsers.mainUser);
        reliquary.withdraw(amount, multipleUsers.mainUserRelic, multipleUsers.mainUser);
        vm.prank(multipleUsers.user1);
        reliquary.withdraw(amount, multipleUsers.user1Relic, multipleUsers.user1);
        vm.prank(multipleUsers.user2);
        reliquary.withdraw(amount, multipleUsers.user2Relic, multipleUsers.user2);
        vm.prank(multipleUsers.user3);
        reliquary.withdraw(amount, multipleUsers.user3Relic, multipleUsers.user3);

        assertEq(
            IERC20(CDX).balanceOf(multipleUsers.mainUser),
            1000 ether - amount,
            "Wrong CDX balance for main user"
        );
        assertEq(
            IERC20(CDX).balanceOf(multipleUsers.user1),
            1000 ether - amount,
            "Wrong CDX balance for user1"
        );
        assertEq(
            IERC20(CDX).balanceOf(multipleUsers.user2),
            1000 ether - amount,
            "Wrong CDX balance for user2"
        );
        assertEq(
            IERC20(CDX).balanceOf(multipleUsers.user3),
            1000 ether - amount,
            "Wrong CDX balance for user3"
        );

        skip(7 days);

        uint256 withdrawalId = cooldownWithdrawal.getUserWithdrawals(multipleUsers.mainUser)[0];
        vm.prank(multipleUsers.mainUser);
        cooldownWithdrawal.executeWithdrawal(withdrawalId);

        withdrawalId = cooldownWithdrawal.getUserWithdrawals(multipleUsers.user1)[0];
        vm.prank(multipleUsers.user1);
        cooldownWithdrawal.executeWithdrawal(withdrawalId);

        withdrawalId = cooldownWithdrawal.getUserWithdrawals(multipleUsers.user2)[0];
        vm.prank(multipleUsers.user2);
        cooldownWithdrawal.executeWithdrawal(withdrawalId);

        withdrawalId = cooldownWithdrawal.getUserWithdrawals(multipleUsers.user3)[0];
        vm.prank(multipleUsers.user3);
        cooldownWithdrawal.executeWithdrawal(withdrawalId);

        assertEq(
            IERC20(USDC).balanceOf(multipleUsers.mainUser),
            multipleUsers.mainUserPrevBalance,
            "Wrong withdrawal balance for main user"
        );
        assertEq(
            IERC20(USDC).balanceOf(multipleUsers.user1),
            multipleUsers.user1PrevBalance,
            "Wrong withdrawal balance for user1"
        );
        assertEq(
            IERC20(USDC).balanceOf(multipleUsers.user2),
            multipleUsers.user2PrevBalance,
            "Wrong withdrawal balance for user2"
        );
        assertEq(
            IERC20(USDC).balanceOf(multipleUsers.user3),
            multipleUsers.user3PrevBalance,
            "Wrong withdrawal balance for user3"
        );
        console2.log("Main user balance: %6e", IERC20(USDC).balanceOf(multipleUsers.mainUser));
        console2.log("User1 balance: %6e", IERC20(USDC).balanceOf(multipleUsers.user1));
        console2.log("User2 balance: %6e", IERC20(USDC).balanceOf(multipleUsers.user2));
        console2.log("User3 balance: %6e", IERC20(USDC).balanceOf(multipleUsers.user3));
        // CDX balances should be restored to the initial deposited amount (1000 ether)
        assertEq(
            IERC20(CDX).balanceOf(multipleUsers.mainUser),
            1000 ether,
            "Wrong CDX balance for main user"
        );
        assertEq(
            IERC20(CDX).balanceOf(multipleUsers.user1), 1000 ether, "Wrong CDX balance for user1"
        );
        assertEq(
            IERC20(CDX).balanceOf(multipleUsers.user2), 1000 ether, "Wrong CDX balance for user2"
        );
        assertEq(
            IERC20(CDX).balanceOf(multipleUsers.user3), 1000 ether, "Wrong CDX balance for user3"
        );
    }

    function testPendingUsdcRewardFromChild_Multidistributions1YearPolynomial(
        uint256 amount,
        uint256 time
    ) public {
        MultipleUsers memory multipleUsers;
        multipleUsers.mainUser = makeAddr("mainUser");
        multipleUsers.user1 = makeAddr("User1");
        multipleUsers.user2 = makeAddr("User2");
        multipleUsers.user3 = makeAddr("User3");

        deal(CDX, multipleUsers.mainUser, 1000 ether);
        deal(CDX, multipleUsers.user1, 1000 ether);
        deal(CDX, multipleUsers.user2, 1000 ether);
        deal(CDX, multipleUsers.user3, 1000 ether);

        reliquary.setCooldownWithdrawal(address(0));
        testToken.mint(address(reliquary), 0); // 0 main reward from parent
        time = 3 days; //bound(time, 0, 365 days);
        childRewarders.push(RollingRewarder(parentRewarder.createChild(USDC)));
        childRewarders[0].updateDistributionPeriod(14 days);
        ERC20Mock(USDC).approve(address(childRewarders[0]), type(uint256).max);
        childRewarders[0].fund(100e6);
        amount = 1000e18; //bound(amount, 1, IERC20(CDX).balanceOf(address(this)));

        vm.startPrank(multipleUsers.mainUser);
        ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
        multipleUsers.mainUserRelic =
            reliquary.createRelicAndDeposit(multipleUsers.mainUser, 0, amount);
        vm.stopPrank();

        multipleUsers.mainUserPrevBalance = IERC20(USDC).balanceOf(multipleUsers.mainUser);
        for (uint256 idx = 0; idx < 400 days; idx += time) {
            if (idx % 14 days == 0 && idx != 0) {
                childRewarders[0].updateDistributionPeriod(14 days);
                childRewarders[0].fund((idx / 1 days) * 100e6);
            }
            if (idx == 90 days) {
                vm.startPrank(multipleUsers.user1);
                ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
                multipleUsers.user1Relic =
                    reliquary.createRelicAndDeposit(multipleUsers.user1, 0, amount);
                vm.stopPrank();
            }
            if (idx == 180 days) {
                vm.startPrank(multipleUsers.user2);
                ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
                multipleUsers.user2Relic =
                    reliquary.createRelicAndDeposit(multipleUsers.user2, 0, amount);
                vm.stopPrank();
                // childRewarders[0].fund(1000e6);
            }
            if (idx == 270 days) {
                vm.startPrank(multipleUsers.user3);
                ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
                multipleUsers.user3Relic =
                    reliquary.createRelicAndDeposit(multipleUsers.user3, 0, amount);
                vm.stopPrank();
            }
            skip(time);

            /* Main user */
            PositionInfo memory positionInfo =
                reliquary.getPositionForId(multipleUsers.mainUserRelic);
            ICurvesData curve =
                ICurvesData(address(reliquary.getPoolInfo(uint8(positionInfo.poolId)).curve));
            uint256 multiplier =
                (curve.getFunction(uint256(positionInfo.level)) * 10_000) / curve.minMultiplier();

            console2.log(
                "Main user Day %s. Pending USDC: %6e",
                idx / 1 days,
                childRewarders[0].pendingToken(multipleUsers.mainUserRelic)
            );
            multipleUsers.mainUserPrevBalance += childRewarders[0].pendingToken(
                multipleUsers.mainUserRelic
            );
            console2.log("Main user multiplier: ", multiplier);
            console2.log(
                "Main user function for level %s : %s",
                positionInfo.level,
                curve.getFunction(uint256(positionInfo.level))
            );

            /* User1 */
            positionInfo = reliquary.getPositionForId(multipleUsers.user1Relic);
            curve = ICurvesData(address(reliquary.getPoolInfo(uint8(positionInfo.poolId)).curve));
            multiplier =
                (curve.getFunction(uint256(positionInfo.level)) * 10_000) / curve.minMultiplier();
            console2.log(
                "User1 Day %s. Pending USDC: %6e",
                idx / 1 days,
                childRewarders[0].pendingToken(multipleUsers.user1Relic)
            );
            multipleUsers.user1PrevBalance += childRewarders[0].pendingToken(
                multipleUsers.user1Relic
            );
            console2.log("User1 multiplier: ", multiplier);
            console2.log(
                "User1 function for level %s : %s",
                positionInfo.level,
                curve.getFunction(uint256(positionInfo.level))
            );

            /* User2 */
            positionInfo = reliquary.getPositionForId(multipleUsers.user2Relic);
            curve = ICurvesData(address(reliquary.getPoolInfo(uint8(positionInfo.poolId)).curve));
            multiplier =
                (curve.getFunction(uint256(positionInfo.level)) * 10_000) / curve.minMultiplier();
            console2.log(
                "User2 Day %s. Pending USDC: %6e",
                idx / 1 days,
                childRewarders[0].pendingToken(multipleUsers.user2Relic)
            );
            multipleUsers.user2PrevBalance += childRewarders[0].pendingToken(
                multipleUsers.user2Relic
            );
            console2.log(
                "User2 Day %s. Pending USDC: %6e",
                idx / 1 days,
                childRewarders[0].pendingToken(multipleUsers.user2Relic)
            );
            console2.log("User2 multiplier: ", multiplier);
            console2.log(
                "User2 function for level %s : %s",
                positionInfo.level,
                curve.getFunction(uint256(positionInfo.level))
            );

            /* User3 */
            positionInfo = reliquary.getPositionForId(multipleUsers.user3Relic);
            curve = ICurvesData(address(reliquary.getPoolInfo(uint8(positionInfo.poolId)).curve));
            multiplier =
                (curve.getFunction(uint256(positionInfo.level)) * 10_000) / curve.minMultiplier();
            console2.log(
                "User3 Day %s. Pending USDC: %6e",
                idx / 1 days,
                childRewarders[0].pendingToken(multipleUsers.user3Relic)
            );
            console2.log(
                "User3 Day %s. Pending USDC: %6e",
                idx / 1 days,
                childRewarders[0].pendingToken(multipleUsers.user3Relic)
            );
            multipleUsers.user3PrevBalance += childRewarders[0].pendingToken(
                multipleUsers.user3Relic
            );
            console2.log("User3 multiplier: ", multiplier);
            console2.log(
                "User3 function for level %s : %s",
                positionInfo.level,
                curve.getFunction(uint256(positionInfo.level))
            );

            vm.prank(multipleUsers.mainUser);
            reliquary.update(multipleUsers.mainUserRelic, multipleUsers.mainUser);
            if (idx >= 90 days) {
                vm.prank(multipleUsers.user1);
                reliquary.update(multipleUsers.user1Relic, multipleUsers.user1);
            }
            if (idx >= 180 days) {
                vm.prank(multipleUsers.user2);
                reliquary.update(multipleUsers.user2Relic, multipleUsers.user2);
            }
            if (idx >= 270 days) {
                vm.prank(multipleUsers.user3);
                reliquary.update(multipleUsers.user3Relic, multipleUsers.user3);
            }

            // console2.log("2. Pending rewards: ", reliquary.pendingReward(relicId));
        }
        vm.prank(multipleUsers.mainUser);
        reliquary.withdraw(amount, multipleUsers.mainUserRelic, multipleUsers.mainUser);
        vm.prank(multipleUsers.user1);
        reliquary.withdraw(amount, multipleUsers.user1Relic, multipleUsers.user1);
        vm.prank(multipleUsers.user2);
        reliquary.withdraw(amount, multipleUsers.user2Relic, multipleUsers.user2);
        vm.prank(multipleUsers.user3);
        reliquary.withdraw(amount, multipleUsers.user3Relic, multipleUsers.user3);

        assertEq(
            IERC20(USDC).balanceOf(multipleUsers.mainUser),
            multipleUsers.mainUserPrevBalance,
            "Wrong withdrawal balance for main user"
        );
        assertEq(
            IERC20(USDC).balanceOf(multipleUsers.user1),
            multipleUsers.user1PrevBalance,
            "Wrong withdrawal balance for user1"
        );
        assertEq(
            IERC20(USDC).balanceOf(multipleUsers.user2),
            multipleUsers.user2PrevBalance,
            "Wrong withdrawal balance for user2"
        );
        assertEq(
            IERC20(USDC).balanceOf(multipleUsers.user3),
            multipleUsers.user3PrevBalance,
            "Wrong withdrawal balance for user3"
        );
        // assert(false);
    }

    // function testUsdcWithdrawalRewardFromChild_1Year(uint256 amount, uint256 time) public {
    //     MultipleUsers memory multipleUsers;
    //     multipleUsers.mainUser = makeAddr("mainUser");
    //     multipleUsers.user1 = makeAddr("User1");
    //     multipleUsers.user2 = makeAddr("User2");
    //     multipleUsers.user3 = makeAddr("User3");

    //     deal(CDX, multipleUsers.mainUser, 1000 ether);
    //     deal(CDX, multipleUsers.user1, 1000 ether);
    //     deal(CDX, multipleUsers.user2, 1000 ether);
    //     deal(CDX, multipleUsers.user3, 1000 ether);

    //     testToken.mint(address(reliquary), 0); // 0 main reward from parent
    //     time = 3 days; //bound(time, 0, 365 days);
    //     childRewarders.push(RollingRewarder(parentRewarder.createChild(USDC)));
    //     childRewarders[0].updateDistributionPeriod(365 days);
    //     ERC20Mock(USDC).approve(address(childRewarders[0]), type(uint256).max);
    //     childRewarders[0].fund(1000e6);
    //     amount = 1000e18; //bound(amount, 1, IERC20(CDX).balanceOf(address(this)));

    //     vm.startPrank(multipleUsers.mainUser);
    //     ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
    //     multipleUsers.mainUserRelic =
    //         reliquary.createRelicAndDeposit(multipleUsers.mainUser, 0, amount);
    //     vm.stopPrank();

    //     multipleUsers.mainUserPrevBalance = IERC20(USDC).balanceOf(multipleUsers.mainUser);
    //     // multipleUsers.user1PrevBalance = IERC20(CDX).balanceOf(
    //     //     multipleUsers.user1
    //     // );
    //     // multipleUsers.user2PrevBalance = IERC20(CDX).balanceOf(
    //     //     multipleUsers.user2
    //     // );
    //     // multipleUsers.user3PrevBalance = IERC20(CDX).balanceOf(
    //     //     multipleUsers.user3
    //     // );
    //     for (uint256 idx = 0; idx < 365 days; idx += time) {
    //         if (idx == 90 days) {
    //             vm.startPrank(multipleUsers.user1);
    //             ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
    //             multipleUsers.user1Relic =
    //                 reliquary.createRelicAndDeposit(multipleUsers.user1, 0, amount);
    //             vm.stopPrank();
    //         }
    //         if (idx == 180 days) {
    //             vm.startPrank(multipleUsers.user2);
    //             ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
    //             multipleUsers.user2Relic =
    //                 reliquary.createRelicAndDeposit(multipleUsers.user2, 0, amount);
    //             vm.stopPrank();
    //             childRewarders[0].fund(1000e6);
    //         }
    //         if (idx == 270 days) {
    //             vm.startPrank(multipleUsers.user3);
    //             ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
    //             multipleUsers.user3Relic =
    //                 reliquary.createRelicAndDeposit(multipleUsers.user3, 0, amount);
    //             vm.stopPrank();
    //         }
    //         skip(time);
    //         // reliquary.update(relicId, address(this));
    //         // console2.log("Relic id: ", relicId);
    //         // reliquary.pendingReward(1) is the bootstrapped relic.
    //         // assertApproxEqAbs(
    //         //     reliquary.pendingReward(relicId) + reliquary.pendingReward(1),
    //         //     time * emissionRate,
    //         //     (time * emissionRate) / 100000
    //         // ); // max 0,0001%

    //         // console2.log("1. Pending rewards: ", reliquary.pendingReward(relicId));
    //         console2.log(
    //             "Main user Day %s. Balance of USDC: %6e",
    //             idx / 1 days,
    //             IERC20(USDC).balanceOf(multipleUsers.mainUser)
    //         );
    //         console2.log(
    //             "User1 Day %s. Balance of USDC: %6e",
    //             idx / 1 days,
    //             IERC20(USDC).balanceOf(multipleUsers.user1)
    //         );
    //         console2.log(
    //             "User2 Day %s. Balance of USDC: %6e",
    //             idx / 1 days,
    //             IERC20(USDC).balanceOf(multipleUsers.user2)
    //         );
    //         console2.log(
    //             "User3 Day %s. Balance of USDC: %6e",
    //             idx / 1 days,
    //             IERC20(USDC).balanceOf(multipleUsers.user3)
    //         );
    //         uint256 tmpDiff = IERC20(USDC).balanceOf(multipleUsers.mainUser)
    //             >= multipleUsers.mainUserPrevBalance
    //             ? IERC20(USDC).balanceOf(multipleUsers.mainUser) - multipleUsers.mainUserPrevBalance
    //             : 0;
    //         console2.log("Main user Day %s. Diff USDC: %6e", idx / 1 days, tmpDiff);
    //         tmpDiff = IERC20(USDC).balanceOf(multipleUsers.user1) >= multipleUsers.user1PrevBalance
    //             ? IERC20(USDC).balanceOf(multipleUsers.user1) - multipleUsers.user1PrevBalance
    //             : 0;
    //         console2.log("User1 Day %s. Diff USDC: %6e", idx / 1 days, tmpDiff);
    //         tmpDiff = IERC20(USDC).balanceOf(multipleUsers.user2) >= multipleUsers.user2PrevBalance
    //             ? IERC20(USDC).balanceOf(multipleUsers.user2) - multipleUsers.user2PrevBalance
    //             : 0;
    //         console2.log("User2 Day %s. Diff USDC: %6e", idx / 1 days, tmpDiff);
    //         tmpDiff = IERC20(USDC).balanceOf(multipleUsers.user3) >= multipleUsers.user3PrevBalance
    //             ? IERC20(USDC).balanceOf(multipleUsers.user3) - multipleUsers.user3PrevBalance
    //             : 0;
    //         console2.log("User3 Day %s. Diff USDC: %6e", idx / 1 days, tmpDiff);

    //         multipleUsers.mainUserPrevBalance = IERC20(USDC).balanceOf(multipleUsers.mainUser);
    //         vm.prank(multipleUsers.mainUser);
    //         reliquary.update(multipleUsers.mainUserRelic, multipleUsers.mainUser);
    //         if (idx >= 90 days) {
    //             multipleUsers.user1PrevBalance = IERC20(USDC).balanceOf(multipleUsers.user1);
    //             vm.prank(multipleUsers.user1);
    //             reliquary.update(multipleUsers.user1Relic, multipleUsers.user1);
    //         }
    //         if (idx >= 180 days) {
    //             multipleUsers.user2PrevBalance = IERC20(USDC).balanceOf(multipleUsers.user2);
    //             vm.prank(multipleUsers.user2);
    //             reliquary.update(multipleUsers.user2Relic, multipleUsers.user2);
    //         }
    //         if (idx >= 270 days) {
    //             multipleUsers.user3PrevBalance = IERC20(USDC).balanceOf(multipleUsers.user3);
    //             vm.prank(multipleUsers.user3);
    //             reliquary.update(multipleUsers.user3Relic, multipleUsers.user3);
    //         }

    //         // console2.log("2. Pending rewards: ", reliquary.pendingReward(relicId));
    //     }

    //     // assert(false);
    // }

    // function testPendingUsdcRewardFromChild_1Year(uint256 amount, uint256 time) public {
    //     MultipleUsers memory multipleUsers;
    //     multipleUsers.mainUser = makeAddr("mainUser");
    //     multipleUsers.user1 = makeAddr("User1");
    //     multipleUsers.user2 = makeAddr("User2");
    //     multipleUsers.user3 = makeAddr("User3");

    //     deal(CDX, multipleUsers.mainUser, 1000 ether);
    //     deal(CDX, multipleUsers.user1, 1000 ether);
    //     deal(CDX, multipleUsers.user2, 1000 ether);
    //     deal(CDX, multipleUsers.user3, 1000 ether);

    //     testToken.mint(address(reliquary), 0); // 0 main reward from parent
    //     time = 3 days; //bound(time, 0, 365 days);
    //     childRewarders.push(RollingRewarder(parentRewarder.createChild(USDC)));
    //     childRewarders[0].updateDistributionPeriod(400 days);
    //     ERC20Mock(USDC).approve(address(childRewarders[0]), type(uint256).max);
    //     childRewarders[0].fund(1000e6);
    //     amount = 1000e18; //bound(amount, 1, IERC20(CDX).balanceOf(address(this)));

    //     vm.startPrank(multipleUsers.mainUser);
    //     ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
    //     multipleUsers.mainUserRelic =
    //         reliquary.createRelicAndDeposit(multipleUsers.mainUser, 0, amount);
    //     vm.stopPrank();

    //     multipleUsers.mainUserPrevBalance = IERC20(USDC).balanceOf(multipleUsers.mainUser);
    //     // multipleUsers.user1PrevBalance = IERC20(CDX).balanceOf(
    //     //     multipleUsers.user1
    //     // );
    //     // multipleUsers.user2PrevBalance = IERC20(CDX).balanceOf(
    //     //     multipleUsers.user2
    //     // );
    //     // multipleUsers.user3PrevBalance = IERC20(CDX).balanceOf(
    //     //     multipleUsers.user3
    //     // );
    //     for (uint256 idx = 0; idx < 400 days; idx += time) {
    //         if (idx == 90 days) {
    //             vm.startPrank(multipleUsers.user1);
    //             ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
    //             multipleUsers.user1Relic =
    //                 reliquary.createRelicAndDeposit(multipleUsers.user1, 0, amount);
    //             vm.stopPrank();
    //         }
    //         if (idx == 180 days) {
    //             vm.startPrank(multipleUsers.user2);
    //             ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
    //             multipleUsers.user2Relic =
    //                 reliquary.createRelicAndDeposit(multipleUsers.user2, 0, amount);
    //             vm.stopPrank();
    //             // childRewarders[0].fund(1000e6);
    //         }
    //         if (idx == 270 days) {
    //             vm.startPrank(multipleUsers.user3);
    //             ERC20Mock(CDX).approve(address(reliquary), type(uint256).max);
    //             multipleUsers.user3Relic =
    //                 reliquary.createRelicAndDeposit(multipleUsers.user3, 0, amount);
    //             vm.stopPrank();
    //         }
    //         skip(time);

    //         PositionInfo memory positionInfo =
    //             reliquary.getPositionForId(multipleUsers.mainUserRelic);
    //         ICurvesData curve =
    //             ICurvesData(address(reliquary.getPoolInfo(uint8(positionInfo.poolId)).curve));
    //         uint256 multiplier =
    //             (curve.getFunction(uint256(positionInfo.level)) * 10_000) / curve.minMultiplier();

    //         console2.log(
    //             "Main user Day %s. Pending USDC: %6e",
    //             idx / 1 days,
    //             childRewarders[0].pendingToken(multipleUsers.mainUserRelic)
    //         );
    //         console2.log("Main user multiplier: ", multiplier);
    //         console2.log(
    //             "User1 Day %s. Pending USDC: %6e",
    //             idx / 1 days,
    //             childRewarders[0].pendingToken(multipleUsers.user1Relic)
    //         );
    //         console2.log(
    //             "User2 Day %s. Pending USDC: %6e",
    //             idx / 1 days,
    //             childRewarders[0].pendingToken(multipleUsers.user2Relic)
    //         );
    //         console2.log(
    //             "User3 Day %s. Pending USDC: %6e",
    //             idx / 1 days,
    //             childRewarders[0].pendingToken(multipleUsers.user3Relic)
    //         );

    //         vm.prank(multipleUsers.mainUser);
    //         reliquary.update(multipleUsers.mainUserRelic, multipleUsers.mainUser);
    //         if (idx >= 90 days) {
    //             vm.prank(multipleUsers.user1);
    //             reliquary.update(multipleUsers.user1Relic, multipleUsers.user1);
    //         }
    //         if (idx >= 180 days) {
    //             vm.prank(multipleUsers.user2);
    //             reliquary.update(multipleUsers.user2Relic, multipleUsers.user2);
    //         }
    //         if (idx >= 270 days) {
    //             vm.prank(multipleUsers.user3);
    //             reliquary.update(multipleUsers.user3Relic, multipleUsers.user3);
    //         }

    //         // console2.log("2. Pending rewards: ", reliquary.pendingReward(relicId));
    //     }

    //     assert(false);
    // }
}
