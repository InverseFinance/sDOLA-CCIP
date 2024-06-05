pragma solidity ^0.8.19;

import {ExchangeRateProvider} from "src/ExchangeRateProvider.sol";
import {GovernanceProxy} from "src/GovernanceProxy.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import "forge-std/Test.sol";

contract GovernanceProxyTest is Test {
    address owner = 0x11EC78492D53c9276dD7a184B1dbfB34E50B710D; //gov
    address link = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
    address router = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    //ERC20Mintable lockedToken = ERC20Mintable(0xCbB162B761B83578b2a0226cbAf4C1adE0d60B2e); //sDOLA
    GovernanceProxy proxy;
    ExchangeRateProvider erp;
    uint64 l1ChainSelector = 3478487238524512106; //Arbitrum CCIP chainselector
    address sender = 0x4C7b266B4bf0A8758fa85E69292eE55c212236cF;
    uint l2Fork;

    function setUp() external {
        string memory testnetL2RPC = vm.envString("RPC_MAINNET_SEPOLIA");

        l2Fork = vm.createSelectFork(testnetL2RPC);
        proxy = new GovernanceProxy(router, sender, l1ChainSelector);
        erp = new ExchangeRateProvider();
        erp.setUpdater(address(proxy), true);
    }

    function testReceiveMessage() external {
        bytes memory callData = abi.encodeWithSelector(ExchangeRateProvider.setExchangeRate.selector, 2 ether);
        Client.Any2EVMMessage memory message = buildCCIPMessage(address(proxy), address(erp), callData);
        vm.prank(router);
        proxy.ccipReceive(message);
        assertEq(erp.exchangeRate(), 2 ether);
    }

    function buildCCIPMessage(
        address _proxy,
        address _calledContract,
        bytes memory _callData
    ) public view returns (Client.Any2EVMMessage memory) {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        return
            Client.Any2EVMMessage({
                messageId: bytes32(uint(1)),
                sourceChainSelector: l1ChainSelector,
                sender: abi.encode(sender), // ABI-encoded sender address
                data: abi.encode(_calledContract, _callData),
                destTokenAmounts: new Client.EVMTokenAmount[](0) // Empty array as no tokens are transferred
            });
    }



}
