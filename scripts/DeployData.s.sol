// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "contracts/ReliquaryUIDataProvider.sol";

contract DeployReliquaryUIDataProvider is Script {
    address constant RELIQUARY_ADDRESS = 0x32E570927836251160C40361D5e7b3c38c4e7adf;

    function run() external {
        vm.startBroadcast();

        ReliquaryUIDataProvider dataProvider = new ReliquaryUIDataProvider(RELIQUARY_ADDRESS);

        vm.stopBroadcast();

        console.log("ReliquaryUIDataProvider deployed at:", address(dataProvider));
    }
}
