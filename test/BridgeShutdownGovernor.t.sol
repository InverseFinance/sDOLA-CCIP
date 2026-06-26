// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {
    BridgeShutdownChainUpdate,
    BridgeShutdownGovernor,
    IBridgeShutdownTokenPool
} from "src/BridgeShutdownGovernor.sol";
import {GovernanceSender} from "src/GovernanceSender.sol";

contract MockRouter is IRouterClient {
    uint256 public fee = 0.1 ether;
    uint256 public sends;
    uint64 public lastDestinationChainSelector;
    bytes public lastReceiver;
    bytes public lastData;
    bytes public lastExtraArgs;
    mapping(uint256 sendIndex => uint64 destinationChainSelector) public destinationChainSelectorsBySend;
    mapping(uint256 sendIndex => bytes receiver) public receiversBySend;
    mapping(uint256 sendIndex => bytes data) public dataBySend;
    mapping(uint256 sendIndex => bytes extraArgs) public extraArgsBySend;

    function setFee(uint256 newFee) external {
        fee = newFee;
    }

    function isChainSupported(uint64) external pure returns (bool) {
        return true;
    }

    function getSupportedTokens(uint64) external pure returns (address[] memory tokens) {
        tokens = new address[](0);
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external view returns (uint256) {
        return fee;
    }

    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32 messageId)
    {
        require(msg.value == fee, "unexpected fee");

        ++sends;
        lastDestinationChainSelector = destinationChainSelector;
        lastReceiver = message.receiver;
        lastData = message.data;
        lastExtraArgs = message.extraArgs;
        destinationChainSelectorsBySend[sends] = destinationChainSelector;
        receiversBySend[sends] = message.receiver;
        dataBySend[sends] = message.data;
        extraArgsBySend[sends] = message.extraArgs;

        messageId = keccak256(abi.encode(sends, destinationChainSelector, message.receiver, message.data));
    }
}

contract BridgeShutdownGovernorTest is Test {
    address internal owner = address(0xA11CE);
    address payable internal beneficiary = payable(address(0xBEEF));

    MockRouter internal router;
    GovernanceSender internal governanceSender;
    BridgeShutdownGovernor internal shutdownGovernor;

    function setUp() external {
        router = new MockRouter();
        governanceSender = _installGovernanceSender(address(router));
        shutdownGovernor = new BridgeShutdownGovernor(owner);

        assertEq(address(shutdownGovernor.governanceSender()), shutdownGovernor.GOVERNANCE_SENDER_ADDRESS());

        governanceSender.allowlistGovernanceProxy(
            shutdownGovernor.BASE_CHAIN_SELECTOR(), shutdownGovernor.BASE_GOVERNANCE_PROXY()
        );
        governanceSender.allowlistGovernanceProxy(
            shutdownGovernor.OPTIMISM_CHAIN_SELECTOR(), shutdownGovernor.OPTIMISM_GOVERNANCE_PROXY()
        );
        governanceSender.allowlistGovernanceProxy(
            shutdownGovernor.ARBITRUM_CHAIN_SELECTOR(), shutdownGovernor.ARBITRUM_GOVERNANCE_PROXY()
        );
        governanceSender.allowlistGovernanceProxy(
            shutdownGovernor.BERACHAIN_CHAIN_SELECTOR(), shutdownGovernor.BERACHAIN_GOVERNANCE_PROXY()
        );

        governanceSender.transferOwnership(address(shutdownGovernor));

        vm.prank(owner);
        shutdownGovernor.acceptGovernanceSenderOwnership();
    }

    function testAcceptGovernanceSenderOwnershipAllowlistsShutdownGovernor() external {
        assertEq(governanceSender.owner(), address(shutdownGovernor));
        assertTrue(governanceSender.allowListedCallers(address(shutdownGovernor)));
    }

    function testGovernanceProxiesArePreConfiguredOnSender() external {
        assertEq(
            governanceSender.governanceProxies(shutdownGovernor.BASE_CHAIN_SELECTOR()),
            shutdownGovernor.BASE_GOVERNANCE_PROXY()
        );
        assertEq(
            governanceSender.governanceProxies(shutdownGovernor.OPTIMISM_CHAIN_SELECTOR()),
            shutdownGovernor.OPTIMISM_GOVERNANCE_PROXY()
        );
        assertEq(
            governanceSender.governanceProxies(shutdownGovernor.ARBITRUM_CHAIN_SELECTOR()),
            shutdownGovernor.ARBITRUM_GOVERNANCE_PROXY()
        );
        assertEq(
            governanceSender.governanceProxies(shutdownGovernor.BERACHAIN_CHAIN_SELECTOR()),
            shutdownGovernor.BERACHAIN_GOVERNANCE_PROXY()
        );
    }

    function testExecuteL2ShutdownFundsSenderAndSendsFixedBatch() external {
        router.setFee(0.1 ether);

        uint256 messageCount = shutdownGovernor.L2_SHUTDOWN_MESSAGE_COUNT();
        uint256 feeBudget = messageCount * router.fee();

        vm.deal(owner, feeBudget);
        vm.prank(owner);
        bytes32[] memory messageIds = shutdownGovernor.executeL2Shutdown{value: feeBudget}();

        assertEq(messageIds.length, messageCount);
        assertEq(router.sends(), messageCount);
        assertEq(address(governanceSender).balance, 0);
        assertEq(router.lastDestinationChainSelector(), shutdownGovernor.BERACHAIN_CHAIN_SELECTOR());
        assertEq(router.lastReceiver(), abi.encode(shutdownGovernor.BERACHAIN_GOVERNANCE_PROXY()));
        assertEq(
            router.lastData(),
            abi.encode(
                shutdownGovernor.BERACHAIN_TOKEN(),
                abi.encodeWithSignature("setMinter(address,bool)", shutdownGovernor.BERACHAIN_TOKEN_POOL(), false)
            )
        );
        assertGt(uint256(messageIds[0]), 0);
        assertGt(uint256(messageIds[messageIds.length - 1]), 0);
        assertTrue(messageIds[0] != messageIds[messageIds.length - 1]);

        _assertUint64ArrayEq(
            _decodeTokenPoolRemovalsFromSentMessage(1),
            _array4(
                shutdownGovernor.ARBITRUM_CHAIN_SELECTOR(),
                shutdownGovernor.OPTIMISM_CHAIN_SELECTOR(),
                shutdownGovernor.MAINNET_CHAIN_SELECTOR(),
                shutdownGovernor.BERACHAIN_CHAIN_SELECTOR()
            )
        );
        _assertUint64ArrayEq(
            _decodeTokenPoolRemovalsFromSentMessage(2),
            _array3(
                shutdownGovernor.ARBITRUM_CHAIN_SELECTOR(),
                shutdownGovernor.BASE_CHAIN_SELECTOR(),
                shutdownGovernor.MAINNET_CHAIN_SELECTOR()
            )
        );
        _assertUint64ArrayEq(
            _decodeTokenPoolRemovalsFromSentMessage(3),
            _array4(
                shutdownGovernor.BASE_CHAIN_SELECTOR(),
                shutdownGovernor.OPTIMISM_CHAIN_SELECTOR(),
                shutdownGovernor.MAINNET_CHAIN_SELECTOR(),
                shutdownGovernor.BERACHAIN_CHAIN_SELECTOR()
            )
        );
        _assertUint64ArrayEq(
            _decodeTokenPoolRemovalsFromSentMessage(4),
            _array3(
                shutdownGovernor.ARBITRUM_CHAIN_SELECTOR(),
                shutdownGovernor.BASE_CHAIN_SELECTOR(),
                shutdownGovernor.MAINNET_CHAIN_SELECTOR()
            )
        );
    }

    function testRemovedHelperApisAreAbsent() external {
        BridgeShutdownGovernor.TokenPoolRemovals memory removals;

        (bool success,) = address(shutdownGovernor)
            .call(abi.encodeWithSignature("executeL2Shutdown((uint64[],uint64[],uint64[],uint64[]))", removals));
        assertFalse(success);

        (success,) = address(shutdownGovernor).staticcall(abi.encodeWithSignature("buildTokenPoolRemovals()"));
        assertFalse(success);

        (success,) = address(shutdownGovernor).staticcall(abi.encodeWithSignature("buildL2ShutdownMessages()"));
        assertFalse(success);

        (success,) = address(shutdownGovernor).staticcall(abi.encodeWithSignature("buildMainnetTokenPoolRemovals()"));
        assertFalse(success);

        (success,) = address(shutdownGovernor).staticcall(abi.encodeWithSignature("buildMainnetShutdownCalls()"));
        assertFalse(success);

        (success,) = address(shutdownGovernor)
            .staticcall(abi.encodeWithSignature("governanceProxyFor(uint64)", shutdownGovernor.BASE_CHAIN_SELECTOR()));
        assertFalse(success);

        (success,) = address(shutdownGovernor)
            .staticcall(
                abi.encodeWithSignature("buildL2ShutdownMessages((uint64[],uint64[],uint64[],uint64[]))", removals)
            );
        assertFalse(success);

        uint64[] memory mainnetRemovals = _array4(
            shutdownGovernor.BASE_CHAIN_SELECTOR(),
            shutdownGovernor.OPTIMISM_CHAIN_SELECTOR(),
            shutdownGovernor.ARBITRUM_CHAIN_SELECTOR(),
            shutdownGovernor.BERACHAIN_CHAIN_SELECTOR()
        );
        (success,) = address(shutdownGovernor)
            .staticcall(abi.encodeWithSignature("buildMainnetShutdownCalls(uint64[])", mainnetRemovals));
        assertFalse(success);

        (success,) = address(shutdownGovernor)
            .staticcall(abi.encodeWithSignature("buildMainnetLegacyBridgeShutdownCalls(address)", address(0)));
        assertFalse(success);

        (success,) = address(shutdownGovernor).call(abi.encodeWithSignature("setShutdownGovernanceProxies()"));
        assertFalse(success);
    }

    function testWithdrawPullsFromShutdownGovernorAndGovernanceSender() external {
        vm.deal(address(governanceSender), 1 ether);
        vm.deal(address(shutdownGovernor), 0.5 ether);

        uint256 beforeBalance = beneficiary.balance;

        vm.prank(owner);
        shutdownGovernor.withdraw(beneficiary);

        assertEq(beneficiary.balance - beforeBalance, 1.5 ether);
        assertEq(address(governanceSender).balance, 0);
        assertEq(address(shutdownGovernor).balance, 0);
    }

    function testTransferGovernanceSenderOwnershipDisablesShutdownCaller() external {
        address nextOwner = address(0x1234);

        vm.prank(owner);
        shutdownGovernor.transferGovernanceSenderOwnership(nextOwner);

        assertFalse(governanceSender.allowListedCallers(address(shutdownGovernor)));

        vm.prank(nextOwner);
        governanceSender.acceptOwnership();

        assertEq(governanceSender.owner(), nextOwner);
    }

    function testOnlyOwnerCanExecuteL2Shutdown() external {
        vm.expectRevert("Only callable by owner");
        shutdownGovernor.executeL2Shutdown();
    }

    function _installGovernanceSender(address router_) internal returns (GovernanceSender installedGovernanceSender) {
        GovernanceSender implementation = new GovernanceSender(router_);
        address senderAddress = 0x4e521Fe7A9084067096d45A312B8FEeE39D5F1f3;

        vm.etch(senderAddress, address(implementation).code);
        vm.store(senderAddress, bytes32(uint256(0)), bytes32(uint256(uint160(address(this)))));
        vm.store(senderAddress, bytes32(uint256(4)), bytes32(uint256(uint160(router_))));

        installedGovernanceSender = GovernanceSender(payable(senderAddress));
    }

    function _decodeTokenPoolRemovalsFromSentMessage(uint256 sendIndex) internal returns (uint64[] memory removals) {
        (address target, bytes memory callData) = abi.decode(router.dataBySend(sendIndex), (address, bytes));
        if (sendIndex == 1) assertEq(target, shutdownGovernor.BASE_TOKEN_POOL());
        if (sendIndex == 2) assertEq(target, shutdownGovernor.OPTIMISM_TOKEN_POOL());
        if (sendIndex == 3) assertEq(target, shutdownGovernor.ARBITRUM_TOKEN_POOL());
        if (sendIndex == 4) assertEq(target, shutdownGovernor.BERACHAIN_TOKEN_POOL());
        removals = _decodeTokenPoolRemovals(callData);
    }

    function _decodeTokenPoolRemovals(bytes memory callData) internal returns (uint64[] memory removals) {
        bytes4 selector;
        assembly {
            selector := mload(add(callData, 32))
        }
        assertEq(selector, IBridgeShutdownTokenPool.applyChainUpdates.selector);

        bytes memory encodedArgs = new bytes(callData.length - 4);
        for (uint256 i; i < encodedArgs.length; ++i) {
            encodedArgs[i] = callData[i + 4];
        }

        BridgeShutdownChainUpdate[] memory chainsToAdd;
        (removals, chainsToAdd) = abi.decode(encodedArgs, (uint64[], BridgeShutdownChainUpdate[]));
        assertEq(chainsToAdd.length, 0);
    }

    function _assertUint64ArrayEq(uint64[] memory actual, uint64[] memory expected) internal {
        assertEq(actual.length, expected.length);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(actual[i], expected[i]);
        }
    }

    function _array3(uint64 a, uint64 b, uint64 c) internal pure returns (uint64[] memory values) {
        values = new uint64[](3);
        values[0] = a;
        values[1] = b;
        values[2] = c;
    }

    function _array4(uint64 a, uint64 b, uint64 c, uint64 d) internal pure returns (uint64[] memory values) {
        values = new uint64[](4);
        values[0] = a;
        values[1] = b;
        values[2] = c;
        values[3] = d;
    }
}
