pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {GovernanceProxy} from "src/GovernanceProxy.sol";
import {ExchangeRateProvider} from "src/ExchangeRateProvider.sol";


contract GovProxyDeploymentL2 is Script {
    
    address owner=0x11EC78492D53c9276dD7a184B1dbfB34E50B710D;
    address router=0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;
    address l1Sender=0xaE5FCA988701EFa29161f539a1782675efE3BDa2;
    uint64 l1ChainSelector=16015286601757825753;


    function run() external {
        require(l1Sender != address(0));
        string memory testnetL2RPC = vm.envString("RPC_ARBITRUM_SEPOLIA");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
      
        uint l2Fork = vm.createSelectFork(testnetL2RPC);
        vm.startBroadcast(deployerPrivateKey);
        ExchangeRateProvider erp = new ExchangeRateProvider(); 

        GovernanceProxy proxy = new GovernanceProxy(router, l1Sender, l1ChainSelector);
        erp.setUpdater(address(proxy), true);
    }
}
