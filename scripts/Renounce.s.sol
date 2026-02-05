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

        reliquary = Reliquary(0x32E570927836251160C40361D5e7b3c38c4e7adf);

        parentForPoolId[0] = ParentRollingRewarder(0x14c20364Ec8379E6C09e0BC015378189475a9205);

        // vm.startBroadcast();

        // if (multisig != address(0)) {
        //     _renounceRoles();
        // }

        // vm.stopBroadcast();
        console2.log("ADMIN");
        console2.logBytes32(reliquary.DEFAULT_ADMIN_ROLE());
        console2.log("OPERATOR");
        console2.logBytes32(OPERATOR);
        console2.log("EMISSION_RATE");
        console2.logBytes32(EMISSION_RATE);
        console2.log("GUARDIAN");
        console2.logBytes32(GUARDIAN);

        _asserts();
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
