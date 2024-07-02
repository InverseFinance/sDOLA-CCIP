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
    IDripable token = IDripable(address(0x139E99f0ab4084E14e6bb7DacA289a91a2d92927));
    ProgrammableDataTokenTransfers tokenBridge = ProgrammableDataTokenTransfers(payable(0x4e1637B02C0560192644C967BE52087baE271B9D));
    address l1Bridge=0x52FFD313cc11882b75879C41d837b20F974ea88f;
    uint64 l1ChainSelector=16015286601757825753;

    function run() external {
        require(address(tokenBridge) != address(0));
        require(l1Bridge != address(0));
        string memory testnetL2RPC = vm.envString("RPC_ARBITRUM_SEPOLIA");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
      
        uint l2Fork = vm.createSelectFork(testnetL2RPC);
        vm.startBroadcast(deployerPrivateKey);

        payable(tokenBridge).transfer(0.1 ether);
        token.approve(address(tokenBridge), 1 ether);
        tokenBridge.allowlistDestinationChain(l1ChainSelector, true);
        tokenBridge.sendMessagePayNative(l1ChainSelector, l1Bridge, owner, 0.09 ether);

    }
}
