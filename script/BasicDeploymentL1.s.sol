pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {ERC20Mintable} from "src/ReceiptToken.sol";
import {ProgrammableDataTokenTransfers} from "src/ProgrammableDataTokenTransfers.sol";
import {ExchangeRateProvider} from "src/ExchangeRateProvider.sol";


contract BasicDeploymentL1 is Script {
    
    address router = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    address link = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    address token = 0x466D489b6d36E7E3b824ef491C225F5830E81cC1;
    uint64 l2ChainSelector=3478487238524512106;

    function run() external {
        require(token != address(0));
        string memory mainnetL1RPC = vm.envString("RPC_MAINNET_SEPOLIA");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
      
        uint l1Fork = vm.createSelectFork(mainnetL1RPC);
        vm.startBroadcast(deployerPrivateKey);
        ExchangeRateProvider erp = new ExchangeRateProvider(); 
        erp.setUpdater(erp.owner(), true);
        erp.setExchangeRate(1 ether);
        erp.setLastUpdate(block.timestamp);
        ProgrammableDataTokenTransfers bridge = new ProgrammableDataTokenTransfers(router, token, link, address(erp), true);
        erp.setUpdater(address(bridge), true);
        bridge.allowlistDestinationChain(l2ChainSelector, true);

    }
}
