pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {ERC20Mintable} from "src/ReceiptToken.sol";
import {GovernanceSender} from "src/GovernanceSender.sol";
import {ExchangeRateProvider} from "src/ExchangeRateProvider.sol";

contract GovernanceTransaction is Script {
    
    address owner=0x11EC78492D53c9276dD7a184B1dbfB34E50B710D;
    GovernanceSender sender = GovernanceSender(payable(0xaE5FCA988701EFa29161f539a1782675efE3BDa2));
    uint64 l2ChainSelector=3478487238524512106;
    address l2GovProxy=0x259f8Fac9a9C155b1B625EfBAbE7B203bF0BF06C;
    address erp=0x402f38457800c32c67c5983381a685A4a1D4f8Bb;

    function run() external {
        require(address(sender) != address(0));
        require(l2GovProxy != address(0));
        string memory testnetL2RPC = vm.envString("RPC_MAINNET_SEPOLIA");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
      
        uint l2Fork = vm.createSelectFork(testnetL2RPC);
        vm.startBroadcast(deployerPrivateKey);

        payable(sender).transfer(0.1 ether);
        bytes memory callData = abi.encodeWithSelector(ExchangeRateProvider.setExchangeRate.selector, 2 ether);
        sender.allowlistGovernanceProxy(l2ChainSelector, l2GovProxy);
        sender.sendMessagePayNative(l2ChainSelector, erp, callData);

    }
}
