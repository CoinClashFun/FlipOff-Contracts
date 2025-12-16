// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/FlipOff.sol";

contract DeployScript is Script {
    // Pyth Entropy on Monad Mainnet
    address constant ENTROPY_ADDRESS = 0xD458261E832415CFd3BAE5E416FdF3230ce6F134;

    function run() external {
        // Load private key from environment
        uint256 deployerPrivateKey = vm.envUint("MAINNET_PRIVATE_KEY");
        address treasury = vm.envAddress("MAINNET_TREASURY_ADDRESS");

        console.log("Deploying FlipOff to Monad Mainnet...");
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("Treasury:", treasury);
        console.log("Entropy:", ENTROPY_ADDRESS);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy FlipOff
        FlipOff flipOff = new FlipOff(ENTROPY_ADDRESS, treasury);

        console.log("FlipOff deployed at:", address(flipOff));

        vm.stopBroadcast();

        // Log deployment info
        console.log("\n=== Deployment Complete ===");
        console.log("FlipOff:", address(flipOff));
        console.log("Min Bet:", flipOff.MIN_BET());
        console.log("House Fee BPS:", flipOff.feeBps());
    }
}
