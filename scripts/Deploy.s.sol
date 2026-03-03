// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import {PoolInfo} from "contracts/interfaces/IReliquary.sol";
import {Reliquary} from "contracts/Reliquary.sol";
import {ICurves, LinearCurve} from "contracts/curves/LinearCurve.sol";
import {LinearPlateauCurve} from "contracts/curves/LinearPlateauCurve.sol";
import {DepositHelperERC4626} from "contracts/helpers/DepositHelperERC4626.sol";
import {NFTDescriptor} from "contracts/nft_descriptors/NFTDescriptor.sol";
import {ParentRollingRewarder} from "contracts/rewarders/ParentRollingRewarder.sol";
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PolynomialPlateauCurve} from "contracts/curves/PolynomialPlateauCurve.sol";
import {CooldownWithdrawal} from "contracts/CooldownWithdrawal.sol";

contract Deploy is Script {
    using stdJson for string;

    struct Pool {
        uint256 allocPoint;
        bool allowPartialWithdrawals;
        uint256 curveIndex;
        string curveType;
        string name;
        address poolToken;
        string tokenType;
    }

    struct ParentRewarderParams {
        uint256 poolId;
    }

    struct ChildRewarderParams {
        uint256 parentIndex;
        address rewarderToken;
    }

    struct LinearCurveParams {
        uint256 minMultiplier;
        uint256 slope;
    }

    struct LinearPlateauCurveParams {
        uint256 minMultiplier;
        uint256 plateauLevel;
        uint256 slope;
    }

    struct PolynomialPlateauCurveParams {
        int256[] coeffs;
        uint256 plateauLevel;
    }

    bytes32 constant OPERATOR = keccak256("OPERATOR");
    bytes32 constant EMISSION_RATE = keccak256("EMISSION_RATE");
    bytes32 constant GUARDIAN = keccak256("GUARDIAN");

    string config;
    address multisig;
    address operator;
    address emissionRateRole;
    address guardianRole;
    address bootstrapAdd;
    Reliquary reliquary;
    uint256 poolCount;
    address rewardToken;
    mapping(uint256 => ParentRollingRewarder) parentForPoolId;
    LinearCurve[] linearCurves;
    LinearPlateauCurve[] linearPlateauCurves;
    PolynomialPlateauCurve[] polynomialPlateauCurves;
    address depositHelper4626;

    // Tracked addresses for JSON output
    address reliquaryImplAddr;
    address cooldownWithdrawalAddr;
    address[] nftDescriptorAddrs;
    address[] parentRewarderAddrs;
    address[] childRewarderAddrs;

    function run() external {
        config = vm.readFile("scripts/deploy_conf.json");
        string memory name = config.readString(".name");
        string memory symbol = config.readString(".symbol");
        multisig = config.readAddress(".multisigRole");
        operator = config.readAddress(".operatorRole");
        emissionRateRole = config.readAddress(".emissionRateRole");
        bootstrapAdd = config.readAddress(".multisigRole"); //! bootstrapAdd set to multisig.
        rewardToken = config.readAddress(".rewardToken");
        guardianRole = config.readAddress(".guardianRole");
        uint256 emissionRate = config.readUint(".emissionRate");
        uint256 minStakingAmount = config.readUint(".minStakingAmount");
        uint256 cooldownPeriod = config.readUint(".cooldownPeriod");
        Pool[] memory pools = abi.decode(config.parseRaw(".pools"), (Pool[]));
        poolCount = pools.length;

        vm.startBroadcast();

        _deployCurves();

        Reliquary reliquaryImpl = new Reliquary();
        reliquaryImplAddr = address(reliquaryImpl);
        console2.log("1.Reliquary(impl): ", address(reliquaryImpl));
        bytes memory data = abi.encodeWithSelector(
            Reliquary.initialize.selector,
            address(rewardToken), // _rewardToken
            emissionRate, // _emissionRate
            name, // _name
            symbol, // _symbol
            0, // stubbed to 0 and later updated with non zero value if needed
            address(0) // _cooldownWithdrawal
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(reliquaryImpl), data);
        reliquary = Reliquary(address(proxy));
        console2.log("1.Reliquary(proxy): ", address(reliquary));

        _deployRewarders();

        reliquary.grantRole(OPERATOR, tx.origin);
        for (uint256 i = 0; i < pools.length; ++i) {
            Pool memory pool = pools[i];

            ICurves curve;
            bytes32 curveTypeHash = keccak256(bytes(pool.curveType));
            if (curveTypeHash == keccak256("linearCurve")) {
                curve = linearCurves[pool.curveIndex];
            } else if (curveTypeHash == keccak256("linearPlateauCurve")) {
                curve = linearPlateauCurves[pool.curveIndex];
            } else if (curveTypeHash == keccak256("polynomialPlateauCurve")) {
                curve = polynomialPlateauCurves[pool.curveIndex];
            } else {
                revert(string.concat("invalid curve type ", pool.curveType));
            }

            _deployHelpers(pool.tokenType);
            address nftDescriptor = address(new NFTDescriptor(address(reliquary)));
            nftDescriptorAddrs.push(nftDescriptor);

            ERC20(pool.poolToken).approve(address(reliquary), 1); // approve 1 wei to bootstrap the pool
            reliquary.addPool(
                pool.allocPoint,
                pool.poolToken,
                address(parentForPoolId[i]),
                curve,
                pool.name,
                nftDescriptor,
                pool.allowPartialWithdrawals,
                bootstrapAdd
            );
        }

        _createChildRewarders();

        if (minStakingAmount > 0) {
            reliquary.setMinStakingAmount(minStakingAmount);
        }

        if (cooldownPeriod > 0) {
            CooldownWithdrawal cooldownWithdrawal =
                new CooldownWithdrawal(uint64(cooldownPeriod), address(reliquary));
            cooldownWithdrawalAddr = address(cooldownWithdrawal);
            console2.log("3.Cooldown ", address(cooldownWithdrawal));
            reliquary.setCooldownWithdrawal(address(cooldownWithdrawal));
            cooldownWithdrawal.transferOwnership(multisig);
        }

        // if (multisig != address(0)) {
        //     _renounceRoles();
        // }

        vm.stopBroadcast();

        _writeDeployment();

        // _asserts();
    }

    function _deployRewarders() internal {
        ParentRewarderParams[] memory parentParams =
            abi.decode(config.parseRaw(".parentRewarders"), (ParentRewarderParams[]));
        ParentRollingRewarder[] memory parentRewarders =
            new ParentRollingRewarder[](parentParams.length);
        console2.log("2.Rewarders deployment");
        for (uint256 i; i < parentParams.length; ++i) {
            ParentRewarderParams memory params = parentParams[i];

            ParentRollingRewarder newParent = new ParentRollingRewarder();
            console2.log("- ", address(newParent));
            parentRewarders[i] = newParent;
            parentRewarderAddrs.push(address(newParent));
            parentForPoolId[params.poolId] = newParent;
        }
    }

    function _createChildRewarders() internal {
        Pool[] memory pools = abi.decode(config.parseRaw(".pools"), (Pool[]));
        poolCount = pools.length;

        ChildRewarderParams[] memory children =
            abi.decode(config.parseRaw(".childRewarders"), (ChildRewarderParams[]));

        for (uint256 i; i < poolCount; ++i) {
            ParentRollingRewarder parent = ParentRollingRewarder(parentForPoolId[i]);
            address child = parent.createChild(children[i].rewarderToken);
            childRewarderAddrs.push(child);
        }
    }

    function _deployCurves() internal {
        LinearCurveParams[] memory linearCurveParams =
            abi.decode(config.parseRaw(".linearCurves"), (LinearCurveParams[]));
        console2.log("Curves: ");
        for (uint256 i; i < linearCurveParams.length; ++i) {
            LinearCurveParams memory params = linearCurveParams[i];
            linearCurves.push(new LinearCurve(params.slope, params.minMultiplier));
            console2.log("- ", address(linearCurves[linearCurves.length - 1]));
        }

        LinearPlateauCurveParams[] memory linearPlateauCurveParams =
            abi.decode(config.parseRaw(".linearPlateauCurves"), (LinearPlateauCurveParams[]));
        for (uint256 i; i < linearPlateauCurveParams.length; ++i) {
            LinearPlateauCurveParams memory params = linearPlateauCurveParams[i];
            linearPlateauCurves.push(
                new LinearPlateauCurve(params.slope, params.minMultiplier, params.plateauLevel)
            );
            console2.log("- ", address(linearPlateauCurves[linearPlateauCurves.length - 1]));
        }

        PolynomialPlateauCurveParams[] memory polynomialPlateauCurveParams = abi.decode(
            config.parseRaw(".polynomialPlateauCurves"), (PolynomialPlateauCurveParams[])
        );
        for (uint256 i; i < polynomialPlateauCurveParams.length; ++i) {
            PolynomialPlateauCurveParams memory params = polynomialPlateauCurveParams[i];
            polynomialPlateauCurves.push(
                new PolynomialPlateauCurve(params.coeffs, params.plateauLevel)
            );
            console2.log("- ", address(polynomialPlateauCurves[polynomialPlateauCurves.length - 1]));
        }
    }

    function _deployHelpers(string memory poolTokenType) internal {
        bytes32 typeHash = keccak256(bytes(poolTokenType));
        if (typeHash == keccak256("4626")) {
            if (depositHelper4626 == address(0)) {
                depositHelper4626 =
                    address(new DepositHelperERC4626(reliquary, config.readAddress(".weth")));
            }
        } else if (typeHash != keccak256("normal") && typeHash != keccak256("pair")) {
            revert(string.concat("invalid token type ", poolTokenType));
        }
    }

    function _renounceRoles() internal {
        bytes32 defaultAdminRole = reliquary.DEFAULT_ADMIN_ROLE();

        reliquary.grantRole(defaultAdminRole, multisig);
        reliquary.grantRole(OPERATOR, multisig);
        reliquary.grantRole(OPERATOR, operator);
        reliquary.grantRole(EMISSION_RATE, multisig);
        reliquary.grantRole(EMISSION_RATE, emissionRateRole);
        reliquary.grantRole(GUARDIAN, guardianRole);

        reliquary.renounceRole(OPERATOR, tx.origin);
        reliquary.renounceRole(EMISSION_RATE, tx.origin);
        reliquary.renounceRole(GUARDIAN, tx.origin);
        reliquary.renounceRole(defaultAdminRole, tx.origin);

        if (multisig != address(0)) {
            for (uint256 i; i < poolCount; ++i) {
                if (address(parentForPoolId[i]) != address(0)) {
                    parentForPoolId[i].transferOwnership(multisig);
                }
            }
        }
    }

    function _writeDeployment() internal {
        string memory obj = "deployment";

        vm.serializeAddress(obj, "reliquaryImpl", reliquaryImplAddr);
        vm.serializeAddress(obj, "reliquaryProxy", address(reliquary));
        vm.serializeAddress(obj, "cooldownWithdrawal", cooldownWithdrawalAddr);
        vm.serializeAddress(obj, "depositHelper4626", depositHelper4626);

        // Curves
        address[] memory lc = new address[](linearCurves.length);
        for (uint256 i; i < linearCurves.length; i++) {
            lc[i] = address(linearCurves[i]);
        }
        vm.serializeAddress(obj, "linearCurves", lc);

        address[] memory lpc = new address[](linearPlateauCurves.length);
        for (uint256 i; i < linearPlateauCurves.length; i++) {
            lpc[i] = address(linearPlateauCurves[i]);
        }
        vm.serializeAddress(obj, "linearPlateauCurves", lpc);

        address[] memory ppc = new address[](polynomialPlateauCurves.length);
        for (uint256 i; i < polynomialPlateauCurves.length; i++) {
            ppc[i] = address(polynomialPlateauCurves[i]);
        }
        vm.serializeAddress(obj, "polynomialPlateauCurves", ppc);

        // Rewarders
        vm.serializeAddress(obj, "parentRewarders", parentRewarderAddrs);
        vm.serializeAddress(obj, "childRewarders", childRewarderAddrs);

        // NFT descriptors — last call captures the full JSON
        string memory finalJson = vm.serializeAddress(obj, "nftDescriptors", nftDescriptorAddrs);

        string memory outputPath =
            string.concat("deployments/", vm.toString(block.chainid), "_deployment.json");
        vm.writeJson(finalJson, outputPath);
        console2.log("Deployment written to:", outputPath);
    }

    function _asserts() internal view {
        assert(reliquary.hasRole(OPERATOR, multisig));
        assert(reliquary.hasRole(EMISSION_RATE, multisig));
        assert(reliquary.hasRole(reliquary.DEFAULT_ADMIN_ROLE(), multisig));
        assert(reliquary.hasRole(OPERATOR, operator));
        assert(reliquary.hasRole(EMISSION_RATE, emissionRateRole));

        assert(!reliquary.hasRole(OPERATOR, tx.origin));
        assert(!reliquary.hasRole(EMISSION_RATE, tx.origin));
        assert(!reliquary.hasRole(reliquary.DEFAULT_ADMIN_ROLE(), tx.origin));
        assert(!reliquary.hasRole(GUARDIAN, tx.origin));

        assert(!reliquary.hasRole(OPERATOR, msg.sender));
        assert(!reliquary.hasRole(EMISSION_RATE, msg.sender));
        assert(!reliquary.hasRole(reliquary.DEFAULT_ADMIN_ROLE(), msg.sender));
        assert(!reliquary.hasRole(GUARDIAN, msg.sender));

        assert(reliquary.rewardToken() == rewardToken);
        assert(reliquary.emissionRate() == config.readUint(".emissionRate"));

        Pool[] memory poolInfos = abi.decode(config.parseRaw(".pools"), (Pool[]));
        for (uint256 i; i < poolInfos.length; ++i) {
            PoolInfo memory reliquaryPoolInfos = reliquary.getPoolInfo(uint8(i));
            Pool memory poolInfo = poolInfos[i];
            assert(
                keccak256(abi.encodePacked(reliquaryPoolInfos.name))
                    == keccak256(abi.encodePacked(poolInfo.name))
            );
            assert(reliquaryPoolInfos.rewarder == address(parentForPoolId[i]));
            assert(reliquaryPoolInfos.poolToken == poolInfo.poolToken);
            assert(reliquaryPoolInfos.allowPartialWithdrawals == poolInfo.allowPartialWithdrawals);
            assert(reliquaryPoolInfos.allocPoint == poolInfo.allocPoint);
        }
    }
}
