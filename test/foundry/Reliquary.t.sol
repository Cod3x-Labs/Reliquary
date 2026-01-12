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
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ReliquaryV2} from "test/foundry/mocks/ReliquaryV2.sol";
import {IERC1967} from "openzeppelin-contracts/contracts/interfaces/IERC1967.sol";

contract ReliquaryTest is ERC721Holder, Test {
    using Strings for address;
    using Strings for uint256;

    Reliquary reliquaryImpl;
    Reliquary reliquary;
    LinearCurve linearCurve;
    LinearPlateauCurve linearPlateauCurve;
    PolynomialPlateauCurve polynomialPlateauCurve;
    ERC20Mock oath;
    ERC20Mock testToken;
    address nftDescriptor;
    uint256 emissionRate = 1e17;

    // Linear function config (to config)
    uint256 slope = 100; // Increase of multiplier every second
    uint256 minMultiplier = 365 days * 100; // Arbitrary (but should be coherent with slope)
    uint256 plateau = 10 days;
    int256[] public coeff =
        [int256(100e18), int256(1e18), int256(5e15), int256(-1e13), int256(5e9)];

    function setUp() public {
        int256[] memory coeffDynamic = new int256[](5);
        for (uint256 i = 0; i < 5; i++) {
            coeffDynamic[i] = coeff[i];
        }

        oath = new ERC20Mock(18);
        // Encode initialization call with ALL parameters
        bytes memory data = abi.encodeWithSelector(
            Reliquary.initialize.selector,
            address(oath), // _rewardToken
            emissionRate, // _emissionRate
            "Reliquary Deposit", // _name
            "RELIC", // _symbol
            uint256(0), // _minStakingAmount
            address(0)
        );

        // Deploy implementation
        reliquaryImpl = new Reliquary();
        // Deploy proxy with encoded initialization - initializer runs here
        ERC1967Proxy proxy = new ERC1967Proxy(address(reliquaryImpl), data);
        address implll =
            address(uint160(uint256(vm.load(address(proxy), ERC1967Utils.IMPLEMENTATION_SLOT))));
        console2.log("Implementation: ", implll);
        // address implll = ERC1967Utils.getImplementation();
        // Cast proxy to contract interface (NO second initialize call)
        reliquary = Reliquary(address(proxy));
        linearPlateauCurve = new LinearPlateauCurve(slope, minMultiplier, plateau);
        linearCurve = new LinearCurve(slope, minMultiplier);
        polynomialPlateauCurve = new PolynomialPlateauCurve(coeffDynamic, 850);

        oath.mint(address(reliquary), 100_000_000 ether);

        testToken = new ERC20Mock(6);
        nftDescriptor = address(new NFTDescriptor(address(reliquary)));

        reliquary.grantRole(keccak256("OPERATOR"), address(this));
        testToken.mint(address(this), 100_000_000 ether);
        testToken.approve(address(reliquary), 1);
        reliquary.addPool(
            100,
            address(testToken),
            address(0),
            linearCurve,
            "ETH Pool",
            nftDescriptor,
            true,
            address(5)
        );

        testToken.approve(address(reliquary), type(uint256).max);
    }

    function testPolynomialCurve() public view {
        console.log(polynomialPlateauCurve.getFunction(8500));
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
        amount = bound(amount, 1, testToken.balanceOf(address(this)));
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
        amount = bound(amount, 1, testToken.balanceOf(address(this)));
        vm.expectEmit(true, true, true, true);
        emit ReliquaryEvents.Deposit(0, amount, address(this), 2);
        reliquary.createRelicAndDeposit(address(this), 0, amount);
    }

    function testDepositExisting(uint256 amountA, uint256 amountB) public {
        amountA = bound(amountA, 1, type(uint256).max / 2);
        amountB = bound(amountB, 1, type(uint256).max / 2);
        vm.assume(amountA + amountB <= testToken.balanceOf(address(this)));
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
        amount = bound(amount, 1, testToken.balanceOf(address(this)));
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, amount);
        vm.expectEmit(true, true, true, true);
        emit ReliquaryEvents.Withdraw(0, amount, address(this), relicId);
        reliquary.withdraw(amount, relicId, address(0));
    }

    function testRevertOnWithdrawUnauthorized() public {
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, 1);
        vm.startPrank(address(1));
        vm.expectRevert(IReliquary.Reliquary__NOT_APPROVED_OR_OWNER.selector);
        reliquary.withdraw(1, relicId, address(0));
    }

    function testHarvest() public {
        testToken.transfer(address(1), 1.25 ether);

        vm.startPrank(address(1));
        testToken.approve(address(reliquary), type(uint256).max);
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
    }

    function testRevertOnHarvestUnauthorized() public {
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, 1);
        vm.expectRevert(IReliquary.Reliquary__NOT_APPROVED_OR_OWNER.selector);
        vm.prank(address(1));
        reliquary.update(relicId, address(this));
    }

    function testSplit(uint256 depositAmount, uint256 splitAmount) public {
        depositAmount = bound(depositAmount, 1, testToken.balanceOf(address(this)));
        splitAmount = bound(splitAmount, 1, depositAmount);

        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, depositAmount);
        uint256 newRelicId = reliquary.split(relicId, splitAmount, address(this));

        assertEq(reliquary.balanceOf(address(this)), 2);
        assertEq(reliquary.getPositionForId(relicId).amount, depositAmount - splitAmount);
        assertEq(reliquary.getPositionForId(newRelicId).amount, splitAmount);
    }

    function testRevertOnSplitUnderflow(uint256 depositAmount, uint256 splitAmount) public {
        depositAmount = bound(depositAmount, 1, testToken.balanceOf(address(this)) / 2 - 1);
        splitAmount = bound(
            splitAmount, depositAmount + 1, testToken.balanceOf(address(this)) - depositAmount
        );

        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, depositAmount);
        vm.expectRevert(stdError.arithmeticError);
        reliquary.split(relicId, splitAmount, address(this));
    }

    function testShift(uint256 depositAmount1, uint256 depositAmount2, uint256 shiftAmount) public {
        depositAmount1 = bound(depositAmount1, 1, testToken.balanceOf(address(this)) - 1);
        depositAmount2 =
            bound(depositAmount2, 1, testToken.balanceOf(address(this)) - depositAmount1);
        shiftAmount = bound(shiftAmount, 1, depositAmount1);

        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, depositAmount1);
        uint256 newRelicId = reliquary.createRelicAndDeposit(address(this), 0, depositAmount2);
        reliquary.shift(relicId, newRelicId, shiftAmount);

        assertEq(reliquary.getPositionForId(relicId).amount, depositAmount1 - shiftAmount);
        assertEq(reliquary.getPositionForId(newRelicId).amount, depositAmount2 + shiftAmount);
    }

    function testRevertOnShiftUnderflow(uint256 depositAmount, uint256 shiftAmount) public {
        depositAmount = bound(depositAmount, 1, testToken.balanceOf(address(this)) / 2 - 1);
        shiftAmount = bound(
            shiftAmount, depositAmount + 1, testToken.balanceOf(address(this)) - depositAmount
        );

        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, depositAmount);
        uint256 newRelicId = reliquary.createRelicAndDeposit(address(this), 0, 1);
        vm.expectRevert(stdError.arithmeticError);
        reliquary.shift(relicId, newRelicId, shiftAmount);
    }

    function testMerge(uint256 depositAmount1, uint256 depositAmount2) public {
        depositAmount1 = bound(depositAmount1, 1, testToken.balanceOf(address(this)) - 1);
        depositAmount2 =
            bound(depositAmount2, 1, testToken.balanceOf(address(this)) - depositAmount1);

        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, depositAmount1);
        uint256 newRelicId = reliquary.createRelicAndDeposit(address(this), 0, depositAmount2);
        reliquary.merge(relicId, newRelicId);

        assertEq(reliquary.getPositionForId(newRelicId).amount, depositAmount1 + depositAmount2);
    }

    function testCompareDepositAndMerge(uint256 amount1, uint256 amount2, uint256 time) public {
        amount1 = bound(amount1, 1, testToken.balanceOf(address(this)) - 1);
        amount2 = bound(amount2, 1, testToken.balanceOf(address(this)) - amount1);
        time = bound(time, 1, 356 days * 1); // 100 years

        console.log(amount1);
        console.log(amount2);
        console.log(time);

        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, amount1);
        skip(time);
        reliquary.deposit(amount2, relicId, address(0));
        uint256 maturity1 = block.timestamp - reliquary.getPositionForId(relicId).entry;

        //reset maturity
        reliquary.withdraw(amount1 + amount2, relicId, address(0));
        reliquary.deposit(amount1, relicId, address(0));

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
        assertEq(reliquary.balanceOf(address(this)), 1);

        reliquary.burn(relicId);
        assertEq(reliquary.balanceOf(address(this)), 0);
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

    function testMinStakingDeposit(uint256 amount) public {
        amount = bound(amount, 1, 6000e18);
        uint256 id = reliquary.createRelicAndDeposit(address(this), 0, 1000);
        reliquary.setMinStakingAmount(amount);
        if (amount > 1) {
            vm.expectRevert(IReliquary.Reliquary__WRONG_INPUT.selector);
            reliquary.deposit(amount - 1, id, address(this));
        }
        reliquary.deposit(amount, id, address(this));
    }

    function testMultipleInitalizationRevert() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        reliquary.initialize(
            address(oath), emissionRate - 1, "Reliquary Depositt", "REELIC", 1, address(0)
        );
    }

    function testInitialized() public {
        assertEq(reliquary.rewardToken(), address(oath));
        assertEq(reliquary.emissionRate(), emissionRate);
    }

    function testImplementationAddressSet() public {
        address implAddress = address(
            uint160(uint256(vm.load(address(reliquary), ERC1967Utils.IMPLEMENTATION_SLOT)))
        );
        assertNotEq(implAddress, address(0));
        assertTrue(implAddress != address(reliquary));
    }

    function testUpgradeToV2() public {
        // Deploy V2 implementation
        ReliquaryV2 implV2 = new ReliquaryV2();

        // Upgrade proxy to V2
        vm.expectEmit(true, true, false, false, address(reliquary));
        emit IERC1967.Upgraded(address(implV2));
        reliquary.upgradeToAndCall(address(implV2), "");

        // Verify implementation address changed
        address newImplAddress = address(
            uint160(uint256(vm.load(address(reliquary), ERC1967Utils.IMPLEMENTATION_SLOT)))
        );
        assertEq(newImplAddress, address(implV2));
        assertNotEq(newImplAddress, address(reliquary));
    }

    // Test storage preserved after upgrade
    function testStoragePreservedAfterUpgrade() public {
        // Store initial values in V1
        uint256 initialEmissionRate = reliquary.emissionRate();
        address initialRewardToken = reliquary.rewardToken();

        // Deploy V2 and upgrade
        ReliquaryV2 implV2 = new ReliquaryV2();
        reliquary.upgradeToAndCall(address(implV2), "");

        // Cast to V2 and check storage
        ReliquaryV2 reliquaryV2AfterUpgrade = ReliquaryV2(address(reliquary));

        // Verify storage not corrupted
        assertEq(reliquaryV2AfterUpgrade.emissionRate(), initialEmissionRate);
        assertEq(reliquaryV2AfterUpgrade.rewardToken(), initialRewardToken);
        assertEq(reliquaryV2AfterUpgrade.minStakingAmount(), 0);
    }

    // Test new V2 functions are accessible
    function testNewV2FunctionsAccessible(uint256 amount) public {
        // Upgrade to V2
        ReliquaryV2 implV2 = new ReliquaryV2();
        reliquary.upgradeToAndCall(address(implV2), "");

        ReliquaryV2 v2Proxy = ReliquaryV2(address(reliquary));

        // Test new V2 function
        amount = bound(amount, 1, testToken.balanceOf(address(this)));
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, amount);
        uint256 initialAmount = testToken.balanceOf(address(this));
        v2Proxy.emergencyWithdraw(relicId);
        console2.log("Initial amount:", initialAmount);
        console2.log("Final amount:", testToken.balanceOf(address(this)));
        assertEq(testToken.balanceOf(address(this)), initialAmount + amount);
    }

    function testV2InitializationRevert() public {
        ReliquaryV2 implV2 = new ReliquaryV2();

        bytes memory data = abi.encodeWithSelector(
            Reliquary.initialize.selector,
            makeAddr("NewAddr"), // _rewardToken
            emissionRate + 2, // _emissionRate
            "ReliquaryV2 Deposit", // _name
            "RELIC2", // _symbol
            uint256(2e6), // _minStakingAmount
            address(0)
        );

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        reliquary.upgradeToAndCall(address(implV2), data);

        ReliquaryV2 v2Proxy = ReliquaryV2(address(reliquary));

        // Initialization values shouldn't be changed
        assertEq(v2Proxy.rewardToken(), address(oath));
        assertEq(v2Proxy.emissionRate(), emissionRate);
        assertEq(v2Proxy.minStakingAmount(), 0);
    }

    function testOnlyOwnerCanUpgrade() public {
        ReliquaryV2 implV2 = new ReliquaryV2();
        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert();
        reliquary.upgradeToAndCall(address(implV2), "");
    }

    // Test storage layout compatibility - NO VARIABLE REORDERING
    function testStorageLayoutCompatibility() public {
        // Record all original storage values
        address originalRewardToken = reliquary.rewardToken();
        uint256 originalEmissionRate = reliquary.emissionRate();
        uint256 originalMinStakingAmount = reliquary.minStakingAmount();

        // Upgrade to V2
        ReliquaryV2 implV2 = new ReliquaryV2();
        reliquary.upgradeToAndCall(address(implV2), "");

        // Cast and verify original storage preserved
        ReliquaryV2 v2Proxy = ReliquaryV2(address(reliquary));

        // ✓ All original storage preserved in same slots
        assertEq(v2Proxy.rewardToken(), originalRewardToken);
        assertEq(v2Proxy.emissionRate(), originalEmissionRate);
        assertEq(v2Proxy.minStakingAmount(), originalMinStakingAmount);
    }

    // Test multiple state mutations before and after upgrade
    function testMultipleStateChangesPreserved(uint256 amountA, uint256 amountB) public {
        // For now, just verify the structure supports state changes
        uint256 preUpgradeEmissionRate = reliquary.emissionRate();
        assertEq(preUpgradeEmissionRate, emissionRate);

        amountA = bound(amountA, 1, type(uint256).max / 2);
        amountB = bound(amountB, 1, type(uint256).max / 2);
        vm.assume(amountA + amountB <= testToken.balanceOf(address(this)));
        uint256 relicId = reliquary.createRelicAndDeposit(address(this), 0, amountA);
        reliquary.deposit(amountB, relicId, address(0));
        assertEq(reliquary.getPositionForId(relicId).amount, amountA + amountB);

        // After upgrade
        ReliquaryV2 implV2 = new ReliquaryV2();
        reliquary.upgradeToAndCall(address(implV2), "");

        ReliquaryV2 v2Proxy = ReliquaryV2(address(reliquary));
        assertEq(v2Proxy.emissionRate(), preUpgradeEmissionRate);
        assertEq(reliquary.getPositionForId(relicId).amount, amountA + amountB);
    }
}
