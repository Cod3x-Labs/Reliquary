// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "contracts/Reliquary.sol";
import "contracts/interfaces/IReliquary.sol";
import "./mocks/ERC20Mock.sol";
import "contracts/nft_descriptors/NFTDescriptor.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "contracts/interfaces/ICurves.sol";
import "contracts/curves/LinearCurve.sol";
import "contracts/curves/LinearPlateauCurve.sol";
import "contracts/curves/PolynomialPlateauCurve.sol";

// The only unfuzzed method is reliquary.setEmissionRate()
contract User {
    function proxy(address target, bytes memory data)
        public
        returns (bool success, bytes memory err)
    {
        return target.call(data);
    }

    function approveERC20(ERC20 target, address spender) public {
        target.approve(spender, type(uint256).max);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }
}

struct DepositData {
    uint256 relicId;
    uint256 amount;
    bool isInit;
}

contract ReliquaryProperties {
    // Linear function config (to config)
    uint256 public slope = 1; // Increase of multiplier every second
    uint256 public minMultiplier = 365 days * 100; // Arbitrary (but should be coherent with slope)
    uint256 public plateauLinear = 10 days;
    uint256 public plateauPoly = 850;
    int256[] public coeff =
        [int256(100e18), int256(1e18), int256(5e15), int256(-1e13), int256(5e9)];

    uint256 public emissionRate = 1e18;
    uint256 public initialMint = 100 ether;
    uint256 public immutable startTimestamp;

    uint8 public totalNbPools;
    uint256 public totalNbUsers;
    mapping(uint256 => bool) public isInit;

    uint256[] public relicIds;
    uint8[] public poolIds;
    User[] public users;
    ICurves[] public curves;
    ERC20Mock[] public tokenPoolIds;
    uint256 public rewardLostByEmergencyWithdraw;

    ERC20Mock public rewardToken;
    Reliquary public reliquary;
    NFTDescriptor public nftDescriptor;
    LinearCurve linearCurve;
    LinearPlateauCurve linearPlateauCurve;
    PolynomialPlateauCurve polynomialPlateauCurve;

    event LogUint(uint256 a);

    constructor() payable {
        // config -----------
        totalNbUsers = 10; // fix
        totalNbPools = 2; // the fuzzer can add new pools
        // ------------------

        startTimestamp = block.timestamp;
        /// setup reliquary
        rewardToken = new ERC20Mock("OATH Token", "OATH");
        reliquary = new Reliquary(address(rewardToken), emissionRate, "Relic", "NFT");
        nftDescriptor = new NFTDescriptor(address(reliquary));

        int256[] memory coeffDynamic = new int256[](5);
        for (uint256 i = 0; i < 5; i++) {
            coeffDynamic[i] = coeff[i];
        }
        linearCurve = new LinearCurve(slope, minMultiplier);
        linearPlateauCurve = new LinearPlateauCurve(slope, minMultiplier, plateauLinear);
        polynomialPlateauCurve = new PolynomialPlateauCurve(coeffDynamic, plateauPoly);

        curves.push(linearCurve);
        curves.push(linearPlateauCurve);
        curves.push(polynomialPlateauCurve);

        rewardToken.mint(address(reliquary), 100 ether); // provide rewards to reliquary contract

        /// setup token pool
        for (uint8 i = 0; i < totalNbPools; i++) {
            ERC20Mock token = new ERC20Mock("Pool Token", "PT");
            tokenPoolIds.push(token);

            token.mint(address(this), 1);
            token.approve(address(reliquary), 1); // approve 1 wei to bootstrap the pool

            // no rewarder for now
            reliquary.addPool(
                100,
                address(token),
                address(0),
                polynomialPlateauCurve,
                "reaper",
                address(nftDescriptor),
                true,
                address(this)
            );
            poolIds.push(i);
        }

        /// setup users
        // admin is this contract
        reliquary.grantRole(keccak256("DEFAULT_ADMIN_ROLE"), address(this));
        reliquary.grantRole(keccak256("OPERATOR"), address(this));
        reliquary.grantRole(keccak256("EMISSION_RATE"), address(this));

        for (uint256 i = 0; i < totalNbUsers; i++) {
            User user = new User();
            users.push(user);
            for (uint8 j = 0; j < tokenPoolIds.length; j++) {
                tokenPoolIds[j].mint(address(user), initialMint);
                user.approveERC20(tokenPoolIds[j], address(reliquary));
            }
        }
    }

    // --------------------- state updates ---------------------

    /// random add pool
    function randAddPools(
        uint256 allocPoint,
        uint256 randSpacingMul,
        uint256 randSizeMul,
        uint256 randSpacingMat,
        uint256 randSizeMat,
        uint256 randCurves
    ) public {
        uint256 maxSize = 10;
        require(allocPoint > 0);
        uint8 startPoolIdsLen = uint8(poolIds.length);
        ERC20Mock token = new ERC20Mock("Pool Token", "PT");
        tokenPoolIds.push(token);
        ICurves curve = curves[randCurves % curves.length];

        token.mint(address(this), 1);
        token.approve(address(reliquary), 1); // approve 1 wei to bootstrap the pool

        // no rewarder for now
        reliquary.addPool(
            allocPoint % 10000 ether, // to avoid overflow on totalAllocPoint [0, 10000e18]
            address(token),
            address(0),
            curve,
            "reaper",
            address(nftDescriptor),
            true,
            address(this)
        );
        poolIds.push(startPoolIdsLen);
        totalNbPools++;

        // mint new token and setup allowance for users
        for (uint256 i = 0; i < totalNbUsers; i++) {
            User user = users[i];
            for (uint8 j = startPoolIdsLen; j < tokenPoolIds.length; j++) {
                tokenPoolIds[j].mint(address(user), initialMint);
                user.approveERC20(tokenPoolIds[j], address(reliquary));
            }
        }
    }

    /// random modify pool
    function randModifyPools(uint8 randPoolId, uint256 allocPoint) public {
        reliquary.modifyPool(
            randPoolId % totalNbPools,
            allocPoint % 10000 ether, // to avoid overflow on totalAllocPoint [0, 10000e18]
            address(0),
            "reaper",
            address(nftDescriptor),
            true
        );
    }

    /// random user create relic and deposit
    function randCreateRelicAndDeposit(uint256 randUser, uint8 randPool, uint256 randAmt) public {
        User user = users[randUser % users.length];
        uint256 amount = (randAmt % initialMint) / 100 + 1; // with seqLen: 100 we should not have supply issues
        uint8 poolId = randPool % totalNbPools;
        ERC20 poolToken = ERC20(reliquary.getPoolInfo(poolId).poolToken);
        uint256 balanceReliquaryBefore = poolToken.balanceOf(address(reliquary));
        uint256 balanceUserBefore = poolToken.balanceOf(address(user));

        // if the user already has a relic, use deposit()
        (bool success, bytes memory data) = user.proxy(
            address(reliquary),
            abi.encodeWithSelector(
                reliquary.createRelicAndDeposit.selector, address(user), poolId, amount
            )
        );
        assert(success);
        uint256 relicId = abi.decode(data, (uint256));
        isInit[relicId] = true;
        relicIds.push(relicId);

        // reliquary balance must have increased by amount
        assert(poolToken.balanceOf(address(reliquary)) == balanceReliquaryBefore + amount);
        // user balance must have decreased by amount
        assert(poolToken.balanceOf(address(user)) == balanceUserBefore - amount);
    }

    /// random user deposit
    function randDeposit(uint256 randRelic, uint256 randAmt) public {
        uint256 relicId = relicIds[randRelic % relicIds.length];
        User user = User(reliquary.ownerOf(relicId));
        uint256 amount = (randAmt % initialMint) / 100 + 1; // with seqLen: 100 we should not have supply issues
        ERC20 poolToken =
            ERC20(reliquary.getPoolInfo(reliquary.getPositionForId(relicId).poolId).poolToken);
        uint256 balanceReliquaryBefore = poolToken.balanceOf(address(reliquary));
        uint256 balanceUserBefore = poolToken.balanceOf(address(user));

        // if the user already has a relic, use deposit()
        if (isInit[relicId]) {
            (bool success,) = user.proxy(
                address(reliquary),
                abi.encodeWithSelector(reliquary.deposit.selector, amount, relicId, address(0))
            );
            assert(success);
        }

        // reliquary balance must have increased by amount
        assert(poolToken.balanceOf(address(reliquary)) == balanceReliquaryBefore + amount);
        // user balance must have decreased by amount
        assert(poolToken.balanceOf(address(user)) == balanceUserBefore - amount);
    }

    /// random user deposit + harvest
    function randDepositAndHarvest(uint256 randRelic, uint256 randAmt) public {
        uint256 relicId = relicIds[randRelic % relicIds.length];
        User user = User(reliquary.ownerOf(relicId));
        uint256 amount = (randAmt % initialMint) / 100 + 1; // with seqLen: 100 we should not have supply issues
        ERC20 poolToken =
            ERC20(reliquary.getPoolInfo(reliquary.getPositionForId(relicId).poolId).poolToken);
        uint256 balanceReliquaryBefore = poolToken.balanceOf(address(reliquary));
        uint256 balanceUserBefore = poolToken.balanceOf(address(user));

        // if the user already has a relic, use deposit()
        if (isInit[relicId]) {
            (bool success,) = user.proxy(
                address(reliquary),
                abi.encodeWithSelector(reliquary.deposit.selector, amount, relicId, address(user))
            );
            assert(success);
        }

        // reliquary balance must have increased by amount
        assert(poolToken.balanceOf(address(reliquary)) == balanceReliquaryBefore + amount);
        // user balance must have decreased by amount
        assert(poolToken.balanceOf(address(user)) == balanceUserBefore - amount);
    }

    /// random withdraw
    function randWithdraw(uint256 randRelic, uint256 randAmt) public {
        uint256 relicId = relicIds[randRelic % relicIds.length];
        User user = User(reliquary.ownerOf(relicId));
        uint256 amount = reliquary.getPositionForId(relicId).amount;

        if (amount > 0) {
            uint256 amountToWithdraw = randAmt % (amount + 1);
            require(amountToWithdraw > 0);

            uint8 poolId = reliquary.getPositionForId(relicId).poolId;
            ERC20 poolToken = ERC20(reliquary.getPoolInfo(poolId).poolToken);

            uint256 balanceReliquaryBefore = poolToken.balanceOf(address(reliquary));
            uint256 balanceUserBefore = poolToken.balanceOf(address(user));

            // if the user already have a relic use deposit()
            (bool success,) = user.proxy(
                address(reliquary),
                abi.encodeWithSelector(
                    reliquary.withdraw.selector,
                    amountToWithdraw, // withdraw more than amount deposited ]0, amount]
                    relicId,
                    address(0)
                )
            );
            assert(success);

            // reliquary balance must have decreased by amountToWithdraw
            assert(
                poolToken.balanceOf(address(reliquary)) == balanceReliquaryBefore - amountToWithdraw
            );
            // user balance must have increased by amountToWithdraw
            assert(poolToken.balanceOf(address(user)) == balanceUserBefore + amountToWithdraw);
        }
    }

    /// random withdraw + harvest
    function randWithdrawAndHarvest(uint256 randRelic, uint256 randAmt) public {
        uint256 relicId = relicIds[randRelic % relicIds.length];
        User user = User(reliquary.ownerOf(relicId));
        uint256 amount = reliquary.getPositionForId(relicId).amount;

        if (amount > 0) {
            uint256 amountToWithdraw = randAmt % (amount + 1);

            uint8 poolId = reliquary.getPositionForId(relicId).poolId;
            ERC20 poolToken = ERC20(reliquary.getPoolInfo(poolId).poolToken);

            uint256 balanceReliquaryBefore = poolToken.balanceOf(address(reliquary));
            uint256 balanceUserBefore = poolToken.balanceOf(address(user));

            // if the user already have a relic use deposit()
            (bool success,) = user.proxy(
                address(reliquary),
                abi.encodeWithSelector(
                    reliquary.withdraw.selector,
                    amountToWithdraw, // withdraw more than amount deposited ]0, amount]
                    relicId,
                    address(user)
                )
            );
            require(success);

            // reliquary balance must have decreased by amountToWithdraw
            assert(
                poolToken.balanceOf(address(reliquary)) == balanceReliquaryBefore - amountToWithdraw
            );
            // user balance must have increased by amountToWithdraw
            assert(poolToken.balanceOf(address(user)) == balanceUserBefore + amountToWithdraw);
        }
    }

    /// random emergency withdraw
    function randEmergencyWithdraw(uint256 rand) public {
        uint256 relicId = relicIds[rand % relicIds.length];

        PositionInfo memory pi = reliquary.getPositionForId(relicId);
        address owner = reliquary.ownerOf(relicId);
        ERC20 poolToken = ERC20(reliquary.getPoolInfo(pi.poolId).poolToken);
        uint256 amount = pi.amount;

        uint256 balanceReliquaryBefore = poolToken.balanceOf(address(reliquary));
        uint256 balanceOwnerBefore = poolToken.balanceOf(owner);

        rewardLostByEmergencyWithdraw += reliquary.pendingReward(relicId);

        (bool success,) = User(owner)
            .proxy(
                address(reliquary),
                abi.encodeWithSelector(reliquary.emergencyWithdraw.selector, relicId)
            );
        require(success);

        isInit[relicId] = false;

        // reliquary balance must have decreased by amount
        assert(poolToken.balanceOf(address(reliquary)) == balanceReliquaryBefore - amount);
        // user balance must have increased by amount
        assert(poolToken.balanceOf(address(owner)) == balanceOwnerBefore + amount);
    }

    /// harvest a position randomly
    function randHarvestPosition(uint256 rand) public {
        uint256 idToHasvest = rand % relicIds.length;
        address owner = reliquary.ownerOf(idToHasvest);

        uint256 balanceReliquaryBefore = rewardToken.balanceOf(address(reliquary));
        uint256 balanceOwnerBefore = rewardToken.balanceOf(owner);
        uint256 amount = reliquary.pendingReward(idToHasvest);

        (bool success,) = User(owner)
            .proxy(
                address(reliquary),
                abi.encodeWithSelector(reliquary.update.selector, idToHasvest, owner)
            );
        require(success);

        // reliquary balance must have increased by amount
        assert(rewardToken.balanceOf(address(reliquary)) == balanceReliquaryBefore - amount);
        // user balance must have decreased by amount
        assert(rewardToken.balanceOf(address(owner)) == balanceOwnerBefore + amount);
    }

    /// random split
    function randSplit(uint256 randRelic, uint256 randAmt, uint256 randUserTo) public {
        uint256 relicIdFrom = relicIds[randRelic % relicIds.length];
        PositionInfo memory piFrom = reliquary.getPositionForId(relicIdFrom);
        uint256 amount = (randAmt % piFrom.amount);
        User owner = User(reliquary.ownerOf(relicIdFrom));
        User to = User(users[randUserTo % users.length]);

        uint256 amountFromBefore = piFrom.amount;

        (bool success, bytes memory data) = owner.proxy(
            address(reliquary),
            abi.encodeWithSelector(reliquary.split.selector, relicIdFrom, amount, address(to))
        );
        require(success);
        uint256 relicIdTo = abi.decode(data, (uint256));
        isInit[relicIdTo] = true;
        relicIds.push(relicIdTo);

        assert(reliquary.getPositionForId(relicIdFrom).amount == amountFromBefore - amount);
        assert(reliquary.getPositionForId(relicIdTo).amount == amount);
    }

    /// random shift
    function randShift(uint256 randRelicFrom, uint256 randRelicTo, uint256 randAmt) public {
        uint256 relicIdFrom = relicIds[randRelicFrom % relicIds.length];
        User user = User(reliquary.ownerOf(relicIdFrom)); // same user for from and to
        require(reliquary.balanceOf(address(user)) >= 2);
        uint256 relicIdTo = relicIds[randRelicTo % relicIds.length];
        require(reliquary.ownerOf(relicIdTo) == address(user));

        uint256 amountFromBefore = reliquary.getPositionForId(relicIdFrom).amount;
        uint256 amountToBefore = reliquary.getPositionForId(relicIdTo).amount;
        uint256 amount = (randAmt % amountFromBefore);

        (bool success,) = user.proxy(
            address(reliquary),
            abi.encodeWithSelector(reliquary.shift.selector, relicIdFrom, relicIdTo, amount)
        );
        require(success);

        assert(reliquary.getPositionForId(relicIdFrom).amount == amountFromBefore - amount);
        assert(reliquary.getPositionForId(relicIdTo).amount == amountToBefore + amount);
    }

    /// random merge
    function randMerge(uint256 randRelicFrom, uint256 randRelicTo) public {
        uint256 relicIdFrom = relicIds[randRelicFrom % relicIds.length];
        User user = User(reliquary.ownerOf(relicIdFrom)); // same user for from and to
        require(reliquary.balanceOf(address(user)) >= 2);
        uint256 relicIdTo = relicIds[randRelicTo % relicIds.length];
        // require(reliquary.ownerOf(relicIdTo) == address(user));

        uint256 amountFromBefore = reliquary.getPositionForId(relicIdFrom).amount;
        uint256 amountToBefore = reliquary.getPositionForId(relicIdTo).amount;
        uint256 amount = amountFromBefore;

        (bool success,) = user.proxy(
            address(reliquary),
            abi.encodeWithSelector(reliquary.merge.selector, relicIdFrom, relicIdTo)
        );
        require(success);

        isInit[relicIdFrom] = false;

        assert(reliquary.getPositionForId(relicIdFrom).amount == 0);
        assert(reliquary.getPositionForId(relicIdTo).amount == amountToBefore + amount);
    }

    /// update a position randomly
    function randUpdatePosition(uint256 rand) public {
        reliquary.update(rand % relicIds.length, address(0));
    }

    /// update a pool randomly
    function randUpdatePools(uint8 rand) public {
        reliquary.updatePool(rand % totalNbPools);
    }

    /// random burn
    function randBurn(uint256 rand) public {
        uint256 idToBurn = relicIds[rand % relicIds.length];

        try reliquary.burn(idToBurn) {
            assert(isInit[idToBurn]);
            isInit[idToBurn] = false;
        } catch {
            assert(true);
        }
    }

    // ---------------------- Invariants ----------------------

    /// @custom:invariant - A user should never be able to withdraw more than deposited.
    function tryTowithdrawMoreThanDeposit(uint256 randRelic, uint256 randAmt) public {
        uint256 relicId = relicIds[randRelic % relicIds.length];
        User user = User(reliquary.ownerOf(relicId));
        uint256 amount = reliquary.getPositionForId(relicId).amount;

        require(randAmt > amount);

        // if the user already have a relic use deposit()
        (bool success,) = user.proxy(
            address(reliquary),
            abi.encodeWithSelector(
                reliquary.withdraw.selector,
                randAmt, // withdraw more than amount deposited ]amount, uint256.max]
                relicId,
                address(0)
            )
        );
        assert(!success);
    }

    /// @custom:invariant - No `position.entry` should be greater than `block.timestamp`.
    /// @custom:invariant - The sum of all `position.amount` should never be greater than total deposit.
    function positionParamsIntegrity() public view {
        uint256[] memory totalAmtInPositions;
        PositionInfo memory pi;
        for (uint256 i; i < relicIds.length; i++) {
            pi = reliquary.getPositionForId(relicIds[i]);
            assert(pi.entry <= block.timestamp);
            totalAmtInPositions[pi.poolId] += pi.amount;
        }

        // this works if there are no pools with twice the same token
        for (uint8 pid; pid < totalNbPools; pid++) {
            uint256 totalBalance =
                ERC20(reliquary.getPoolInfo(pid).poolToken).balanceOf(address(reliquary));
            // check balances integrity
            assert(totalAmtInPositions[pid] == totalBalance);
        }
    }

    /// @custom:invariant - The sum of all `allocPoint` should be equal to `totalAllocpoint`.
    function poolallocPointIntegrity() public view {
        uint256 sum;
        for (uint8 i = 0; i < poolIds.length; i++) {
            sum += reliquary.getPoolInfo(i).allocPoint;
        }
        assert(sum == reliquary.totalAllocPoint());
    }

    /// @custom:invariant - The total reward harvested and pending should never be greater than the total emission rate.
    /// @custom:invariant - `emergencyWithdraw` should burn position rewards.
    function poolEmissionIntegrity() public {
        // require(block.timestamp > startTimestamp + 12);
        uint256 totalReward = rewardLostByEmergencyWithdraw;

        for (uint256 i = 0; i < totalNbUsers; i++) {
            // account for tokenReward harvested
            totalReward += rewardToken.balanceOf(address(users[i]));
        }

        for (uint256 i = 0; i < relicIds.length; i++) {
            uint256 relicId = relicIds[i];
            // account for tokenReward pending
            // check if position was burned
            if (isInit[relicId]) {
                totalReward += reliquary.pendingReward(relicId);
            }
        }

        // only works for constant emission rate
        uint256 maxEmission = (block.timestamp - startTimestamp) * reliquary.emissionRate();

        assert(totalReward <= maxEmission);
    }

    // ---------------------- Helpers ----------------------
}
