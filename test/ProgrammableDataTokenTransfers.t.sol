pragma solidity ^0.8.19;

import {ExchangeRateProvider} from "src/ExchangeRateProvider.sol";
import {ProgrammableDataTokenTransfers, IERC20} from "src/ProgrammableDataTokenTransfers.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import "forge-std/Test.sol";

interface IDrippable {
    function drip(address to) external;
}

contract ProgrammableDataTokenTransfersTest is Test {
    address owner = 0x11EC78492D53c9276dD7a184B1dbfB34E50B710D; //gov
    address link = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
    address router = 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;
    address token = 0xA8C0c11bf64AF62CDCA6f93D3769B88BdD7cb93D;
    ProgrammableDataTokenTransfers pdtt;
    ExchangeRateProvider erp;
    uint64 l1ChainSelector = 16015286601757825753;
    uint64 l2ChainSelector = 3478487238524512106; //Arbitrum CCIP chainselector
    address sender = 0x4C7b266B4bf0A8758fa85E69292eE55c212236cF;
    address user = address(0xA);
    uint l2Fork;

    function setUp() external {
        string memory testnetL2RPC = vm.envString("RPC_ARBITRUM_SEPOLIA");

        l2Fork = vm.createSelectFork(testnetL2RPC);
        erp = new ExchangeRateProvider();
        pdtt = new ProgrammableDataTokenTransfers(router, token, link, address(erp), false);
        pdtt.allowlistSourceChain(l1ChainSelector, true);
        pdtt.allowlistDestinationChain(l1ChainSelector, true);
        pdtt.allowlistSender(sender, l1ChainSelector, true);
        erp.setUpdater(address(pdtt), true);
    }

    function testSendMessagePayNative() external {
        uint amount = 1 ether;
        IDrippable(token).drip(user);
        vm.prank(user);
        IERC20(token).approve(address(pdtt), 1 ether);
        deal(user, 1 ether);
        assertEq(IERC20(token).balanceOf(user), amount);
        vm.prank(user);
        pdtt.sendMessagePayNative{value: 1 ether}(l1ChainSelector, sender, user, amount);
        assertEq(IERC20(token).balanceOf(user), 0);
        assertGt(user.balance, 0);
    }

    function testSendMessagePayNative_fail_notAllowedDestChain() external {
        uint amount = 1 ether;
        IDrippable(token).drip(user);
        pdtt.allowlistDestinationChain(l1ChainSelector, false);
        vm.prank(user);
        IERC20(token).approve(address(pdtt), 1 ether);
        deal(user, 1 ether);
        assertEq(IERC20(token).balanceOf(user), amount);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ProgrammableDataTokenTransfers.DestinationChainNotAllowed.selector, l1ChainSelector)
        );
        pdtt.sendMessagePayNative{value: 1 ether}(l1ChainSelector, sender, user, amount);
    }


    function testReceiveMessage() external {
        vm.selectFork(l2Fork);
        uint amount = 1 ether;
        uint lastUpdate = block.timestamp;
        Client.Any2EVMMessage memory message = buildRouterMessage(user, token, amount, lastUpdate, 2 ether);
        IDrippable(token).drip(address(pdtt));
        vm.prank(router);
        pdtt.ccipReceive(message);
        assertEq(erp.exchangeRate(), 2 ether);
        assertEq(erp.lastUpdate(), lastUpdate);
        assertEq(IERC20(token).balanceOf(address(pdtt)), 0, "Contract did not send funds");
        assertEq(IERC20(token).balanceOf(user), amount, "Receiver did not receive funds");
    }

    function testReceiveMessage_IsCanonical() external {
        vm.selectFork(l2Fork);
        uint amount = 1 ether;
        uint lastUpdate = block.timestamp;
        pdtt = new ProgrammableDataTokenTransfers(router, token, link, address(erp), true);
        pdtt.allowlistSourceChain(l1ChainSelector, true);
        pdtt.allowlistSender(sender, l1ChainSelector, true);
        erp.setUpdater(address(pdtt), true);
        Client.Any2EVMMessage memory message = buildRouterMessage(user, token, amount, lastUpdate, 2 ether);
        IDrippable(token).drip(address(pdtt));
        uint exchangeRateBefore = erp.exchangeRate();
        uint lastUpdateBefore = erp.lastUpdate();

        vm.prank(router);
        pdtt.ccipReceive(message);
        assertEq(erp.exchangeRate(), exchangeRateBefore);
        assertEq(erp.lastUpdate(), lastUpdateBefore);
        assertEq(IERC20(token).balanceOf(address(pdtt)), 0, "Contract did not send funds");
        assertEq(IERC20(token).balanceOf(user), amount, "Receiver did not receive funds");
    }


    function testReceiveMessage_doesNotIncreaseExchangeRateIfLower() external {
        vm.selectFork(l2Fork);
        uint amount = 1 ether;
        uint lastUpdate = block.timestamp;
        Client.Any2EVMMessage memory message = buildRouterMessage(user, token, amount, lastUpdate, 2 ether);
        IDrippable(token).drip(address(pdtt));
        vm.prank(router);
        pdtt.ccipReceive(message);
        assertEq(erp.exchangeRate(), 2 ether);
        assertEq(erp.lastUpdate(), lastUpdate);

        message = buildRouterMessage(user, token, amount, lastUpdate, 1 ether);
        IDrippable(token).drip(address(pdtt));
        vm.prank(router);
        pdtt.ccipReceive(message);
        assertEq(erp.exchangeRate(), 2 ether);
        assertEq(erp.lastUpdate(), lastUpdate);
    }

    function testReceiveMessage_doesNotLastUpdateIfLower() external {
        vm.selectFork(l2Fork);
        uint amount = 1 ether;
        uint lastUpdate = block.timestamp;
        Client.Any2EVMMessage memory message = buildRouterMessage(user, token, amount, lastUpdate, 2 ether);
        IDrippable(token).drip(address(pdtt));
        vm.prank(router);
        pdtt.ccipReceive(message);
        assertEq(erp.exchangeRate(), 2 ether);
        assertEq(erp.lastUpdate(), lastUpdate);

        message = buildRouterMessage(user, token, amount, lastUpdate - 1, 2 ether);
        IDrippable(token).drip(address(pdtt));
        vm.prank(router);
        pdtt.ccipReceive(message);
        assertEq(erp.exchangeRate(), 2 ether);
        assertEq(erp.lastUpdate(), lastUpdate);
    }

    function testReceiveMessage_fail_notAllowedSourceChain() external {
        vm.selectFork(l2Fork);
        uint amount = 1 ether;
        uint lastUpdate = block.timestamp;
        Client.Any2EVMMessage memory message = buildRouterMessage(user, token, amount, lastUpdate, 2 ether);
        message.sourceChainSelector = 0;
        IDrippable(token).drip(address(pdtt));
        vm.prank(router);
        vm.expectRevert(
            abi.encodeWithSelector(ProgrammableDataTokenTransfers.SourceChainNotAllowed.selector, message.sourceChainSelector)
        );
        pdtt.ccipReceive(message);
    }

    function testReceiveMessage_fail_notAllowedSender() external {
        vm.selectFork(l2Fork);
        uint amount = 1 ether;
        uint lastUpdate = block.timestamp;
        Client.Any2EVMMessage memory message = buildRouterMessage(user, token, amount, lastUpdate, 2 ether);
        message.sender = abi.encode(address(0xdead));
        IDrippable(token).drip(address(pdtt));
        vm.prank(router);
        vm.expectRevert(
            abi.encodeWithSelector(ProgrammableDataTokenTransfers.SenderNotAllowed.selector, address(0xdead))
        );
        pdtt.ccipReceive(message);
    }


    function buildRouterMessage(
        address _receiver,
        address _token,
        uint256 _amount,
        uint256 _lastUpdate,
        uint256 _exchangeRate
    ) public view returns (Client.Any2EVMMessage memory) {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // Set the token amounts
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({
            token: _token,
            amount: _amount
        });
        tokenAmounts[0] = tokenAmount;

        return
            Client.Any2EVMMessage({
                messageId: bytes32(uint(1)),
                sourceChainSelector: l1ChainSelector,
                sender: abi.encode(sender), // ABI-encoded sender address
                data: abi.encode(_lastUpdate, _exchangeRate, _receiver),
                destTokenAmounts: tokenAmounts
            });
    }


    function getExchangeRate() public view returns(uint256 exchangeRate){
        exchangeRate = erp.exchangeRate();
    }

    /// @notice Get last update timestamp of the exchange rate
    /// @return The timestamp of the last exchange rate update
    /// @dev This time will always be the block timestamp on mainnet, whereas on L2s it will be lagging
    function getLastUpdate() public view returns(uint256) {
        return erp.lastUpdate();
    }


}
