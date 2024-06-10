pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {ERC20Mintable} from "src/ReceiptToken.sol";
import {ProgrammableDataTokenTransfers, IERC20} from "src/ProgrammableDataTokenTransfers.sol";
import {ExchangeRateProvider} from "src/ExchangeRateProvider.sol";

interface IDripable is IERC20{
    function drip(address to) external;
}

contract BasicL1ToL2Transaction is Script {
    
    address owner=0x11EC78492D53c9276dD7a184B1dbfB34E50B710D;
    address link = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
    IDripable token = IDripable(0x466D489b6d36E7E3b824ef491C225F5830E81cC1);
    ProgrammableDataTokenTransfers tokenBridge = ProgrammableDataTokenTransfers(payable(0x4b09061CA23a820fb629041008EE99b4180918f5));
    ExchangeRateProvider erp = ExchangeRateProvider(0xD307697c8ABa2Ac5255ED7f6077d6581F18bddDC);
    uint64 l2ChainSelector=3478487238524512106;
    address l2Bridge=0x3474ad0e3a9775c9F68B415A7a9880B0CAB9397a;

    function run() external {
        require(address(tokenBridge) != address(0));
        require(l2Bridge != address(0));
        string memory testnetL2RPC = vm.envString("RPC_MAINNET_SEPOLIA");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
      
        uint l2Fork = vm.createSelectFork(testnetL2RPC);
        vm.startBroadcast(deployerPrivateKey);

        payable(tokenBridge).transfer(0.1 ether);
        token.drip(address(tokenBridge));
        erp.setExchangeRate(3 ether);
        tokenBridge.sendMessagePayNative(l2ChainSelector, l2Bridge, owner, 0.09 ether);

    }
}
