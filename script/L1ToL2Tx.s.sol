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
    IDripable token = IDripable(0x466D489b6d36E7E3b824ef491C225F5830E81cC1);
    ProgrammableDataTokenTransfers tokenBridge = ProgrammableDataTokenTransfers(payable(0xE5f24791E273Cb96A1f8E5B67Bc2397F0AD9B8B4));
    ExchangeRateProvider erp = ExchangeRateProvider(0xEc51E66c1e1BFc85aCc3b6847820A3Ff0a38364b);
    uint64 l2ChainSelector=3478487238524512106;
    address l2Bridge=0x93685185666c8D34ad4c574B3DBF41231bbfB31b;

    function run() external {
        require(address(tokenBridge) != address(0));
        require(l2Bridge != address(0));
        string memory testnetL2RPC = vm.envString("RPC_MAINNET_SEPOLIA");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
      
        uint l2Fork = vm.createSelectFork(testnetL2RPC);
        vm.startBroadcast(deployerPrivateKey);

        payable(tokenBridge).transfer(0.1 ether);
        token.drip(0x11EC78492D53c9276dD7a184B1dbfB34E50B710D);
        token.approve(address(tokenBridge), 1 ether);
        erp.setExchangeRate(3 ether);
        tokenBridge.allowlistSourceChain(l2ChainSelector, true);
        tokenBridge.allowlistSender(l2Bridge, true);
        tokenBridge.sendMessagePayNative(l2ChainSelector, l2Bridge, owner, 0.09 ether);

    }
}
