pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {GovernanceSender} from "src/GovernanceSender.sol";

contract GovDeploymentL1 is Script {
    
    address router = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;

    function run() external {
        string memory mainnetL1RPC = vm.envString("RPC_MAINNET_SEPOLIA");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
      
        uint l1Fork = vm.createSelectFork(mainnetL1RPC);
        vm.startBroadcast(deployerPrivateKey);
        GovernanceSender sender = new GovernanceSender(router);
        sender.allowlistCaller(sender.owner(), true);
    }
}
