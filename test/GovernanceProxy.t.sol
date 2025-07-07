pragma solidity ^0.8.19;

import {ExchangeRateProvider} from "src/ExchangeRateProvider.sol";
import {ExchangeRateUpdater} from "src/ExchangeRateUpdater.sol";
import {GovernanceProxy} from "src/GovernanceProxy.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {AddrConfig} from "script/AddrConfig.sol";
import "forge-std/Test.sol";

interface IOwnable {
    function acceptOwnership() external;
}

contract GovernanceProxyTest is Test, AddrConfig {
    address owner = 0x11EC78492D53c9276dD7a184B1dbfB34E50B710D; //gov
    GovernanceProxy proxy = GovernanceProxy(payable(0xE14fb483973945a655BFB80234331B9766BC40ca));
    ExchangeRateUpdater eru;
    uint64 l2ChainSelector = 3734403246176062136; //OP CCIP chainselector
    address allowedSender = 0xAeA8Ae87A34a0fAaEa0e6beD9f4627F576B524Fa;
    uint l2Fork;

    function setUp() external {
        //eru = ExchangeRateUpdater(payable(config.arbitrumSepolia().exchangeRateUpdater));
        l2Fork = vm.createSelectFork(arbitrumSepolia.network);
    }

    function testReceiveMessage() external {
        bytes memory callData = abi.encodeWithSelector(IOwnable.acceptOwnership.selector);
        Client.Any2EVMMessage memory message = buildCCIPMessage(arbitrumSepolia.tokenPool, callData);
        vm.prank(arbitrumSepolia.router);
        proxy.ccipReceive(message);
    }

    function buildCCIPMessage(
        address _calledContract,
        bytes memory _callData
    ) public view returns (Client.Any2EVMMessage memory) {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        return
            Client.Any2EVMMessage({
                messageId: bytes32(uint(1)),
                sourceChainSelector: mainnetSepolia.chainSelector,
                sender: abi.encode(0x74a5a9fB545C373DeE2411f5134d4702A881A21b), // ABI-encoded allowedSender address
                data: abi.encode(_calledContract, _callData),
                destTokenAmounts: new Client.EVMTokenAmount[](0) // Empty array as no tokens are transferred
            });
    }



}
