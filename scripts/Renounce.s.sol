// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import {PoolInfo} from "contracts/interfaces/IReliquary.sol";
import {Reliquary} from "contracts/Reliquary.sol";
import {ParentRollingRewarder} from "contracts/rewarders/ParentRollingRewarder.sol";
import {CooldownWithdrawal} from "contracts/CooldownWithdrawal.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract Renounce is Script {
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

    bytes32 constant OPERATOR = keccak256("OPERATOR");
    bytes32 constant EMISSION_RATE = keccak256("EMISSION_RATE");
    bytes32 constant GUARDIAN = keccak256("GUARDIAN");

    string config;
    string deployment;
    address multisig;
    address operator;
    address emissionRateRole;
    address guardianRole;
    Reliquary reliquary;
    uint256 poolCount;
    address rewardToken;
    mapping(uint256 => ParentRollingRewarder) parentForPoolId;

    function run() external {
        config = vm.readFile("scripts/deploy_conf.json");

        // Read deployed addresses from deployment JSON
        string memory deploymentPath =
            string.concat("deployments/", vm.toString(block.chainid), "_deployment.json");
        deployment = vm.readFile(deploymentPath);

        reliquary = Reliquary(deployment.readAddress(".reliquaryProxy"));
        console2.log("Reliquary proxy:", address(reliquary));

        address[] memory parentRewarders =
            abi.decode(deployment.parseRaw(".parentRewarders"), (address[]));
        for (uint256 i; i < parentRewarders.length; ++i) {
            parentForPoolId[i] = ParentRollingRewarder(parentRewarders[i]);
            console2.log("ParentRewarder[%s]: %s", i, parentRewarders[i]);
        }

        multisig = config.readAddress(".multisigRole");
        operator = config.readAddress(".operatorRole");
        emissionRateRole = config.readAddress(".emissionRateRole");
        guardianRole = config.readAddress(".guardianRole");
        rewardToken = config.readAddress(".rewardToken");
        Pool[] memory pools = abi.decode(config.parseRaw(".pools"), (Pool[]));
        poolCount = pools.length;

        console2.log("ADMIN");
        console2.logBytes32(reliquary.DEFAULT_ADMIN_ROLE());
        console2.log("OPERATOR");
        console2.logBytes32(OPERATOR);
        console2.log("EMISSION_RATE");
        console2.logBytes32(EMISSION_RATE);
        console2.log("GUARDIAN");
        console2.logBytes32(GUARDIAN);

        vm.startBroadcast();

        _renounceRoles();

        vm.stopBroadcast();

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
        // --- Roles granted to the correct addresses ---
        assert(reliquary.hasRole(reliquary.DEFAULT_ADMIN_ROLE(), multisig));
        assert(reliquary.hasRole(OPERATOR, multisig));
        assert(reliquary.hasRole(OPERATOR, operator));
        assert(reliquary.hasRole(EMISSION_RATE, multisig));
        assert(reliquary.hasRole(EMISSION_RATE, emissionRateRole));
        assert(reliquary.hasRole(GUARDIAN, guardianRole));

        // --- Deployer roles fully renounced ---
        assert(!reliquary.hasRole(reliquary.DEFAULT_ADMIN_ROLE(), tx.origin));
        assert(!reliquary.hasRole(OPERATOR, tx.origin));
        assert(!reliquary.hasRole(EMISSION_RATE, tx.origin));
        assert(!reliquary.hasRole(GUARDIAN, tx.origin));

        assert(!reliquary.hasRole(reliquary.DEFAULT_ADMIN_ROLE(), msg.sender));
        assert(!reliquary.hasRole(OPERATOR, msg.sender));
        assert(!reliquary.hasRole(EMISSION_RATE, msg.sender));
        assert(!reliquary.hasRole(GUARDIAN, msg.sender));

        // --- Core config matches deploy_conf ---
        assert(reliquary.rewardToken() == rewardToken);
        assert(reliquary.emissionRate() == config.readUint(".emissionRate"));
        assert(reliquary.minStakingAmount() == config.readUint(".minStakingAmount"));

        // --- Pool count matches ---
        Pool[] memory poolInfos = abi.decode(config.parseRaw(".pools"), (Pool[]));
        assert(reliquary.poolLength() == poolInfos.length);

        // --- Per-pool assertions ---
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

        // --- CooldownWithdrawal ---
        address cooldownAddr = reliquary.cooldownWithdrawal();
        address deployedCooldown = deployment.readAddress(".cooldownWithdrawal");
        if (deployedCooldown != address(0)) {
            assert(cooldownAddr == deployedCooldown);
            assert(Ownable(cooldownAddr).owner() == multisig);
        }

        // --- ParentRewarder ownership transferred to multisig ---
        for (uint256 i; i < poolCount; ++i) {
            if (address(parentForPoolId[i]) != address(0)) {
                assert(parentForPoolId[i].owner() == multisig);
            }
        }
    }
}
