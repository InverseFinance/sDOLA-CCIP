// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test, Vm} from "forge-std/Test.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {
    BridgeShutdownChainUpdate,
    BridgeShutdownGovernor,
    IBridgeShutdownProgrammableBridge,
    IBridgeShutdownTokenPool
} from "src/BridgeShutdownGovernor.sol";
import {GovernanceSender} from "src/GovernanceSender.sol";
import {BridgeShutdownScript} from "script/BridgeShutdown.s.sol";

interface IShutdownGovernanceProxy {
    function allowedSender() external view returns (address);
    function allowedSourceChain() external view returns (uint64);
    function getRouter() external view returns (address);
    function ccipReceive(Client.Any2EVMMessage calldata message) external;
}

interface IShutdownOwnable {
    function owner() external view returns (address);
}

interface IShutdownTokenPool {
    function owner() external view returns (address);
    function getSupportedChains() external view returns (uint64[] memory);
    function transferOwnership(address to) external;
}

interface IShutdownReceiptToken {
    function owner() external view returns (address);
    function mint(address to, uint256 amount) external;
    function setPendingOwner(address newPendingOwner) external;
}

interface IShutdownLegacyBridge {
    function owner() external view returns (address);
    function transferOwnership(address to) external;
    function allowlistedDestinationChains(uint64 destinationChainSelector) external view returns (bool);
    function allowlistedSourceChains(uint64 sourceChainSelector) external view returns (bool);
    function allowlistedSenders(uint64 sourceChainSelector, address sender) external view returns (bool);
}

contract RecordingRouter is IRouterClient {
    uint256 public constant FIXED_FEE = 0.001 ether;

    bytes32 internal constant SENDS_SLOT = bytes32(uint256(keccak256("inverse.bridge.shutdown.test.router.sends")) - 1);

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

contract BridgeShutdownScriptHarness is BridgeShutdownScript {
    function buildMainnetShutdownCallsForFork() external returns (ShutdownCall[] memory calls) {
        BridgeShutdownGovernor shutdownPlan = new BridgeShutdownGovernor(address(this));

        uint64[] memory mainnetRemovals = new uint64[](4);
        mainnetRemovals[0] = shutdownPlan.BASE_CHAIN_SELECTOR();
        mainnetRemovals[1] = shutdownPlan.OPTIMISM_CHAIN_SELECTOR();
        mainnetRemovals[2] = shutdownPlan.ARBITRUM_CHAIN_SELECTOR();
        mainnetRemovals[3] = shutdownPlan.BERACHAIN_CHAIN_SELECTOR();

        calls = new ShutdownCall[](shutdownPlan.MAINNET_SHUTDOWN_CALL_COUNT());
        uint256 count;
        BridgeShutdownChainUpdate[] memory noChainAdds = new BridgeShutdownChainUpdate[](0);

        calls[count++] = ShutdownCall({
            target: shutdownPlan.MAINNET_TOKEN_POOL(),
            callData: abi.encodeWithSelector(
                IBridgeShutdownTokenPool.applyChainUpdates.selector, mainnetRemovals, noChainAdds
            )
        });
        count = _appendMainnetLegacyBridgeShutdown(
            shutdownPlan, calls, count, shutdownPlan.OLD_MAINNET_PROGRAMMABLE_BRIDGE()
        );
        count = _appendMainnetLegacyBridgeShutdown(
            shutdownPlan, calls, count, shutdownPlan.NEW_MAINNET_PROGRAMMABLE_BRIDGE()
        );

        assert(count == calls.length);
    }
}

contract BridgeShutdownGovernorForkTest is Test {
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
    uint256 internal constant BERACHAIN_FORK_BLOCK = 12_025_498;

    address internal constant GOVERNANCE_SENDER_ADDRESS = 0x4e521Fe7A9084067096d45A312B8FEeE39D5F1f3;

    address internal constant MAINNET_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    address internal constant BASE_ROUTER = 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD;
    address internal constant OPTIMISM_ROUTER = 0x3206695CaE29952f4b0c22a169725a865bc8Ce0f;
    address internal constant ARBITRUM_ROUTER = 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8;
    address internal constant BERACHAIN_ROUTER = 0x71a275704c283486fBa26dad3dd0DB78804426eF;

    uint64 internal constant MAINNET_CHAIN_SELECTOR = 5009297550715157269;
    uint64 internal constant BASE_CHAIN_SELECTOR = 15971525489660198786;
    uint64 internal constant OPTIMISM_CHAIN_SELECTOR = 3734403246176062136;
    uint64 internal constant ARBITRUM_CHAIN_SELECTOR = 4949039107694359620;
    uint64 internal constant BERACHAIN_CHAIN_SELECTOR = 1294465214383781161;

    address internal constant BASE_GOVERNANCE_PROXY = 0x1C064265E053D23d120c518fDBB542e6537f82d1;
    address internal constant OPTIMISM_GOVERNANCE_PROXY = 0xaF956837AF704D825c1FCbE2651D5c3c37AD5289;
    address internal constant ARBITRUM_GOVERNANCE_PROXY = 0x607bCd974bB69C78eCdbf0B68748B791bBa24d94;
    address internal constant BERACHAIN_GOVERNANCE_PROXY = 0x1992AF61FBf8ee38741bcc57d636CAA22A1a7702;

    address internal constant MAINNET_TOKEN_POOL = 0x05eEe76f456C51Be0459EC1c0a78bf177B2c877C;
    address internal constant BASE_TOKEN_POOL = 0xd84e1B7e1a7A8D49167884855c3985ef4bCa45aB;
    address internal constant OPTIMISM_TOKEN_POOL = 0x8404024d8F74Ad2D20E82c184816B64D4184A018;
    address internal constant ARBITRUM_TOKEN_POOL = 0xbbc28DB61DF26B76D5F7D5Eed17eD4D6C278460e;
    address internal constant BERACHAIN_TOKEN_POOL = 0x8Bbd036d018657E454F679E7C4726F7a8ECE2773;

    address internal constant BASE_TOKEN = 0xCa78ee4544ec5a33Af86F1E786EfC7d3652bf005;
    address internal constant OPTIMISM_TOKEN = 0xfc63C9c8Ba44AE89C01265453Ed4F427C80cBd4E;
    address internal constant ARBITRUM_TOKEN = 0x7a1e123e41458aabaB8068BFed6010D8f9480898;
    address internal constant BERACHAIN_TOKEN = 0x02eaa69646183c069FC2B64F15923F27B9CF3b03;

    address internal constant OLD_MAINNET_PROGRAMMABLE_BRIDGE = 0x7A43C13f7Fb3A0bF19cEB3fBC583A0CAda6D29a2;
    address internal constant NEW_MAINNET_PROGRAMMABLE_BRIDGE = 0x70F3795c1EF726c58FfeA2e1A51526ac5707C066;
    address internal constant BASE_PROGRAMMABLE_BRIDGE = 0x0173804066F7403E0815680F3DDa125a6cd10F7c;
    address internal constant OP_PROGRAMMABLE_BRIDGE = 0xb5A998E90AdeD2C97f7ceDbb7c45Bbc27E82dfdD;
    address internal constant ARB_PROGRAMMABLE_BRIDGE = 0x0173804066F7403E0815680F3DDa125a6cd10F7c;

    uint256 internal constant L2_SHUTDOWN_MESSAGE_COUNT = 38;
    uint256 internal constant MAINNET_SHUTDOWN_CALL_COUNT = 19;
    uint256 internal constant RECORDING_ROUTER_FIXED_FEE = 0.001 ether;

    bytes32 internal constant CCIP_SEND_RECORDED_TOPIC =
        keccak256("CcipSendRecorded(uint256,uint64,bytes32,bytes,bytes,bytes,address,uint256)");
    bytes32 internal constant MESSAGE_RECEIVED_TOPIC =
        keccak256("MessageReceived(bytes32,uint64,address,address,bool)");

    uint256 internal ethereumFork;
    uint256 internal baseFork;
    uint256 internal optimismFork;
    uint256 internal arbitrumFork;
    uint256 internal berachainFork;

    function setUp() external {
        ethereumFork = vm.createFork("ethereum", ETHEREUM_FORK_BLOCK);
        baseFork = vm.createFork("base", BASE_FORK_BLOCK);
        optimismFork = vm.createFork("optimism", OPTIMISM_FORK_BLOCK);
        arbitrumFork = vm.createFork("arbitrum", ARBITRUM_FORK_BLOCK);
        berachainFork = vm.createFork("berachain", BERACHAIN_FORK_BLOCK);
    }

    function testDeepForkFullShutdownFlow() external {
        _assertPreShutdownState();
        _prepareL2OwnershipForShutdown();
        _assertL2ReadyForShutdownState();

        vm.selectFork(ethereumFork);
        _installRecordingRouter();
        _executeMainnetShutdown();
        _assertMainnetShutdownState();

        GovernanceSender governanceSender = GovernanceSender(payable(GOVERNANCE_SENDER_ADDRESS));
        address shutdownOwner = governanceSender.owner();
        BridgeShutdownGovernor shutdownGovernor = new BridgeShutdownGovernor(shutdownOwner);

        vm.prank(shutdownOwner);
        governanceSender.transferOwnership(address(shutdownGovernor));

        vm.prank(shutdownOwner);
        shutdownGovernor.acceptGovernanceSenderOwnership();

        assertEq(governanceSender.owner(), address(shutdownGovernor));
        assertTrue(governanceSender.allowListedCallers(address(shutdownGovernor)));

        uint256 feeBudget = L2_SHUTDOWN_MESSAGE_COUNT * RECORDING_ROUTER_FIXED_FEE;
        uint256 senderBalanceBefore = address(governanceSender).balance;
        vm.deal(shutdownOwner, feeBudget);

        vm.recordLogs();
        vm.prank(shutdownOwner);
        bytes32[] memory messageIds = shutdownGovernor.executeL2Shutdown{value: feeBudget}();
        RecordedMessage[] memory messages = _recordedMessagesFromLogs(vm.getRecordedLogs());

        assertEq(messageIds.length, L2_SHUTDOWN_MESSAGE_COUNT);
        assertEq(messages.length, L2_SHUTDOWN_MESSAGE_COUNT);
        assertEq(RecordingRouter(MAINNET_ROUTER).sends(), L2_SHUTDOWN_MESSAGE_COUNT);
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
    }

    function _assertPreShutdownState() internal {
        vm.selectFork(ethereumFork);

        GovernanceSender governanceSender = GovernanceSender(payable(GOVERNANCE_SENDER_ADDRESS));
        _assertHasCode(GOVERNANCE_SENDER_ADDRESS, "missing governance sender");
        assertTrue(governanceSender.owner() != address(0));
        assertEq(governanceSender.governanceProxies(BASE_CHAIN_SELECTOR), BASE_GOVERNANCE_PROXY);
        assertEq(governanceSender.governanceProxies(OPTIMISM_CHAIN_SELECTOR), OPTIMISM_GOVERNANCE_PROXY);
        assertEq(governanceSender.governanceProxies(ARBITRUM_CHAIN_SELECTOR), ARBITRUM_GOVERNANCE_PROXY);
        assertEq(governanceSender.governanceProxies(BERACHAIN_CHAIN_SELECTOR), BERACHAIN_GOVERNANCE_PROXY);

        _assertHasCode(MAINNET_TOKEN_POOL, "missing mainnet token pool");
        assertTrue(IShutdownTokenPool(MAINNET_TOKEN_POOL).owner() != address(0));
        _assertSupportedChainSet(
            MAINNET_TOKEN_POOL,
            _array4(BASE_CHAIN_SELECTOR, OPTIMISM_CHAIN_SELECTOR, ARBITRUM_CHAIN_SELECTOR, BERACHAIN_CHAIN_SELECTOR)
        );
        _assertLegacyBridgeHasOwnerIfDeployed(OLD_MAINNET_PROGRAMMABLE_BRIDGE);
        _assertLegacyBridgeHasOwnerIfDeployed(NEW_MAINNET_PROGRAMMABLE_BRIDGE);

        _assertL2PreShutdownState(
            baseFork,
            BASE_GOVERNANCE_PROXY,
            BASE_ROUTER,
            BASE_TOKEN_POOL,
            BASE_TOKEN,
            _array4(ARBITRUM_CHAIN_SELECTOR, OPTIMISM_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR, BERACHAIN_CHAIN_SELECTOR)
        );
        _assertL2PreShutdownState(
            optimismFork,
            OPTIMISM_GOVERNANCE_PROXY,
            OPTIMISM_ROUTER,
            OPTIMISM_TOKEN_POOL,
            OPTIMISM_TOKEN,
            _array3(ARBITRUM_CHAIN_SELECTOR, BASE_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR)
        );
        _assertL2PreShutdownState(
            arbitrumFork,
            ARBITRUM_GOVERNANCE_PROXY,
            ARBITRUM_ROUTER,
            ARBITRUM_TOKEN_POOL,
            ARBITRUM_TOKEN,
            _array4(BASE_CHAIN_SELECTOR, OPTIMISM_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR, BERACHAIN_CHAIN_SELECTOR)
        );
        _assertL2PreShutdownState(
            berachainFork,
            BERACHAIN_GOVERNANCE_PROXY,
            BERACHAIN_ROUTER,
            BERACHAIN_TOKEN_POOL,
            BERACHAIN_TOKEN,
            _array3(ARBITRUM_CHAIN_SELECTOR, BASE_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR)
        );
    }

    function _assertL2PreShutdownState(
        uint256 forkId,
        address governanceProxy,
        address router,
        address tokenPool,
        address token,
        uint64[] memory expectedSupportedChains
    ) internal {
        vm.selectFork(forkId);

        _assertHasCode(governanceProxy, "missing governance proxy");
        assertEq(IShutdownGovernanceProxy(governanceProxy).getRouter(), router);
        assertEq(IShutdownGovernanceProxy(governanceProxy).allowedSender(), GOVERNANCE_SENDER_ADDRESS);
        assertEq(IShutdownGovernanceProxy(governanceProxy).allowedSourceChain(), MAINNET_CHAIN_SELECTOR);

        _assertHasCode(tokenPool, "missing l2 token pool");
        _assertHasCode(token, "missing l2 token");
        _assertSupportedChainSet(tokenPool, expectedSupportedChains);
        _assertCanMintZero(token, tokenPool);
    }

    function _prepareL2OwnershipForShutdown() internal {
        _prepareL2OwnershipForShutdown(
            baseFork, BASE_GOVERNANCE_PROXY, BASE_ROUTER, BASE_TOKEN, BASE_TOKEN_POOL, BASE_PROGRAMMABLE_BRIDGE
        );
        _prepareL2OwnershipForShutdown(
            optimismFork,
            OPTIMISM_GOVERNANCE_PROXY,
            OPTIMISM_ROUTER,
            OPTIMISM_TOKEN,
            OPTIMISM_TOKEN_POOL,
            OP_PROGRAMMABLE_BRIDGE
        );
        _prepareL2OwnershipForShutdown(
            arbitrumFork,
            ARBITRUM_GOVERNANCE_PROXY,
            ARBITRUM_ROUTER,
            ARBITRUM_TOKEN,
            ARBITRUM_TOKEN_POOL,
            ARB_PROGRAMMABLE_BRIDGE
        );
        _prepareL2OwnershipForShutdown(
            berachainFork,
            BERACHAIN_GOVERNANCE_PROXY,
            BERACHAIN_ROUTER,
            BERACHAIN_TOKEN,
            BERACHAIN_TOKEN_POOL,
            address(0)
        );
    }

    function _prepareL2OwnershipForShutdown(
        uint256 forkId,
        address governanceProxy,
        address router,
        address token,
        address tokenPool,
        address legacyBridge
    ) internal {
        vm.selectFork(forkId);

        if (IShutdownReceiptToken(token).owner() != governanceProxy) {
            vm.prank(IShutdownReceiptToken(token).owner());
            IShutdownReceiptToken(token).setPendingOwner(governanceProxy);
            _deliverGovernanceCall(
                governanceProxy,
                router,
                token,
                abi.encodeWithSignature("acceptOwner()"),
                keccak256(abi.encode("accept-token-owner", token))
            );
        }

        if (IShutdownTokenPool(tokenPool).owner() != governanceProxy) {
            vm.prank(IShutdownTokenPool(tokenPool).owner());
            IShutdownTokenPool(tokenPool).transferOwnership(governanceProxy);
            _deliverGovernanceCall(
                governanceProxy,
                router,
                tokenPool,
                abi.encodeWithSignature("acceptOwnership()"),
                keccak256(abi.encode("accept-token-pool-owner", tokenPool))
            );
        }

        if (legacyBridge != address(0) && legacyBridge.code.length != 0) {
            if (IShutdownLegacyBridge(legacyBridge).owner() != governanceProxy) {
                vm.prank(IShutdownLegacyBridge(legacyBridge).owner());
                IShutdownLegacyBridge(legacyBridge).transferOwnership(governanceProxy);
                _deliverGovernanceCall(
                    governanceProxy,
                    router,
                    legacyBridge,
                    abi.encodeWithSignature("acceptOwnership()"),
                    keccak256(abi.encode("accept-legacy-bridge-owner", legacyBridge))
                );
            }
        }
    }

    function _assertL2ReadyForShutdownState() internal {
        _assertL2ReadyForShutdownState(
            baseFork, BASE_GOVERNANCE_PROXY, BASE_TOKEN_POOL, BASE_TOKEN, BASE_PROGRAMMABLE_BRIDGE
        );
        _assertL2ReadyForShutdownState(
            optimismFork, OPTIMISM_GOVERNANCE_PROXY, OPTIMISM_TOKEN_POOL, OPTIMISM_TOKEN, OP_PROGRAMMABLE_BRIDGE
        );
        _assertL2ReadyForShutdownState(
            arbitrumFork, ARBITRUM_GOVERNANCE_PROXY, ARBITRUM_TOKEN_POOL, ARBITRUM_TOKEN, ARB_PROGRAMMABLE_BRIDGE
        );
        _assertL2ReadyForShutdownState(
            berachainFork, BERACHAIN_GOVERNANCE_PROXY, BERACHAIN_TOKEN_POOL, BERACHAIN_TOKEN, address(0)
        );
    }

    function _assertL2ReadyForShutdownState(
        uint256 forkId,
        address governanceProxy,
        address tokenPool,
        address token,
        address legacyBridge
    ) internal {
        vm.selectFork(forkId);
        assertEq(IShutdownTokenPool(tokenPool).owner(), governanceProxy);
        assertEq(IShutdownReceiptToken(token).owner(), governanceProxy);
        _assertLegacyBridgeOwnerIfDeployed(legacyBridge, governanceProxy);
    }

    function _installRecordingRouter() internal {
        RecordingRouter implementation = new RecordingRouter();
        vm.etch(MAINNET_ROUTER, address(implementation).code);
    }

    function _executeMainnetShutdown() internal {
        BridgeShutdownScriptHarness harness = new BridgeShutdownScriptHarness();
        BridgeShutdownScript.ShutdownCall[] memory calls = harness.buildMainnetShutdownCallsForFork();

        assertEq(calls.length, MAINNET_SHUTDOWN_CALL_COUNT);

        for (uint256 i; i < calls.length; ++i) {
            if (calls[i].target.code.length == 0) continue;

            vm.prank(IShutdownOwnable(calls[i].target).owner());
            (bool success,) = calls[i].target.call(calls[i].callData);
            if (!success) {
                emit log_named_address("mainnet shutdown target", calls[i].target);
                emit log_bytes(calls[i].callData);
            }
            assertTrue(success, "mainnet shutdown call failed");
        }
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
            IShutdownGovernanceProxy(governanceProxy)
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

    function _deliverGovernanceCall(
        address governanceProxy,
        address router,
        address target,
        bytes memory callData,
        bytes32 messageId
    ) internal {
        vm.recordLogs();
        vm.prank(router);
        IShutdownGovernanceProxy(governanceProxy)
            .ccipReceive(
                Client.Any2EVMMessage({
                messageId: messageId,
                sourceChainSelector: MAINNET_CHAIN_SELECTOR,
                sender: abi.encode(GOVERNANCE_SENDER_ADDRESS),
                data: abi.encode(target, callData),
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
            );

        _assertGovernanceProxyCallSucceeded(vm.getRecordedLogs(), governanceProxy, messageId, target);
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
        _assertNoSupportedChains(MAINNET_TOKEN_POOL);
        _assertMainnetLegacyBridgeShutdown(OLD_MAINNET_PROGRAMMABLE_BRIDGE);
        _assertMainnetLegacyBridgeShutdown(NEW_MAINNET_PROGRAMMABLE_BRIDGE);
    }

    function _assertL2ShutdownState() internal {
        vm.selectFork(baseFork);
        _assertNoSupportedChains(BASE_TOKEN_POOL);
        _assertNotMinter(BASE_TOKEN, BASE_TOKEN_POOL);
        _assertBaseLegacyBridgeShutdown();

        vm.selectFork(optimismFork);
        _assertNoSupportedChains(OPTIMISM_TOKEN_POOL);
        _assertNotMinter(OPTIMISM_TOKEN, OPTIMISM_TOKEN_POOL);
        _assertOptimismLegacyBridgeShutdown();

        vm.selectFork(arbitrumFork);
        _assertNoSupportedChains(ARBITRUM_TOKEN_POOL);
        _assertNotMinter(ARBITRUM_TOKEN, ARBITRUM_TOKEN_POOL);
        _assertArbitrumLegacyBridgeShutdown();

        vm.selectFork(berachainFork);
        _assertNoSupportedChains(BERACHAIN_TOKEN_POOL);
        _assertNotMinter(BERACHAIN_TOKEN, BERACHAIN_TOKEN_POOL);
    }

    function _assertMainnetLegacyBridgeShutdown(address bridge) internal {
        if (bridge.code.length == 0) return;

        _assertLegacyRoutesDisabled(
            bridge, _array3(BASE_CHAIN_SELECTOR, OPTIMISM_CHAIN_SELECTOR, ARBITRUM_CHAIN_SELECTOR)
        );
        _assertLegacySenderDisabled(bridge, BASE_PROGRAMMABLE_BRIDGE, BASE_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(bridge, OP_PROGRAMMABLE_BRIDGE, OPTIMISM_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(bridge, ARB_PROGRAMMABLE_BRIDGE, ARBITRUM_CHAIN_SELECTOR);
    }

    function _assertBaseLegacyBridgeShutdown() internal {
        address bridge = BASE_PROGRAMMABLE_BRIDGE;
        if (bridge.code.length == 0) return;

        _assertLegacyRoutesDisabled(
            bridge, _array3(ARBITRUM_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR, OPTIMISM_CHAIN_SELECTOR)
        );
        _assertLegacySenderDisabled(bridge, OLD_MAINNET_PROGRAMMABLE_BRIDGE, MAINNET_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(bridge, NEW_MAINNET_PROGRAMMABLE_BRIDGE, MAINNET_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(bridge, ARB_PROGRAMMABLE_BRIDGE, ARBITRUM_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(bridge, OP_PROGRAMMABLE_BRIDGE, OPTIMISM_CHAIN_SELECTOR);
    }

    function _assertOptimismLegacyBridgeShutdown() internal {
        address bridge = OP_PROGRAMMABLE_BRIDGE;
        if (bridge.code.length == 0) return;

        _assertLegacyRoutesDisabled(
            bridge, _array3(ARBITRUM_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR, BASE_CHAIN_SELECTOR)
        );
        _assertLegacySenderDisabled(bridge, OLD_MAINNET_PROGRAMMABLE_BRIDGE, MAINNET_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(bridge, NEW_MAINNET_PROGRAMMABLE_BRIDGE, MAINNET_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(bridge, ARB_PROGRAMMABLE_BRIDGE, ARBITRUM_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(bridge, BASE_PROGRAMMABLE_BRIDGE, BASE_CHAIN_SELECTOR);
    }

    function _assertArbitrumLegacyBridgeShutdown() internal {
        address bridge = ARB_PROGRAMMABLE_BRIDGE;
        if (bridge.code.length == 0) return;

        _assertLegacyRoutesDisabled(
            bridge, _array3(OPTIMISM_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR, BASE_CHAIN_SELECTOR)
        );
        _assertLegacySenderDisabled(bridge, OLD_MAINNET_PROGRAMMABLE_BRIDGE, MAINNET_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(bridge, NEW_MAINNET_PROGRAMMABLE_BRIDGE, MAINNET_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(bridge, OP_PROGRAMMABLE_BRIDGE, OPTIMISM_CHAIN_SELECTOR);
        _assertLegacySenderDisabled(bridge, BASE_PROGRAMMABLE_BRIDGE, BASE_CHAIN_SELECTOR);
    }

    function _assertLegacyRoutesDisabled(address bridge, uint64[] memory remoteSelectors) internal {
        for (uint256 i; i < remoteSelectors.length; ++i) {
            assertFalse(IShutdownLegacyBridge(bridge).allowlistedDestinationChains(remoteSelectors[i]));
            assertFalse(IShutdownLegacyBridge(bridge).allowlistedSourceChains(remoteSelectors[i]));
        }
    }

    function _assertLegacySenderDisabled(address bridge, address sender, uint64 sourceChainSelector) internal {
        assertFalse(IShutdownLegacyBridge(bridge).allowlistedSenders(sourceChainSelector, sender));
    }

    function _assertSupportedChainSet(address tokenPool, uint64[] memory expected) internal {
        uint64[] memory actual = IShutdownTokenPool(tokenPool).getSupportedChains();
        assertEq(actual.length, expected.length);

        for (uint256 i; i < expected.length; ++i) {
            assertTrue(_contains(actual, expected[i]), "missing supported chain");
        }
    }

    function _assertNoSupportedChains(address tokenPool) internal {
        assertEq(IShutdownTokenPool(tokenPool).getSupportedChains().length, 0);
    }

    function _assertCanMintZero(address token, address minter) internal {
        vm.prank(minter);
        IShutdownReceiptToken(token).mint(address(0xBEEF), 0);
    }

    function _assertNotMinter(address token, address minter) internal {
        vm.prank(minter);
        vm.expectRevert(bytes("msg.sender not minter"));
        IShutdownReceiptToken(token).mint(address(0xBEEF), 0);
    }

    function _assertLegacyBridgeOwnerIfDeployed(address bridge, address expectedOwner) internal {
        if (bridge == address(0) || bridge.code.length == 0) return;
        assertEq(IShutdownLegacyBridge(bridge).owner(), expectedOwner);
    }

    function _assertLegacyBridgeHasOwnerIfDeployed(address bridge) internal {
        if (bridge == address(0) || bridge.code.length == 0) return;
        assertTrue(IShutdownLegacyBridge(bridge).owner() != address(0));
    }

    function _assertHasCode(address target, string memory errorMessage) internal {
        assertGt(target.code.length, 0, errorMessage);
    }

    function _contains(uint64[] memory values, uint64 needle) internal pure returns (bool) {
        for (uint256 i; i < values.length; ++i) {
            if (values[i] == needle) return true;
        }
        return false;
    }

    function _governanceProxyFor(uint64 chainSelector) internal pure returns (address) {
        if (chainSelector == BASE_CHAIN_SELECTOR) return BASE_GOVERNANCE_PROXY;
        if (chainSelector == OPTIMISM_CHAIN_SELECTOR) return OPTIMISM_GOVERNANCE_PROXY;
        if (chainSelector == ARBITRUM_CHAIN_SELECTOR) return ARBITRUM_GOVERNANCE_PROXY;
        if (chainSelector == BERACHAIN_CHAIN_SELECTOR) return BERACHAIN_GOVERNANCE_PROXY;
        revert("unknown governance proxy");
    }

    function _routerFor(uint64 chainSelector) internal pure returns (address) {
        if (chainSelector == BASE_CHAIN_SELECTOR) return BASE_ROUTER;
        if (chainSelector == OPTIMISM_CHAIN_SELECTOR) return OPTIMISM_ROUTER;
        if (chainSelector == ARBITRUM_CHAIN_SELECTOR) return ARBITRUM_ROUTER;
        if (chainSelector == BERACHAIN_CHAIN_SELECTOR) return BERACHAIN_ROUTER;
        revert("unknown router");
    }

    function _forkFor(uint64 chainSelector) internal view returns (uint256) {
        if (chainSelector == BASE_CHAIN_SELECTOR) return baseFork;
        if (chainSelector == OPTIMISM_CHAIN_SELECTOR) return optimismFork;
        if (chainSelector == ARBITRUM_CHAIN_SELECTOR) return arbitrumFork;
        if (chainSelector == BERACHAIN_CHAIN_SELECTOR) return berachainFork;
        revert("unknown fork");
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
