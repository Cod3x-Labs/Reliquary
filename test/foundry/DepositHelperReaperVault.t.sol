// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "openzeppelin-contracts/contracts/token/ERC721/utils/ERC721Holder.sol";
import "contracts/helpers/DepositHelperReaperVault.sol";
import "contracts/nft_descriptors/NFTDescriptor.sol";
import "contracts/Reliquary.sol";
import "contracts/curves/LinearCurve.sol";

interface IReaperVaultTest is IReaperVault {
    function balance() external view returns (uint256);

    function tvlCap() external view returns (uint256);

    function withdrawalQueue(uint256) external view returns (IStrategy);
}

interface IStrategy is IAccessControlEnumerable {
    function harvest() external;
}

contract DepositHelperReaperVaultTest is ERC721Holder, Test {
    DepositHelperReaperVault helper;
    Reliquary reliquary;
    LinearCurve linearCurve;
    IReaperVaultTest wethVault = IReaperVaultTest(0x1bAd45E92DCe078Cf68C2141CD34f54A02c92806);
    IReaperVaultTest usdcVault = IReaperVaultTest(0x508734b52BA7e04Ba068A2D4f67720Ac1f63dF47);
    IReaperVaultTest sternVault = IReaperVaultTest(0x3eE6107d9C93955acBb3f39871D32B02F82B78AB);
    IERC20 oath;
    IWeth weth;
    uint256 emissionRate = 1e17;

    // Linear function config (to config)
    uint256 slope = 100; // Increase of multiplier every second
    uint256 minMultiplier = 365 days * 100; // Arbitrary (but should be coherent with slope)

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("optimism", 111980000);

        oath = IERC20(0x00e1724885473B63bCE08a9f0a52F35b0979e35A);
        reliquary = new Reliquary(address(oath), emissionRate, "Reliquary Deposit", "RELIC");
        linearCurve = new LinearCurve(slope, minMultiplier);

        address nftDescriptor = address(new NFTDescriptor(address(reliquary)));
        deal(address(wethVault), address(this), 1);
        wethVault.approve(address(reliquary), 1); // approve 1 wei to bootstrap the pool
        reliquary.addPool(
            1000,
            address(wethVault),
            address(0),
            linearCurve,
            "WETH",
            nftDescriptor,
            true,
            address(this)
        );
        deal(address(usdcVault), address(this), 1);
        usdcVault.approve(address(reliquary), 1); // approve 1 wei to bootstrap the pool
        reliquary.addPool(
            1000,
            address(usdcVault),
            address(0),
            linearCurve,
            "USDC",
            nftDescriptor,
            true,
            address(this)
        );
        deal(address(sternVault), address(this), 1);
        sternVault.approve(address(reliquary), 1); // approve 1 wei to bootstrap the pool
        reliquary.addPool(
            1000,
            address(sternVault),
            address(0),
            linearCurve,
            "ERN",
            nftDescriptor,
            true,
            address(this)
        );

        weth = IWeth(address(wethVault.token()));
        helper = new DepositHelperReaperVault(reliquary, address(weth));

        weth.deposit{value: 1_000_000 ether}();
        weth.approve(address(helper), type(uint256).max);
        helper.reliquary().setApprovalForAll(address(helper), true);
    }

    function testCreateNew(uint256 amount, bool depositETH) public {
        amount = bound(amount, 10, weth.balanceOf(address(this)));
        (uint256 relicId, uint256 shares) =
            helper.createRelicAndDeposit{value: depositETH ? amount : 0}(0, amount);

        assertEq(weth.balanceOf(address(helper)), 0);
        assertEq(reliquary.balanceOf(address(this)), 4, "no Relic given");
        assertEq(
            reliquary.getPositionForId(relicId).amount,
            shares,
            "deposited amount not expected amount"
        );
    }

    function testDepositExisting(uint256 amountA, uint256 amountB, bool aIsETH, bool bIsETH)
        public
    {
        amountA = bound(amountA, 10, 0.5 ether);
        amountB = bound(amountB, 10, 1 ether - amountA);

        (uint256 relicId, uint256 sharesA) =
            helper.createRelicAndDeposit{value: aIsETH ? amountA : 0}(0, amountA);
        uint256 sharesB = helper.deposit{value: bIsETH ? amountB : 0}(amountB, relicId, false);

        assertEq(weth.balanceOf(address(helper)), 0);
        uint256 relicAmount = reliquary.getPositionForId(relicId).amount;
        assertEq(relicAmount, sharesA + sharesB);
    }

    function testRevertOnDepositUnauthorized() public {
        (uint256 relicId,) = helper.createRelicAndDeposit(0, 1 ether);
        vm.expectRevert(bytes("not approved or owner"));
        vm.prank(address(1));
        helper.deposit(1 ether, relicId, true);
    }

    function testWithdraw(uint256 amount, bool harvest, bool depositETH, bool withdrawETH) public {
        uint256 ethInitialBalance = address(this).balance;
        uint256 wethInitialBalance = weth.balanceOf(address(this));
        amount = bound(amount, 10, 1 ether);

        (uint256 relicId,) = helper.createRelicAndDeposit{value: depositETH ? amount : 0}(0, amount);
        if (depositETH) {
            assertEq(address(this).balance, ethInitialBalance - amount);
        } else {
            assertEq(weth.balanceOf(address(this)), wethInitialBalance - amount);
        }

        IStrategy strategy = usdcVault.withdrawalQueue(0);
        vm.prank(strategy.getRoleMember(keccak256("STRATEGIST"), 0));
        strategy.harvest();

        helper.withdraw(amount, relicId, harvest, withdrawETH);

        uint256 difference;
        if (depositETH && withdrawETH) {
            difference = ethInitialBalance - address(this).balance;
        } else if (depositETH && !withdrawETH) {
            difference = weth.balanceOf(address(this)) - wethInitialBalance;
        } else if (!depositETH && withdrawETH) {
            difference = address(this).balance - ethInitialBalance;
        } else {
            difference = wethInitialBalance - weth.balanceOf(address(this));
        }

        uint256 expectedDifference = (depositETH == withdrawETH) ? 0 : amount;
        assertApproxEqAbs(difference, expectedDifference, 10);
    }

    function testWithdrawUSDC(uint256 amount, bool harvest) public {
        amount = bound(amount, 10, 1e15);
        IERC20 usdc = usdcVault.token();
        assertEq(usdc.balanceOf(address(this)), 0);
        deal(address(usdc), address(this), amount);
        usdc.approve(address(helper), amount);

        (uint256 relicId,) = helper.createRelicAndDeposit(1, amount);
        assertEq(usdc.balanceOf(address(this)), 0);

        IStrategy strategy = usdcVault.withdrawalQueue(0);
        vm.prank(strategy.getRoleMember(keccak256("STRATEGIST"), 0));
        strategy.harvest();

        helper.withdraw(amount, relicId, harvest, false);

        assertApproxEqAbs(usdc.balanceOf(address(this)), amount, 10);
    }

    function testWithdrawStERN(uint256 amount, bool harvest) public {
        amount = bound(amount, 10, sternVault.tvlCap() - sternVault.balance());
        IERC20 ern = sternVault.token();
        assertEq(ern.balanceOf(address(this)), 0);
        deal(address(ern), address(this), amount);
        ern.approve(address(helper), type(uint256).max);

        (uint256 relicId,) = helper.createRelicAndDeposit(2, amount);
        assertEq(ern.balanceOf(address(this)), 0);

        IStrategy strategy = sternVault.withdrawalQueue(0);
        vm.prank(strategy.getRoleMember(keccak256("STRATEGIST"), 0));
        strategy.harvest();

        helper.withdraw(amount, relicId, harvest, false);

        assertApproxEqAbs(ern.balanceOf(address(this)), amount, 10);
    }

    function testRevertOnWithdrawUnauthorized(bool harvest, bool isETH) public {
        (uint256 relicId,) = helper.createRelicAndDeposit(0, 1 ether);
        vm.expectRevert(bytes("not approved or owner"));
        vm.prank(address(1));
        helper.withdraw(1 ether, relicId, harvest, isETH);
    }
}
