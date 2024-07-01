pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {ERC20Mintable} from "src/ReceiptToken.sol";
import {ProgrammableDataTokenTransfers, IERC20} from "src/ProgrammableDataTokenTransfers.sol";
import {ExchangeRateProvider} from "src/ExchangeRateProvider.sol";

interface IDripable is IERC20{
    function drip(address to) external;
}

contract L1ToL2Tx is Script {
    
    address owner=0x11EC78492D53c9276dD7a184B1dbfB34E50B710D;
    address link = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
    IDripable token = IDripable(address(0));
    ProgrammableDataTokenTransfers tokenBridge = ProgrammableDataTokenTransfers(payable(0x5C16aE212f8d721FAb74164d1039d4514b11DB54));
    ExchangeRateProvider erp = ExchangeRateProvider(0xEd704C24729Ff0904a6180459dda1A5B3789F742);
    uint64 l1ChainSelector=0;
    address l1Bridge=0x53d0D1add4e89E82fE872646830240F5feC477De;

    function run() external {
        require(address(tokenBridge) != address(0));
        require(l1Bridge != address(0));
        string memory testnetL2RPC = vm.envString("RPC_MAINNET_SEPOLIA");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
      
        uint l2Fork = vm.createSelectFork(testnetL2RPC);
        vm.startBroadcast(deployerPrivateKey);

        payable(tokenBridge).transfer(0.1 ether);
        token.drip(0x11EC78492D53c9276dD7a184B1dbfB34E50B710D);
        token.approve(address(tokenBridge), 1 ether);
        tokenBridge.allowlistSourceChain(l1ChainSelector, true);
        tokenBridge.allowlistSender(l1Bridge, true);
        tokenBridge.sendMessagePayNative(l1ChainSelector, l1Bridge, owner, 0.09 ether);

    }
}
