// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test, Vm} from "forge-std/Test.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {GovernanceSender} from "src/GovernanceSender.sol";
import {SINVBridgeShutdownGovernor} from "src/SINVBridgeShutdownGovernor.sol";

interface ISINVShutdownGovernanceProxy {
    function allowedSender() external view returns (address);
    function getRouter() external view returns (address);
    function ccipReceive(Client.Any2EVMMessage calldata message) external;
}

interface ISINVShutdownProgrammableBridge {
    function owner() external view returns (address);
    function transferOwnership(address to) external;
    function acceptOwnership() external;
    function allowlistDestinationChain(uint64 destinationChainSelector, bool allowed) external;
    function allowlistSourceChain(uint64 sourceChainSelector, bool allowed) external;
    function allowlistSender(address sender, uint64 sourceChainSelector, bool allowed) external;
    function allowlistedDestinationChains(uint64 destinationChainSelector) external view returns (bool);
    function allowlistedSourceChains(uint64 sourceChainSelector) external view returns (bool);
    function allowlistedSenders(uint64 sourceChainSelector, address sender) external view returns (bool);
}

contract SINVRecordingRouter is IRouterClient {
    uint256 public constant FIXED_FEE = 0.001 ether;

    bytes32 internal constant SENDS_SLOT = bytes32(uint256(keccak256("inverse.sinv.shutdown.test.router.sends")) - 1);

    event CcipSendRecorded(
        uint256 indexed sendIndex,
        uint64 indexed destinationChainSelector,
        bytes32 indexed messageId,
        bytes receiver,
        bytes data,
        bytes extraArgs,
        address feeToken,
        uint256 fee
    );

    function isChainSupported(uint64) external pure returns (bool) {
        return true;
    }

    function getSupportedTokens(uint64) external pure returns (address[] memory tokens) {
        tokens = new address[](0);
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external pure returns (uint256) {
        return FIXED_FEE;
    }

    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32 messageId)
    {
        require(msg.value == FIXED_FEE, "unexpected fee");

        uint256 sendIndex = _incrementSends();
        messageId = keccak256(
            abi.encode(sendIndex, destinationChainSelector, message.receiver, message.data, message.extraArgs)
        );

        emit CcipSendRecorded(
            sendIndex,
            destinationChainSelector,
            messageId,
            message.receiver,
            message.data,
            message.extraArgs,
            message.feeToken,
            msg.value
        );
    }

    function sends() external view returns (uint256 count) {
        bytes32 slot = SENDS_SLOT;
        assembly {
            count := sload(slot)
        }
    }

    function _incrementSends() internal returns (uint256 count) {
        bytes32 slot = SENDS_SLOT;
        assembly {
            count := add(sload(slot), 1)
            sstore(slot, count)
        }
    }
}

contract SINVBridgeShutdownGovernorForkTest is Test {
    struct RecordedMessage {
        uint256 sendIndex;
        uint64 destinationChainSelector;
        bytes32 messageId;
        bytes receiver;
        bytes data;
        bytes extraArgs;
        address feeToken;
        uint256 fee;
    }

    uint256 internal constant ETHEREUM_FORK_BLOCK = 23_618_514;
    uint256 internal constant BASE_FORK_BLOCK = 37_085_140;
    uint256 internal constant OPTIMISM_FORK_BLOCK = 142_680_427;
    uint256 internal constant ARBITRUM_FORK_BLOCK = 391_501_570;

    address internal constant MAINNET_GOV = 0x926dF14a23BE491164dCF93f4c468A50ef659D5B;
    address internal constant OLD_MAINNET_BRIDGE_OWNER = 0x11EC78492D53c9276dD7a184B1dbfB34E50B710D;
    address internal constant GOVERNANCE_SENDER_ADDRESS = 0xAeA8Ae87A34a0fAaEa0e6beD9f4627F576B524Fa;

    address internal constant MAINNET_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    address internal constant BASE_ROUTER = 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD;
    address internal constant OPTIMISM_ROUTER = 0x3206695CaE29952f4b0c22a169725a865bc8Ce0f;
    address internal constant ARBITRUM_ROUTER = 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8;

    uint64 internal constant MAINNET_CHAIN_SELECTOR = 5009297550715157269;
    uint64 internal constant BASE_CHAIN_SELECTOR = 15971525489660198786;
    uint64 internal constant OPTIMISM_CHAIN_SELECTOR = 3734403246176062136;
    uint64 internal constant ARBITRUM_CHAIN_SELECTOR = 4949039107694359620;

    address internal constant BASE_GOVERNANCE_PROXY = 0x5D5392505ee69f9FE7a6a1c1AF14f17Db3B3e364;
    address internal constant OPTIMISM_GOVERNANCE_PROXY = 0xCbB162B761B83578b2a0226cbAf4C1adE0d60B2e;
    address internal constant ARBITRUM_GOVERNANCE_PROXY = 0x1230bd56bf23Bf7adF95b9F861711301E3CCd6b3;

    address internal constant OLD_MAINNET_PROGRAMMABLE_BRIDGE = 0x7A43C13f7Fb3A0bF19cEB3fBC583A0CAda6D29a2;
    address internal constant NEW_MAINNET_PROGRAMMABLE_BRIDGE = 0x70F3795c1EF726c58FfeA2e1A51526ac5707C066;
    address internal constant BASE_PROGRAMMABLE_BRIDGE = 0x0173804066F7403E0815680F3DDa125a6cd10F7c;
    address internal constant OP_PROGRAMMABLE_BRIDGE = 0xb5A998E90AdeD2C97f7ceDbb7c45Bbc27E82dfdD;
    address internal constant ARB_PROGRAMMABLE_BRIDGE = 0x0173804066F7403E0815680F3DDa125a6cd10F7c;

    uint256 internal constant L2_SHUTDOWN_MESSAGE_COUNT = 30;
    uint256 internal constant RECORDING_ROUTER_FIXED_FEE = 0.001 ether;

    bytes32 internal constant CCIP_SEND_RECORDED_TOPIC =
        keccak256("CcipSendRecorded(uint256,uint64,bytes32,bytes,bytes,bytes,address,uint256)");
    bytes32 internal constant MESSAGE_RECEIVED_TOPIC =
        keccak256("MessageReceived(bytes32,uint64,address,address,bool)");

    uint256 internal ethereumFork;
    uint256 internal baseFork;
    uint256 internal optimismFork;
    uint256 internal arbitrumFork;

    function setUp() external {
        ethereumFork = vm.createFork("ethereum", ETHEREUM_FORK_BLOCK);
        baseFork = vm.createFork("base", BASE_FORK_BLOCK);
        optimismFork = vm.createFork("optimism", OPTIMISM_FORK_BLOCK);
        arbitrumFork = vm.createFork("arbitrum", ARBITRUM_FORK_BLOCK);
    }

    function testDeepForkFullSINVShutdownFlow() external {
        _assertPreShutdownState();

        vm.selectFork(ethereumFork);
        _installRecordingRouter();
        _executeMainnetShutdownWithOldBridgePrecondition();
        _assertMainnetShutdownState();

        GovernanceSender governanceSender = GovernanceSender(payable(GOVERNANCE_SENDER_ADDRESS));
        SINVBridgeShutdownGovernor shutdownGovernor = new SINVBridgeShutdownGovernor(MAINNET_GOV);

        vm.prank(MAINNET_GOV);
        governanceSender.transferOwnership(address(shutdownGovernor));

        vm.prank(MAINNET_GOV);
        shutdownGovernor.acceptGovernanceSenderOwnership();

        assertEq(governanceSender.owner(), address(shutdownGovernor));
        assertTrue(governanceSender.allowListedCallers(address(shutdownGovernor)));

        uint256 feeBudget = L2_SHUTDOWN_MESSAGE_COUNT * RECORDING_ROUTER_FIXED_FEE;
        uint256 senderBalanceBefore = address(governanceSender).balance;
        vm.deal(MAINNET_GOV, feeBudget);

        vm.recordLogs();
        vm.prank(MAINNET_GOV);
        bytes32[] memory messageIds = shutdownGovernor.executeL2Shutdown{value: feeBudget}();
        RecordedMessage[] memory messages = _recordedMessagesFromLogs(vm.getRecordedLogs());

        assertEq(messageIds.length, L2_SHUTDOWN_MESSAGE_COUNT);
        assertEq(messages.length, L2_SHUTDOWN_MESSAGE_COUNT);
        assertEq(SINVRecordingRouter(MAINNET_ROUTER).sends(), L2_SHUTDOWN_MESSAGE_COUNT);
        assertEq(address(governanceSender).balance, senderBalanceBefore);

        for (uint256 i; i < messages.length; ++i) {
            assertEq(messages[i].sendIndex, i + 1);
            assertEq(messages[i].messageId, messageIds[i]);
            assertEq(messages[i].feeToken, address(0));
            assertEq(messages[i].fee, RECORDING_ROUTER_FIXED_FEE);
            assertEq(messages[i].receiver, abi.encode(_governanceProxyFor(messages[i].destinationChainSelector)));
        }

        _deliverMessages(messages);
        _assertL2ShutdownState();

        vm.selectFork(ethereumFork);
        vm.prank(MAINNET_GOV);
        shutdownGovernor.transferGovernanceSenderOwnership(MAINNET_GOV);
        assertFalse(governanceSender.allowListedCallers(address(shutdownGovernor)));

        vm.prank(MAINNET_GOV);
        governanceSender.acceptOwnership();
        assertEq(governanceSender.owner(), MAINNET_GOV);
    }

    function testOldMainnetBridgeRequiresOwnershipPrecondition() external {
        vm.selectFork(ethereumFork);

        assertEq(ISINVShutdownProgrammableBridge(OLD_MAINNET_PROGRAMMABLE_BRIDGE).owner(), OLD_MAINNET_BRIDGE_OWNER);

        vm.prank(MAINNET_GOV);
        vm.expectRevert(bytes("Only callable by owner"));
        ISINVShutdownProgrammableBridge(OLD_MAINNET_PROGRAMMABLE_BRIDGE)
            .allowlistSourceChain(BASE_CHAIN_SELECTOR, false);

        _transferOldMainnetBridgeToGov();

        vm.prank(MAINNET_GOV);
        ISINVShutdownProgrammableBridge(OLD_MAINNET_PROGRAMMABLE_BRIDGE)
            .allowlistSourceChain(BASE_CHAIN_SELECTOR, false);
    }

    function _assertPreShutdownState() internal {
        vm.selectFork(ethereumFork);

        GovernanceSender governanceSender = GovernanceSender(payable(GOVERNANCE_SENDER_ADDRESS));
        _assertHasCode(GOVERNANCE_SENDER_ADDRESS, "missing sinv governance sender");
        assertEq(governanceSender.owner(), MAINNET_GOV);
        assertEq(governanceSender.governanceProxies(BASE_CHAIN_SELECTOR), BASE_GOVERNANCE_PROXY);
        assertEq(governanceSender.governanceProxies(OPTIMISM_CHAIN_SELECTOR), OPTIMISM_GOVERNANCE_PROXY);
        assertEq(governanceSender.governanceProxies(ARBITRUM_CHAIN_SELECTOR), ARBITRUM_GOVERNANCE_PROXY);

        _assertHasCode(OLD_MAINNET_PROGRAMMABLE_BRIDGE, "missing old mainnet programmable bridge");
        _assertHasCode(NEW_MAINNET_PROGRAMMABLE_BRIDGE, "missing new mainnet programmable bridge");
        assertEq(ISINVShutdownProgrammableBridge(OLD_MAINNET_PROGRAMMABLE_BRIDGE).owner(), OLD_MAINNET_BRIDGE_OWNER);
        assertEq(ISINVShutdownProgrammableBridge(NEW_MAINNET_PROGRAMMABLE_BRIDGE).owner(), MAINNET_GOV);

        _assertL2PreShutdownState(baseFork, BASE_GOVERNANCE_PROXY, BASE_ROUTER, BASE_PROGRAMMABLE_BRIDGE);
        _assertL2PreShutdownState(optimismFork, OPTIMISM_GOVERNANCE_PROXY, OPTIMISM_ROUTER, OP_PROGRAMMABLE_BRIDGE);
        _assertL2PreShutdownState(arbitrumFork, ARBITRUM_GOVERNANCE_PROXY, ARBITRUM_ROUTER, ARB_PROGRAMMABLE_BRIDGE);
    }

    function _assertL2PreShutdownState(
        uint256 forkId,
        address governanceProxy,
        address router,
        address programmableBridge
    ) internal {
        vm.selectFork(forkId);

        _assertHasCode(governanceProxy, "missing sinv governance proxy");
        _assertHasCode(programmableBridge, "missing sinv programmable bridge");
        assertEq(ISINVShutdownGovernanceProxy(governanceProxy).getRouter(), router);
        assertEq(ISINVShutdownGovernanceProxy(governanceProxy).allowedSender(), GOVERNANCE_SENDER_ADDRESS);
        assertEq(ISINVShutdownProgrammableBridge(programmableBridge).owner(), governanceProxy);
    }

    function _installRecordingRouter() internal {
        SINVRecordingRouter implementation = new SINVRecordingRouter();
        vm.etch(MAINNET_ROUTER, address(implementation).code);
    }

    function _executeMainnetShutdownWithOldBridgePrecondition() internal {
        _transferOldMainnetBridgeToGov();
        _executeMainnetBridgeShutdown(OLD_MAINNET_PROGRAMMABLE_BRIDGE);
        _executeMainnetBridgeShutdown(NEW_MAINNET_PROGRAMMABLE_BRIDGE);
    }

    function _transferOldMainnetBridgeToGov() internal {
        vm.selectFork(ethereumFork);

        vm.prank(OLD_MAINNET_BRIDGE_OWNER);
        ISINVShutdownProgrammableBridge(OLD_MAINNET_PROGRAMMABLE_BRIDGE).transferOwnership(MAINNET_GOV);

        vm.prank(MAINNET_GOV);
        ISINVShutdownProgrammableBridge(OLD_MAINNET_PROGRAMMABLE_BRIDGE).acceptOwnership();

        assertEq(ISINVShutdownProgrammableBridge(OLD_MAINNET_PROGRAMMABLE_BRIDGE).owner(), MAINNET_GOV);
    }

    function _executeMainnetBridgeShutdown(address bridge) internal {
        uint64[3] memory remoteSelectors = [BASE_CHAIN_SELECTOR, OPTIMISM_CHAIN_SELECTOR, ARBITRUM_CHAIN_SELECTOR];

        vm.startPrank(MAINNET_GOV);
        for (uint256 i; i < remoteSelectors.length; ++i) {
            ISINVShutdownProgrammableBridge(bridge).allowlistDestinationChain(remoteSelectors[i], false);
            ISINVShutdownProgrammableBridge(bridge).allowlistSourceChain(remoteSelectors[i], false);
        }
        ISINVShutdownProgrammableBridge(bridge).allowlistSender(BASE_PROGRAMMABLE_BRIDGE, BASE_CHAIN_SELECTOR, false);
        ISINVShutdownProgrammableBridge(bridge).allowlistSender(OP_PROGRAMMABLE_BRIDGE, OPTIMISM_CHAIN_SELECTOR, false);
        ISINVShutdownProgrammableBridge(bridge).allowlistSender(ARB_PROGRAMMABLE_BRIDGE, ARBITRUM_CHAIN_SELECTOR, false);
        vm.stopPrank();
    }

    function _recordedMessagesFromLogs(Vm.Log[] memory logs) internal pure returns (RecordedMessage[] memory messages) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 4 && logs[i].topics[0] == CCIP_SEND_RECORDED_TOPIC) ++count;
        }

        messages = new RecordedMessage[](count);
        count = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 4 || logs[i].topics[0] != CCIP_SEND_RECORDED_TOPIC) continue;

            (bytes memory receiver, bytes memory data, bytes memory extraArgs, address feeToken, uint256 fee) =
                abi.decode(logs[i].data, (bytes, bytes, bytes, address, uint256));

            messages[count++] = RecordedMessage({
                sendIndex: uint256(logs[i].topics[1]),
                destinationChainSelector: uint64(uint256(logs[i].topics[2])),
                messageId: logs[i].topics[3],
                receiver: receiver,
                data: data,
                extraArgs: extraArgs,
                feeToken: feeToken,
                fee: fee
            });
        }
    }

    function _deliverMessages(RecordedMessage[] memory messages) internal {
        for (uint256 i; i < messages.length; ++i) {
            RecordedMessage memory message = messages[i];
            address governanceProxy = _governanceProxyFor(message.destinationChainSelector);
            address router = _routerFor(message.destinationChainSelector);
            (address target,) = abi.decode(message.data, (address, bytes));

            vm.selectFork(_forkFor(message.destinationChainSelector));
            vm.recordLogs();
            vm.prank(router);
            ISINVShutdownGovernanceProxy(governanceProxy)
                .ccipReceive(
                    Client.Any2EVMMessage({
                    messageId: message.messageId,
                    sourceChainSelector: MAINNET_CHAIN_SELECTOR,
                    sender: abi.encode(GOVERNANCE_SENDER_ADDRESS),
                    data: message.data,
                    destTokenAmounts: new Client.EVMTokenAmount[](0)
                })
                );

            _assertGovernanceProxyCallSucceeded(vm.getRecordedLogs(), governanceProxy, message.messageId, target);
        }
    }

    function _assertGovernanceProxyCallSucceeded(
        Vm.Log[] memory logs,
        address governanceProxy,
        bytes32 messageId,
        address expectedTarget
    ) internal {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != governanceProxy) continue;
            if (logs[i].topics.length != 3 || logs[i].topics[0] != MESSAGE_RECEIVED_TOPIC) continue;
            if (logs[i].topics[1] != messageId) continue;
            if (uint64(uint256(logs[i].topics[2])) != MAINNET_CHAIN_SELECTOR) continue;

            (address sender, address target, bool success) = abi.decode(logs[i].data, (address, address, bool));
            assertEq(sender, GOVERNANCE_SENDER_ADDRESS);
            assertEq(target, expectedTarget);
            assertTrue(success, "governance proxy target call failed");
            return;
        }

        revert("missing MessageReceived event");
    }

    function _assertMainnetShutdownState() internal {
        _assertMainnetLegacyBridgeShutdown(OLD_MAINNET_PROGRAMMABLE_BRIDGE);
        _assertMainnetLegacyBridgeShutdown(NEW_MAINNET_PROGRAMMABLE_BRIDGE);
    }

    function _assertL2ShutdownState() internal {
        vm.selectFork(baseFork);
        _assertBaseLegacyBridgeShutdown();

        vm.selectFork(optimismFork);
        _assertOptimismLegacyBridgeShutdown();

        vm.selectFork(arbitrumFork);
        _assertArbitrumLegacyBridgeShutdown();
    }

    function _assertMainnetLegacyBridgeShutdown(address bridge) internal {
        _assertLegacyRoutesDisabled(
            bridge, _array3(BASE_CHAIN_SELECTOR, OPTIMISM_CHAIN_SELECTOR, ARBITRUM_CHAIN_SELECTOR)
        );
        _assertLegacySenderDisabled(bridge, BASE_PROGRAMMABLE_BRIDGE, BASE_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(bridge, OP_PROGRAMMABLE_BRIDGE, OPTIMISM_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(bridge, ARB_PROGRAMMABLE_BRIDGE, ARBITRUM_CHAIN_SELECTOR);
    }

    function _assertBaseLegacyBridgeShutdown() internal {
        _assertLegacyRoutesDisabled(
            BASE_PROGRAMMABLE_BRIDGE, _array3(ARBITRUM_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR, OPTIMISM_CHAIN_SELECTOR)
        );
        _assertLegacySenderDisabled(BASE_PROGRAMMABLE_BRIDGE, OLD_MAINNET_PROGRAMMABLE_BRIDGE, MAINNET_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(BASE_PROGRAMMABLE_BRIDGE, NEW_MAINNET_PROGRAMMABLE_BRIDGE, MAINNET_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(BASE_PROGRAMMABLE_BRIDGE, ARB_PROGRAMMABLE_BRIDGE, ARBITRUM_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(BASE_PROGRAMMABLE_BRIDGE, OP_PROGRAMMABLE_BRIDGE, OPTIMISM_CHAIN_SELECTOR);
    }

    function _assertOptimismLegacyBridgeShutdown() internal {
        _assertLegacyRoutesDisabled(
            OP_PROGRAMMABLE_BRIDGE, _array3(ARBITRUM_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR, BASE_CHAIN_SELECTOR)
        );
        _assertLegacySenderDisabled(OP_PROGRAMMABLE_BRIDGE, OLD_MAINNET_PROGRAMMABLE_BRIDGE, MAINNET_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(OP_PROGRAMMABLE_BRIDGE, NEW_MAINNET_PROGRAMMABLE_BRIDGE, MAINNET_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(OP_PROGRAMMABLE_BRIDGE, ARB_PROGRAMMABLE_BRIDGE, ARBITRUM_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(OP_PROGRAMMABLE_BRIDGE, BASE_PROGRAMMABLE_BRIDGE, BASE_CHAIN_SELECTOR);
    }

    function _assertArbitrumLegacyBridgeShutdown() internal {
        _assertLegacyRoutesDisabled(
            ARB_PROGRAMMABLE_BRIDGE, _array3(OPTIMISM_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR, BASE_CHAIN_SELECTOR)
        );
        _assertLegacySenderDisabled(ARB_PROGRAMMABLE_BRIDGE, OLD_MAINNET_PROGRAMMABLE_BRIDGE, MAINNET_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(ARB_PROGRAMMABLE_BRIDGE, NEW_MAINNET_PROGRAMMABLE_BRIDGE, MAINNET_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(ARB_PROGRAMMABLE_BRIDGE, OP_PROGRAMMABLE_BRIDGE, OPTIMISM_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(ARB_PROGRAMMABLE_BRIDGE, BASE_PROGRAMMABLE_BRIDGE, BASE_CHAIN_SELECTOR);
    }

    function _assertLegacyRoutesDisabled(address bridge, uint64[] memory remoteSelectors) internal {
        for (uint256 i; i < remoteSelectors.length; ++i) {
            assertFalse(ISINVShutdownProgrammableBridge(bridge).allowlistedDestinationChains(remoteSelectors[i]));
            assertFalse(ISINVShutdownProgrammableBridge(bridge).allowlistedSourceChains(remoteSelectors[i]));
        }
    }

    function _assertLegacySenderDisabled(address bridge, address sender, uint64 sourceChainSelector) internal {
        assertFalse(ISINVShutdownProgrammableBridge(bridge).allowlistedSenders(sourceChainSelector, sender));
    }

    function _assertHasCode(address target, string memory errorMessage) internal {
        assertGt(target.code.length, 0, errorMessage);
    }

    function _governanceProxyFor(uint64 chainSelector) internal pure returns (address) {
        if (chainSelector == BASE_CHAIN_SELECTOR) return BASE_GOVERNANCE_PROXY;
        if (chainSelector == OPTIMISM_CHAIN_SELECTOR) return OPTIMISM_GOVERNANCE_PROXY;
        if (chainSelector == ARBITRUM_CHAIN_SELECTOR) return ARBITRUM_GOVERNANCE_PROXY;
        revert("unknown governance proxy");
    }

    function _routerFor(uint64 chainSelector) internal pure returns (address) {
        if (chainSelector == BASE_CHAIN_SELECTOR) return BASE_ROUTER;
        if (chainSelector == OPTIMISM_CHAIN_SELECTOR) return OPTIMISM_ROUTER;
        if (chainSelector == ARBITRUM_CHAIN_SELECTOR) return ARBITRUM_ROUTER;
        revert("unknown router");
    }

    function _forkFor(uint64 chainSelector) internal view returns (uint256) {
        if (chainSelector == BASE_CHAIN_SELECTOR) return baseFork;
        if (chainSelector == OPTIMISM_CHAIN_SELECTOR) return optimismFork;
        if (chainSelector == ARBITRUM_CHAIN_SELECTOR) return arbitrumFork;
        revert("unknown fork");
    }

    function _array3(uint64 a, uint64 b, uint64 c) internal pure returns (uint64[] memory values) {
        values = new uint64[](3);
        values[0] = a;
        values[1] = b;
        values[2] = c;
    }
}
