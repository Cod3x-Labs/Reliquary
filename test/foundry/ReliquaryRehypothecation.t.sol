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

contract TestReliquaryRehypothecation is ERC721Holder, Test {
    using Strings for address;
    using Strings for uint256;

    Reliquary reliquary;
    LinearPlateauCurve linearPlateauCurve;
    ERC20Mock oath;
    GaugeBalancer gaugeBalancer;
    address nftDescriptor;
    address treasury = address(0xccc);
    uint256 emissionRate = 1e17;

    // Linear function config (to config)
    uint256 slope = 100; // Increase of multiplier every second
    uint256 minMultiplier = 365 days * 100; // Arbitrary (but should be coherent with slope)
    uint256 plateau = 10 days;

    uint256 forkIdPolygon;
    address wmatic = address(0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270);
    address balToken = address(0xba100000625a3754423978a60c9317c58a424e3D);
    address triPool = address(0x4B7586A4F49841447150D3d92d9E9e000f766c30);
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
        deal(triPool, address(this), 100_000_000 ether);
        IERC20(triPool).approve(address(reliquary), 1);
        reliquary.addPool(
            100,
            triPool,
            address(0),
            linearPlateauCurve,
            "ETH Pool",
            nftDescriptor,
            true,
            address(this)
        );

        gaugeBalancer = new GaugeBalancer(address(reliquary), gauge, triPool);

        IERC20(triPool).approve(address(gaugeBalancer), type(uint256).max);
        IERC20(triPool).approve(address(reliquary), type(uint256).max);

        reliquary.setTreasury(treasury);
        reliquary.enableRehypothecation(0, address(gaugeBalancer));
    }

    function testGaugeBalancerDirectly(uint256 _seedAmt) public {
        GaugeBalancer gaugeBalancerTemp = new GaugeBalancer(address(this), gauge, triPool);

        IERC20(triPool).approve(address(gaugeBalancerTemp), type(uint256).max);
        IERC20(triPool).approve(address(reliquary), type(uint256).max);
        reliquary.setTreasury(treasury);
        reliquary.enableRehypothecation(0, address(gaugeBalancerTemp));

        uint256 balanceBeforeBPT = IERC20(triPool).balanceOf(address(this));
        uint256 amt = bound(_seedAmt, 1000, balanceBeforeBPT);
        gaugeBalancerTemp.deposit(amt);
        skip(1 weeks);

        assertEq(balanceBeforeBPT - amt, IERC20(triPool).balanceOf(address(this)));

        uint256 balanceBeforeWmatic = IERC20(wmatic).balanceOf(address(this));

        console.log(IERC20(wmatic).balanceOf(address(this)));

        gaugeBalancerTemp.claim(address(this));

        console.log(IERC20(wmatic).balanceOf(address(this)));

        assertGt(IERC20(wmatic).balanceOf(address(this)), balanceBeforeWmatic);

        gaugeBalancerTemp.withdraw(amt);
        assertEq(balanceBeforeBPT, IERC20(triPool).balanceOf(address(this)));
    }
}
