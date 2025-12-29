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
        uint256 lockEndTime = config.readUint(".lockEndTime");
        uint256 minStakingAmount = config.readUint(".minStakingAmount");
        Pool[] memory pools = abi.decode(config.parseRaw(".pools"), (Pool[]));
        poolCount = pools.length;

        vm.startBroadcast();

        _deployCurves();

        reliquary = new Reliquary(
            rewardToken, emissionRate, name, symbol, uint40(lockEndTime), minStakingAmount
        );

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
            } else {
                revert(string.concat("invalid curve type ", pool.curveType));
            }

            _deployHelpers(pool.tokenType);
            address nftDescriptor = address(new NFTDescriptor(address(reliquary)));

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

        if (multisig != address(0)) {
            _renounceRoles();
        }

        vm.stopBroadcast();

        _asserts();
    }

    function _deployRewarders() internal {
        ParentRewarderParams[] memory parentParams =
            abi.decode(config.parseRaw(".parentRewarders"), (ParentRewarderParams[]));
        ParentRollingRewarder[] memory parentRewarders =
            new ParentRollingRewarder[](parentParams.length);
        for (uint256 i; i < parentParams.length; ++i) {
            ParentRewarderParams memory params = parentParams[i];

            ParentRollingRewarder newParent = new ParentRollingRewarder();

            parentRewarders[i] = newParent;
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
            parent.createChild(children[i].rewarderToken);
        }
    }

    function _deployCurves() internal {
        LinearCurveParams[] memory linearCurveParams =
            abi.decode(config.parseRaw(".linearCurves"), (LinearCurveParams[]));
        for (uint256 i; i < linearCurveParams.length; ++i) {
            LinearCurveParams memory params = linearCurveParams[i];
            linearCurves.push(new LinearCurve(params.slope, params.minMultiplier));
        }

        LinearPlateauCurveParams[] memory linearPlateauCurveParams =
            abi.decode(config.parseRaw(".linearPlateauCurves"), (LinearPlateauCurveParams[]));
        for (uint256 i; i < linearPlateauCurveParams.length; ++i) {
            LinearPlateauCurveParams memory params = linearPlateauCurveParams[i];
            linearPlateauCurves.push(
                new LinearPlateauCurve(params.slope, params.minMultiplier, params.plateauLevel)
            );
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
