// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "contracts/Reliquary.sol";
import "contracts/interfaces/IReliquary.sol";
import "contracts/nft_descriptors/NFTDescriptor.sol";
import "contracts/curves/LinearPlateauCurve.sol";
import "./mocks/ERC20Mock.sol";
import "contracts/rehypothecation_adapters/GaugeBalancer.sol";

contract ReliquaryBlancerGaugeTest is ERC721Holder, Test {
    using Strings for address;
    using Strings for uint256;

    Reliquary reliquary;
    LinearPlateauCurve linearPlateauCurve;
    ERC20Mock oath;
    GaugeBalancer gaugeBalancer;

    address nftDescriptor;
    uint256 emissionRate = 1e17;

    // Linear function config (to config)
    uint256 slope = 100; // Increase of multiplier every second
    uint256 minMultiplier = 365 days * 100; // Arbitrary (but should be coherent with slope)
    uint256 plateau = 10 days;
    address treasury = address(0xccc);

    uint256 forkIdPolygon;
    address wmatic = address(0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270);
    address balToken = address(0xba100000625a3754423978a60c9317c58a424e3D);
    address balancerPool = address(0x4B7586A4F49841447150D3d92d9E9e000f766c30);
    address gauge = address(0x07dAcD2229824D6Ff928181563745a573b026B3d);
    address dai = address(0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063);

    function setUp() public {
        forkIdPolygon = vm.createFork(vm.envString("POLYGON_RPC_URL"), 58870669);
        vm.selectFork(forkIdPolygon);

        oath = new ERC20Mock(18);
        reliquary = new Reliquary(address(oath), emissionRate, "Reliquary Deposit", "RELIC");
        linearPlateauCurve = new LinearPlateauCurve(slope, minMultiplier, plateau);

        oath.mint(address(reliquary), 100_000_000 ether);

        nftDescriptor = address(new NFTDescriptor(address(reliquary)));

        reliquary.grantRole(keccak256("OPERATOR"), address(this));
        deal(balancerPool, address(this), 100_000_000 ether);
        IERC20(balancerPool).approve(address(reliquary), 1);
        reliquary.addPool(
            100,
            address(balancerPool),
            address(0),
            linearPlateauCurve,
            "ETH Pool",
            nftDescriptor,
            true,
            address(this)
        );

        gaugeBalancer = new GaugeBalancer(address(reliquary), gauge, balancerPool);

        IERC20(balancerPool).approve(address(gaugeBalancer), type(uint256).max);
        IERC20(balancerPool).approve(address(reliquary), type(uint256).max);

        reliquary.setTreasury(treasury);
        reliquary.enableRehypothecation(0, address(gaugeBalancer));
    }

    function testModifyPool() public {
        vm.expectEmit(true, true, false, true);
        emit ReliquaryEvents.LogPoolModified(0, 100, address(0), nftDescriptor);
        reliquary.modifyPool(0, 100, address(0), "USDC Pool", nftDescriptor, true);
    }

    function testRevertOnModifyInvalidPool() public {
        vm.expectRevert(IReliquary.Reliquary__NON_EXISTENT_POOL.selector);
        reliquary.modifyPool(1, 100, address(0), "USDC Pool", nftDescriptor, true);
    }

    function testRevertOnModifyPoolUnauthorized() public {
        vm.expectRevert();
        vm.prank(address(1));
        reliquary.modifyPool(0, 100, address(0), "USDC Pool", nftDescriptor, true);
    }

    function testPendingOath(uint256 amount, uint256 time) public {
        time = bound(time, 0, 3650 days);
        amount = bound(amount, 1, IERC20(balancerPool).balanceOf(address(this)));
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, amount);
        skip(time);
        reliquary.update(relicId, address(0));
        // reliquary.pendingReward(1) is the bootstrapped relic.
        assertApproxEqAbs(
            reliquary.pendingReward(relicId) + reliquary.pendingReward(1),
            time * emissionRate,
            (time * emissionRate) / 100000
        ); // max 0,0001%
    }

    function testCreateRelicAndDeposit(uint256 amount) public {
        amount = bound(amount, 1, IERC20(balancerPool).balanceOf(address(this)));
        vm.expectEmit(true, true, true, true);
        emit ReliquaryEvents.Deposit(0, amount, address(this), 2);
        reliquary.createRelicAndDeposit(address(this), 0, amount);
    }

    function testDepositExisting(uint256 amountA, uint256 amountB) public {
        amountA = bound(amountA, 1, type(uint256).max / 2);
        amountB = bound(amountB, 1, type(uint256).max / 2);
        vm.assume(amountA + amountB <= IERC20(balancerPool).balanceOf(address(this)));
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, amountA);
        reliquary.deposit(amountB, relicId, address(0));
        assertEq(reliquary.getPositionForId(relicId).amount, amountA + amountB);
    }

    function testRevertOnDepositInvalidPool(uint8 pool) public {
        pool = uint8(bound(pool, 1, type(uint8).max));
        vm.expectRevert(IReliquary.Reliquary__NON_EXISTENT_POOL.selector);
        reliquary.createRelicAndDeposit(address(this), pool, 1);
    }

    function testRevertOnDepositUnauthorized() public {
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, 1);
        vm.expectRevert(IReliquary.Reliquary__NOT_APPROVED_OR_OWNER.selector);
        vm.prank(address(1));
        reliquary.deposit(1, relicId, address(0));
    }

    function testWithdraw(uint256 amount) public {
        amount = bound(amount, 1, IERC20(balancerPool).balanceOf(address(this)));
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, amount);
        vm.expectEmit(true, true, true, true);
        emit ReliquaryEvents.Withdraw(0, amount, address(this), relicId);
        reliquary.withdraw(amount, relicId, address(0));
    }

    function testRevertOnWithdrawUnauthorized() public {
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, 1);
        vm.expectRevert(IReliquary.Reliquary__NOT_APPROVED_OR_OWNER.selector);
        vm.prank(address(1));
        reliquary.withdraw(1, relicId, address(0));
    }

    function testHarvest() public {
        IERC20(balancerPool).transfer(address(1), 1.25 ether);

        vm.startPrank(address(1));
        IERC20(balancerPool).approve(address(reliquary), type(uint256).max);
        uint256 relicIdA = reliquary.createRelicAndDeposit(address(1), 0, 1 ether);
        skip(180 days);
        reliquary.withdraw(0.75 ether, relicIdA, address(0));
        reliquary.deposit(1 ether, relicIdA, address(0));

        // Gauge claim
        uint256 treasuryBalanceBefore = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertGt(IERC20(wmatic).balanceOf(treasury), treasuryBalanceBefore);
        uint256 treasuryBalanceMid = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertEq(IERC20(wmatic).balanceOf(treasury), treasuryBalanceMid);

        vm.stopPrank();
        uint256 relicIdB = reliquary.createRelicAndDeposit(address(this), 0, 100 ether);
        skip(180 days);
        reliquary.update(relicIdB, address(this));

        vm.startPrank(address(1));
        reliquary.update(relicIdA, address(this));
        vm.stopPrank();

        assertApproxEqAbs(oath.balanceOf(address(this)) / 1e18, 3110400, 1);
    }

    function testDisableRehypothecation() public {
        IERC20(balancerPool).transfer(address(1), 1.25 ether);

        vm.startPrank(address(1));
        IERC20(balancerPool).approve(address(reliquary), type(uint256).max);
        uint256 relicIdA = reliquary.createRelicAndDeposit(address(1), 0, 1 ether);
        skip(180 days);
        reliquary.withdraw(0.75 ether, relicIdA, address(0));
        reliquary.deposit(1 ether, relicIdA, address(0));
        vm.stopPrank();

        // Disable rehypothecation
        uint256 treasuryBalanceBefore = IERC20(wmatic).balanceOf(treasury);
        uint256 reliquaryBalanceBefore = IERC20(balancerPool).balanceOf(address(reliquary));
        reliquary.disableRehypothecation(0, false);
        assertEq(IERC20(wmatic).balanceOf(treasury), treasuryBalanceBefore);
        assertGt(IERC20(balancerPool).balanceOf(address(reliquary)), reliquaryBalanceBefore);
        uint256 treasuryBalanceMid = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertEq(IERC20(wmatic).balanceOf(treasury), treasuryBalanceMid);

        uint256 relicIdB = reliquary.createRelicAndDeposit(address(this), 0, 100 ether);
        skip(180 days);
        reliquary.update(relicIdB, address(this));

        vm.startPrank(address(1));
        reliquary.update(relicIdA, address(this));
        vm.stopPrank();

        assertApproxEqAbs(oath.balanceOf(address(this)) / 1e18, 3110400, 1);
    }

    function testDisableRehypothecationAndClaim() public {
        IERC20(balancerPool).transfer(address(1), 1.25 ether);

        vm.startPrank(address(1));
        IERC20(balancerPool).approve(address(reliquary), type(uint256).max);
        uint256 relicIdA = reliquary.createRelicAndDeposit(address(1), 0, 1 ether);
        skip(180 days);
        reliquary.withdraw(0.75 ether, relicIdA, address(0));
        reliquary.deposit(1 ether, relicIdA, address(0));
        vm.stopPrank();

        // Disable rehypothecation
        uint256 treasuryBalanceBefore = IERC20(wmatic).balanceOf(treasury);
        uint256 reliquaryBalanceBefore = IERC20(balancerPool).balanceOf(address(reliquary));
        reliquary.disableRehypothecation(0, true);
        assertGt(IERC20(wmatic).balanceOf(treasury), treasuryBalanceBefore);
        assertGt(IERC20(balancerPool).balanceOf(address(reliquary)), reliquaryBalanceBefore);
        uint256 treasuryBalanceMid = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertEq(IERC20(wmatic).balanceOf(treasury), treasuryBalanceMid);

        uint256 relicIdB = reliquary.createRelicAndDeposit(address(this), 0, 100 ether);
        skip(180 days);
        reliquary.update(relicIdB, address(this));

        vm.startPrank(address(1));
        reliquary.update(relicIdA, address(this));
        vm.stopPrank();

        assertApproxEqAbs(oath.balanceOf(address(this)) / 1e18, 3110400, 1);
    }

    function testDisableRehypothecationAndClaim2() public {
        IERC20(balancerPool).transfer(address(1), 1.25 ether);

        vm.startPrank(address(1));
        IERC20(balancerPool).approve(address(reliquary), type(uint256).max);
        uint256 relicIdA = reliquary.createRelicAndDeposit(address(1), 0, 1 ether);
        skip(180 days);
        reliquary.withdraw(0.75 ether, relicIdA, address(0));
        reliquary.deposit(1 ether, relicIdA, address(0));
        vm.stopPrank();

        uint256 relicIdB = reliquary.createRelicAndDeposit(address(this), 0, 100 ether);
        skip(180 days);
        reliquary.update(relicIdB, address(this));

        vm.startPrank(address(1));
        reliquary.update(relicIdA, address(this));
        vm.stopPrank();

        assertApproxEqAbs(oath.balanceOf(address(this)) / 1e18, 3110400, 1);

        // Disable rehypothecation
        uint256 treasuryBalanceBefore = IERC20(wmatic).balanceOf(treasury);
        uint256 reliquaryBalanceBefore = IERC20(balancerPool).balanceOf(address(reliquary));
        reliquary.claimRehypothecation(0);
        reliquary.disableRehypothecation(0, false);
        assertGt(IERC20(wmatic).balanceOf(treasury), treasuryBalanceBefore);
        assertGt(IERC20(balancerPool).balanceOf(address(reliquary)), reliquaryBalanceBefore);
        uint256 treasuryBalanceMid = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertEq(IERC20(wmatic).balanceOf(treasury), treasuryBalanceMid);
    }

    function testRevertOnHarvestUnauthorized() public {
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, 1);
        vm.expectRevert(IReliquary.Reliquary__NOT_APPROVED_OR_OWNER.selector);
        vm.prank(address(1));
        reliquary.update(relicId, address(this));
    }

    function testEmergencyWithdraw(uint256 amount) public {
        amount = bound(amount, 1, IERC20(balancerPool).balanceOf(address(this)));
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, amount);
        vm.expectEmit(true, true, true, true);
        emit ReliquaryEvents.EmergencyWithdraw(0, amount, address(this), relicId);
        reliquary.emergencyWithdraw(relicId);
    }

    function testRevertOnEmergencyWithdrawNotOwner() public {
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, 1);
        vm.expectRevert(IReliquary.Reliquary__NOT_OWNER.selector);
        vm.prank(address(1));
        reliquary.emergencyWithdraw(relicId);
    }

    function testSplit(uint256 depositAmount, uint256 splitAmount) public {
        depositAmount = bound(depositAmount, 1, IERC20(balancerPool).balanceOf(address(this)));
        splitAmount = bound(splitAmount, 1, depositAmount);

        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, depositAmount);
        uint256 newRelicId = reliquary.split(relicId, splitAmount, address(this));

        assertEq(reliquary.balanceOf(address(this)), 3);
        assertEq(reliquary.getPositionForId(relicId).amount, depositAmount - splitAmount);
        assertEq(reliquary.getPositionForId(newRelicId).amount, splitAmount);
    }

    function testRevertOnSplitUnderflow(uint256 depositAmount, uint256 splitAmount) public {
        depositAmount =
            bound(depositAmount, 1, IERC20(balancerPool).balanceOf(address(this)) / 2 - 1);
        splitAmount = bound(
            splitAmount,
            depositAmount + 1,
            IERC20(balancerPool).balanceOf(address(this)) - depositAmount
        );

        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, depositAmount);
        vm.expectRevert(stdError.arithmeticError);
        reliquary.split(relicId, splitAmount, address(this));
    }

    function testShift(uint256 depositAmount1, uint256 depositAmount2, uint256 shiftAmount)
        public
    {
        depositAmount1 = bound(depositAmount1, 1, IERC20(balancerPool).balanceOf(address(this)) - 1);
        depositAmount2 =
            bound(depositAmount2, 1, IERC20(balancerPool).balanceOf(address(this)) - depositAmount1);
        shiftAmount = bound(shiftAmount, 1, depositAmount1);

        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, depositAmount1);
        uint256 newRelicId = reliquary.createRelicAndDeposit(address(this), 0, depositAmount2);
        reliquary.shift(relicId, newRelicId, shiftAmount);

        assertEq(reliquary.getPositionForId(relicId).amount, depositAmount1 - shiftAmount);
        assertEq(reliquary.getPositionForId(newRelicId).amount, depositAmount2 + shiftAmount);
    }

    function testRevertOnShiftUnderflow(uint256 depositAmount, uint256 shiftAmount) public {
        depositAmount =
            bound(depositAmount, 1, IERC20(balancerPool).balanceOf(address(this)) / 2 - 1);
        shiftAmount = bound(
            shiftAmount,
            depositAmount + 1,
            IERC20(balancerPool).balanceOf(address(this)) - depositAmount
        );

        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, depositAmount);
        uint256 newRelicId = reliquary.createRelicAndDeposit(address(this), 0, 1);
        vm.expectRevert(stdError.arithmeticError);
        reliquary.shift(relicId, newRelicId, shiftAmount);
    }

    function testMerge(uint256 depositAmount1, uint256 depositAmount2) public {
        depositAmount1 = bound(depositAmount1, 1, IERC20(balancerPool).balanceOf(address(this)) - 1);
        depositAmount2 =
            bound(depositAmount2, 1, IERC20(balancerPool).balanceOf(address(this)) - depositAmount1);

        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, depositAmount1);
        uint256 newRelicId = reliquary.createRelicAndDeposit(address(this), 0, depositAmount2);
        reliquary.merge(relicId, newRelicId);

        assertEq(reliquary.getPositionForId(newRelicId).amount, depositAmount1 + depositAmount2);
    }

    function testCompareDepositAndMerge(uint256 amount1, uint256 amount2, uint256 time) public {
        amount1 = bound(amount1, 1e4, IERC20(balancerPool).balanceOf(address(this)) - 1);
        amount2 = bound(amount2, 1, IERC20(balancerPool).balanceOf(address(this)) - amount1);
        time = bound(time, 1 weeks, 20 weeks);

        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, amount1);
        skip(time);
        reliquary.deposit(amount2, relicId, address(0));
        uint256 maturity1 = block.timestamp - reliquary.getPositionForId(relicId).entry;

        // Reset maturity
        reliquary.withdraw(amount1 + amount2, relicId, address(0));
        reliquary.deposit(amount1, relicId, address(0));

        // Gauge claim
        uint256 treasuryBalanceBefore = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertGt(IERC20(wmatic).balanceOf(treasury), treasuryBalanceBefore);
        uint256 treasuryBalanceMid = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertEq(IERC20(wmatic).balanceOf(treasury), treasuryBalanceMid);

        skip(time);
        uint256 newRelicId = reliquary.createRelicAndDeposit(address(this), 0, amount2);
        reliquary.merge(newRelicId, relicId);
        uint256 maturity2 = block.timestamp - reliquary.getPositionForId(relicId).entry;

        assertApproxEqAbs(maturity1, maturity2, 1);
    }

    function testMergeAfterSplit() public {
        uint256 depositAmount1 = 100 ether;
        uint256 depositAmount2 = 50 ether;
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, depositAmount1);
        skip(2 days);

        // Gauge claim
        uint256 treasuryBalanceBefore = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertGt(IERC20(wmatic).balanceOf(treasury), treasuryBalanceBefore);
        uint256 treasuryBalanceMid = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertEq(IERC20(wmatic).balanceOf(treasury), treasuryBalanceMid);

        reliquary.update(relicId, address(this));
        reliquary.split(relicId, 50 ether, address(this));
        uint256 newRelicId = reliquary.createRelicAndDeposit(address(this), 0, depositAmount2);
        reliquary.merge(relicId, newRelicId);
        assertEq(reliquary.getPositionForId(newRelicId).amount, 100 ether);
    }

    function testBurn() public {
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, 1 ether);
        vm.expectRevert(IReliquary.Reliquary__BURNING_PRINCIPAL.selector);
        reliquary.burn(relicId);

        reliquary.withdraw(1 ether, relicId, address(this));
        vm.expectRevert(IReliquary.Reliquary__NOT_APPROVED_OR_OWNER.selector);
        vm.prank(address(1));
        reliquary.burn(relicId);
        assertEq(reliquary.balanceOf(address(this)), 2);

        reliquary.burn(relicId);
        assertEq(reliquary.balanceOf(address(this)), 1);
    }

    function testPocShiftVulnerability() public {
        uint256 idParent = reliquary.createRelicAndDeposit(address(this), 0, 10000 ether);
        skip(366 days);
        reliquary.update(idParent, address(0));

        for (uint256 i = 0; i < 10; i++) {
            uint256 idChild = reliquary.createRelicAndDeposit(address(this), 0, 10 ether);
            reliquary.shift(idParent, idChild, 1);
            reliquary.update(idParent, address(0));
            uint256 levelChild = reliquary.getPositionForId(idChild).level;
            assertEq(levelChild, 0); // assert max level
        }
    }

    function testPause() public {
        reliquary.grantRole(keccak256("OPERATOR"), address(this));
        vm.expectRevert();
        reliquary.pause();

        reliquary.createRelicAndDeposit(address(this), 0, 1000);

        reliquary.grantRole(keccak256("GUARDIAN"), address(this));
        reliquary.pause();
        vm.expectRevert();
        reliquary.createRelicAndDeposit(address(this), 0, 1000);

        reliquary.unpause();
        reliquary.createRelicAndDeposit(address(this), 0, 1000);
    }

    function testRelic1Level() public {
        uint256 relic1 = 1;

        reliquary.deposit(999, 1, address(0));
        vm.stopPrank();
        uint256 relic2 = reliquary.createRelicAndDeposit(address(this), 0, 1000);

        assertEq(reliquary.getPositionForId(relic1).level, 0);
        assertEq(reliquary.getPositionForId(relic2).level, 0);

        skip(1 days);

        reliquary.update(relic1, address(0));
        reliquary.update(relic2, address(0));

        assertEq(reliquary.getPositionForId(relic1).level, 0);
        assertGt(reliquary.getPositionForId(relic2).level, 0);

        skip(1 days);

        reliquary.update(relic1, address(0));
        reliquary.update(relic2, address(0));

        assertEq(reliquary.getPositionForId(relic1).level, 0);
        assertGt(reliquary.getPositionForId(relic2).level, 0);

        // Gauge claim
        uint256 treasuryBalanceBefore = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertGt(IERC20(wmatic).balanceOf(treasury), treasuryBalanceBefore);
        uint256 treasuryBalanceMid = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertEq(IERC20(wmatic).balanceOf(treasury), treasuryBalanceMid);
    }

    function testRelic1RewardDistribution1(uint256 seedTime) public {
        uint256 time = bound(seedTime, 1 days, 365 days);

        uint256 relic1 = 1;

        reliquary.deposit(999, 1, address(0));
        vm.stopPrank();
        uint256 relic2 = reliquary.createRelicAndDeposit(address(this), 0, 1000);

        skip(time);

        reliquary.update(relic1, address(11));
        reliquary.update(relic2, address(22));

        skip(time);

        reliquary.update(relic1, address(11));
        reliquary.update(relic2, address(22));

        // test relic 1 linearity
        assertGt(oath.balanceOf(address(22)), oath.balanceOf(address(11)));

        // Gauge claim
        uint256 treasuryBalanceBefore = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertGt(IERC20(wmatic).balanceOf(treasury), treasuryBalanceBefore);
        uint256 treasuryBalanceMid = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertEq(IERC20(wmatic).balanceOf(treasury), treasuryBalanceMid);
    }

    function testRelic1RewardDistribution2(uint256 seedTime) public {
        uint256 time = bound(seedTime, 1 days, 365 days);

        uint256 relic1 = 1;

        reliquary.deposit(999, 1, address(0));
        reliquary.createRelicAndDeposit(address(this), 0, 1000);

        skip(time);

        reliquary.update(relic1, address(11));

        uint256 balance11 = oath.balanceOf(address(11));

        skip(time);

        reliquary.update(relic1, address(11));

        // test relic 1 linearity
        assertApproxEqRel(oath.balanceOf(address(11)), balance11 * 2, 1e2); // 0

        skip(time);

        // Gauge claim
        uint256 treasuryBalanceBefore = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertGt(IERC20(wmatic).balanceOf(treasury), treasuryBalanceBefore);
        uint256 treasuryBalanceMid = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertEq(IERC20(wmatic).balanceOf(treasury), treasuryBalanceMid);

        reliquary.update(relic1, address(11));

        // test relic 1 linearity
        assertApproxEqRel(oath.balanceOf(address(11)), balance11 * 3, 1e2); // 0
    }

    function testRelic2ToNRewardDistribution() public {
        uint256 time = 365 days; // bound(seedTime, 1, 365 days);

        reliquary.deposit(999, 1, address(0));
        uint256 relic2 = reliquary.createRelicAndDeposit(address(this), 0, 1000);

        skip(time);

        reliquary.update(relic2, address(22));

        uint256 balance22 = oath.balanceOf(address(22));

        skip(time);

        reliquary.update(relic2, address(22));

        // Gauge claim
        uint256 treasuryBalanceBefore = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertGt(IERC20(wmatic).balanceOf(treasury), treasuryBalanceBefore);
        uint256 treasuryBalanceMid = IERC20(wmatic).balanceOf(treasury);
        reliquary.claimRehypothecation(0);
        assertEq(IERC20(wmatic).balanceOf(treasury), treasuryBalanceMid);

        // test relic 1 linearity
        assertGt(oath.balanceOf(address(22)), balance22 * 2); // 0

        skip(time);

        reliquary.update(relic2, address(22));

        // test relic 1 linearity
        assertGt(oath.balanceOf(address(22)), balance22 * 3); // 0
    }

    function testRelic1ProhibitedActions() public {
        uint256 relic1 = 1;

        reliquary.deposit(999, 1, address(0));
        vm.stopPrank();
        uint256 relic2 = reliquary.createRelicAndDeposit(address(this), 0, 1000);

        vm.expectRevert(IReliquary.Reliquary__RELIC1_PROHIBITED_ACTION.selector);
        reliquary.split(relic1, 500, address(0));

        vm.expectRevert(IReliquary.Reliquary__RELIC1_PROHIBITED_ACTION.selector);
        reliquary.shift(relic1, relic2, 500);

        vm.expectRevert(IReliquary.Reliquary__RELIC1_PROHIBITED_ACTION.selector);
        reliquary.shift(relic2, relic1, 500);

        vm.expectRevert(IReliquary.Reliquary__RELIC1_PROHIBITED_ACTION.selector);
        reliquary.merge(relic1, relic2);

        vm.expectRevert(IReliquary.Reliquary__RELIC1_PROHIBITED_ACTION.selector);
        reliquary.merge(relic2, relic1);
    }
}
