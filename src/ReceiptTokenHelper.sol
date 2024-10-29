pragma solidity ^0.8.19;

import {ERC20Mintable, ExchangeRateProvider} from "src/ReceiptToken.sol";
import {GovernanceSender} from "src/GovernanceSender.sol";


contract ReceiptTokenHelper {
    
    address public gov;
    GovernanceSender public sender;

    error OnlyGovernance();

    modifier OnlyGov() {
        if(msg.sender != gov) revert OnlyGovernance();
        _;
    }

    constructor(address _gov, address _govSender){
        gov = _gov;
        sender = GovernanceSender(payable(_govSender));
    }

    function setMinter(uint64 ccipChainSelector, address l2ReceiptToken, address l2Minter, bool canMint) external OnlyGov {
        bytes memory callData = abi.encodeWithSelector(ERC20Mintable.setMinter.selector, l2Minter, canMint);
        sender.sendMessagePayNative(ccipChainSelector, l2ReceiptToken, callData, 400_000);
        
    }

    function setUpdater(uint64 ccipChainSelector, address l2ReceiptToken, address l2Updater, bool canUpdate) external OnlyGov {
        bytes memory callData = abi.encodeWithSelector(ExchangeRateProvider.setUpdater.selector, l2Updater, canUpdate);
        sender.sendMessagePayNative(ccipChainSelector, l2ReceiptToken, callData, 400_000);
        
    }

    function setPendingOwner(uint64 ccipChainSelector, address l2ReceiptToken, address pendingOwner) external OnlyGov {
        bytes memory callData = abi.encodeWithSelector(ExchangeRateProvider.setPendingOwner.selector, pendingOwner);
        sender.sendMessagePayNative(ccipChainSelector, l2ReceiptToken, callData, 400_000);   
    }

    function acceptOwner(uint64 ccipChainSelector, address l2ReceiptToken) external OnlyGov {
        bytes memory callData = abi.encodeWithSelector(ExchangeRateProvider.acceptOwner.selector);
        sender.sendMessagePayNative(ccipChainSelector, l2ReceiptToken, callData, 400_000);   
    }

    function setGov(address _newGov) external OnlyGov {
        gov = _newGov;
    }
}
