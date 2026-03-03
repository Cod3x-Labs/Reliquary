// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "contracts/ReliquaryUIDataProvider.sol";

contract DeployReliquaryUIDataProvider is Script {
    using stdJson for string;

    function run() external {
        string memory deploymentPath =
            string.concat("deployments/", vm.toString(block.chainid), "_deployment.json");
        string memory deployment = vm.readFile(deploymentPath);
        address reliquaryProxy = deployment.readAddress(".reliquaryProxy");
        console.log("Read reliquaryProxy from deployment:", reliquaryProxy);

        vm.startBroadcast();

        ReliquaryUIDataProvider dataProvider = new ReliquaryUIDataProvider(reliquaryProxy);

        vm.stopBroadcast();

        console.log("ReliquaryUIDataProvider deployed at:", address(dataProvider));

        string memory dataDeploymentPath =
            string.concat("deployments/", vm.toString(block.chainid), "_dataDeployment.json");
        // Write the data provider address back to the deployment JSON
        vm.writeJson(
            vm.serializeAddress("update", "dataProvider", address(dataProvider)), dataDeploymentPath
        );
        console.log("Updated deployment JSON with dataProvider address");
    }
}
