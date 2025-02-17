// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "contracts/ReliquaryUIDataProvider.sol";

contract DeployReliquaryUIDataProvider is Script {
    function run() external {
        vm.startBroadcast();

        ReliquaryUIDataProvider dataProvider = new ReliquaryUIDataProvider(0x1Cf49e880fc64C0B98BeE0Ecac89aA79D29335EA);

        vm.stopBroadcast();

        console.log("ReliquaryUIDataProvider deployed at:", address(dataProvider));
    }
}