// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TaskForge} from "../src/TaskForge.sol";

interface IERC20Meta {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/// @notice Deploys TaskForge to Arc Testnet. Reads PRIVATE_KEY and USDC_ADDRESS from the environment.
contract DeployTaskForge is Script {
    uint256 public constant ARC_TESTNET_CHAIN_ID = 5042002;

    function run() external returns (TaskForge deployed) {
        require(block.chainid == ARC_TESTNET_CHAIN_ID, "DeployTaskForge: not Arc Testnet (5042002)");

        address usdc = vm.envAddress("USDC_ADDRESS");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        require(usdc.code.length > 0, "DeployTaskForge: USDC_ADDRESS has no code");
        require(IERC20Meta(usdc).decimals() == 6, "DeployTaskForge: expected 6-decimal USDC");

        vm.startBroadcast(pk);
        deployed = new TaskForge(IERC20(usdc));
        vm.stopBroadcast();

        console.log("TaskForge deployed at:", address(deployed));
        console.log("USDC token:", usdc);
        console.log("Record these in deployments/arc-testnet.json after verifying on ArcScan.");
    }
}
