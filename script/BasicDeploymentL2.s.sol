pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {ERC20Mintable} from "src/ReceiptToken.sol";
import {ProgrammableDataTokenTransfers} from "src/ProgrammableDataTokenTransfers.sol";
import {ExchangeRateProvider} from "src/ExchangeRateProvider.sol";


contract BasicDeploymentL2 is Script {
    
    address owner=0x11EC78492D53c9276dD7a184B1dbfB34E50B710D;
    address router=0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;
    address link=0x143E1dAE4F018ff86051a01D44a1B49B13704056;
    address l1Sender=0x15E4613fF3f0818B25EE8647AB5B0679945e714e;
    address token=0xA8C0c11bf64AF62CDCA6f93D3769B88BdD7cb93D;
    uint64 l1ChainSelector=16015286601757825753;


    function run() external {
        require(l1Sender != address(0));
        require(token != address(0));
        string memory testnetL2RPC = vm.envString("RPC_ARBITRUM_SEPOLIA");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
      
        uint l2Fork = vm.createSelectFork(testnetL2RPC);
        vm.startBroadcast(deployerPrivateKey);
        ExchangeRateProvider erp = new ExchangeRateProvider(); 

        ProgrammableDataTokenTransfers bridge = new ProgrammableDataTokenTransfers(router, token, link, address(erp), false);
        erp.setUpdater(address(bridge), true);
        bridge.allowlistSourceChain(l1ChainSelector, true);
        bridge.allowlistSender(l1Sender, true);
    }
}
