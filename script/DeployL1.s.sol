pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {ERC20Mintable} from "src/ReceiptToken.sol";
import {ProgrammableDataTokenTransfers} from "src/ProgrammableDataTokenTransfers.sol";
import {ExchangeRateProvider} from "src/ExchangeRateProvider.sol";


contract DeployL1 is Script {
    
    address router = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    address link = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address sinv = 0x08d23468A467d2bb86FaE0e32F247A26C7E2e994;
    address gov = 0x926dF14a23BE491164dCF93f4c468A50ef659D5B;
    uint64 arbChainSelector=4949039107694359620;
    uint64 baseChainSelector=15971525489660198786;
    uint64 opChainSelector=3734403246176062136;

    function run() external {
        require(sinv != address(0));
        string memory mainnetL1RPC = vm.envString("RPC_MAINNET");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
      
        uint l1Fork = vm.createSelectFork(mainnetL1RPC);
        vm.startBroadcast(deployerPrivateKey);
        ProgrammableDataTokenTransfers bridge = ProgrammableDataTokenTransfers(payable(0x041C3A97843B2B5ea59Fc02e4c20dd7bcd89f38A));//new ProgrammableDataTokenTransfers(router, sinv, link, sinv, true);
        /*
        bridge.allowlistDestinationChain(arbChainSelector, true);
        bridge.allowlistDestinationChain(baseChainSelector, true);
        bridge.allowlistDestinationChain(opChainSelector, true);
        bridge.allowlistSourceChain(arbChainSelector, true);
        bridge.allowlistSourceChain(baseChainSelector, true);
        */
        bridge.allowlistSourceChain(opChainSelector, true);
        bridge.transferOwnership(gov);
    }
}
