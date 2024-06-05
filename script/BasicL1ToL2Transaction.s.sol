pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {ERC20Mintable} from "src/ReceiptToken.sol";
import {ProgrammableDataTokenTransfers, IERC20} from "src/ProgrammableDataTokenTransfers.sol";

interface IDripable is IERC20{
    function drip(address to) external;
}

contract BasicL1ToL2Transaction is Script {
    
    address owner=0x11EC78492D53c9276dD7a184B1dbfB34E50B710D;
    address link = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
    IDripable token = IDripable(0x466D489b6d36E7E3b824ef491C225F5830E81cC1);
    ProgrammableDataTokenTransfers tokenBridge = ProgrammableDataTokenTransfers(payable(0x15E4613fF3f0818B25EE8647AB5B0679945e714e));
    uint64 l2ChainSelector=3478487238524512106;
    address l2Bridge=0xab4AE477899fD61B27744B4DEbe8990C66c81C22;

    function run() external {
        require(address(tokenBridge) != address(0));
        require(l2Bridge != address(0));
        string memory testnetL2RPC = vm.envString("RPC_MAINNET_SEPOLIA");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
      
        uint l2Fork = vm.createSelectFork(testnetL2RPC);
        vm.startBroadcast(deployerPrivateKey);

        payable(tokenBridge).transfer(0.1 ether);
        token.drip(address(tokenBridge));
        //token.transfer(address(tokenBridge), 0.01 ether);
        tokenBridge.setExchangeRate(1 ether + 1);
        tokenBridge.sendMessagePayNative(l2ChainSelector, l2Bridge, owner, 0.09 ether);

    }
}
