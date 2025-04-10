// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SwapUniswapV3} from "../src/swapModules/SwapUniswapV3.sol";

contract SwapUniswapV3Script is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Get addresses from environment variables
        address swapRouter = vm.envAddress("UNISWAP_V3_ROUTER");
        address wzeta = vm.envAddress("WZETA");

        // Deploy SwapUniswapV3
        SwapUniswapV3 swapUniswapV3 = new SwapUniswapV3(swapRouter, wzeta);
        console2.log("SwapUniswapV3 deployed to:", address(swapUniswapV3));
        console2.log("Uniswap V3 Router:", swapRouter);
        console2.log("WZETA:", wzeta);

        vm.stopBroadcast();
    }
}
