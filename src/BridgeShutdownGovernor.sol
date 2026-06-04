// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ConfirmedOwner} from "@chainlink/contracts-ccip/src/v0.8/shared/access/ConfirmedOwner.sol";
import {GovernanceSender} from "src/GovernanceSender.sol";

struct BridgeShutdownRateLimiterConfig {
    bool isEnabled;
    uint128 capacity;
    uint128 rate;
}

struct BridgeShutdownChainUpdate {
    uint64 remoteChainSelector;
    bytes[] remotePoolAddresses;
    bytes remoteTokenAddress;
    BridgeShutdownRateLimiterConfig outboundRateLimiterConfig;
    BridgeShutdownRateLimiterConfig inboundRateLimiterConfig;
}

interface IBridgeShutdownTokenPool {
    function applyChainUpdates(
        uint64[] calldata remoteChainSelectorsToRemove,
        BridgeShutdownChainUpdate[] calldata chainsToAdd
    ) external;
}

interface IBridgeShutdownMintable {
    function setMinter(address minter, bool isMinter) external;
}

interface IBridgeShutdownProgrammableBridge {
    function allowlistDestinationChain(uint64 destinationChainSelector, bool allowed) external;
    function allowlistSourceChain(uint64 sourceChainSelector, bool allowed) external;
    function allowlistSender(address sender, uint64 sourceChainSelector, bool allowed) external;
}

/// @notice L1 owner of GovernanceSender used to send bridge wind-down messages.
contract BridgeShutdownGovernor is ConfirmedOwner {
    struct ShutdownMessage {
        uint64 destinationChainSelector;
        address target;
        bytes callData;
        uint256 gasLimit;
    }

    struct ShutdownCall {
        address target;
        bytes callData;
    }

    struct TokenPoolRemovals {
        uint64[] baseRemovals;
        uint64[] optimismRemovals;
        uint64[] arbitrumRemovals;
        uint64[] berachainRemovals;
    }

    error InvalidAddress();
    error InvalidTarget();
    error InvalidCallData();
    error InvalidGasLimit();
    error EthTransferFailed(address target, uint256 amount);
    error UnknownChainSelector(uint64 chainSelector);

    event GovernanceSenderFunded(uint256 amount);
    event GovernanceSenderAllowlisted(address caller);
    event GovernanceProxySet(uint64 indexed destinationChainSelector, address indexed governanceProxy);
    event ShutdownMessageSent(
        bytes32 indexed messageId, uint64 indexed destinationChainSelector, address indexed target, uint256 gasLimit
    );
    event GovernanceSenderOwnershipTransferRequested(address indexed newOwner);
    event EthWithdrawn(address indexed beneficiary, uint256 amount);

    uint256 public constant TOKEN_POOL_GAS_LIMIT = 600_000;
    uint256 public constant SET_MINTER_GAS_LIMIT = 250_000;
    uint256 public constant LEGACY_BRIDGE_GAS_LIMIT = 250_000;
    uint256 public constant L2_SHUTDOWN_MESSAGE_COUNT = 38;
    uint256 public constant MAINNET_LEGACY_BRIDGE_CALL_COUNT = 9;
    uint256 public constant MAINNET_SHUTDOWN_CALL_COUNT = 19;

    uint64 public constant MAINNET_CHAIN_SELECTOR = 5009297550715157269;
    uint64 public constant BASE_CHAIN_SELECTOR = 15971525489660198786;
    uint64 public constant OPTIMISM_CHAIN_SELECTOR = 3734403246176062136;
    uint64 public constant ARBITRUM_CHAIN_SELECTOR = 4949039107694359620;
    uint64 public constant BERACHAIN_CHAIN_SELECTOR = 1294465214383781161;

    address public constant BASE_GOVERNANCE_PROXY = 0x1C064265E053D23d120c518fDBB542e6537f82d1;
    address public constant OPTIMISM_GOVERNANCE_PROXY = 0xaF956837AF704D825c1FCbE2651D5c3c37AD5289;
    address public constant ARBITRUM_GOVERNANCE_PROXY = 0x607bCd974bB69C78eCdbf0B68748B791bBa24d94;
    address public constant BERACHAIN_GOVERNANCE_PROXY = 0x1992AF61FBf8ee38741bcc57d636CAA22A1a7702;

    address public constant MAINNET_TOKEN_POOL = 0x05eEe76f456C51Be0459EC1c0a78bf177B2c877C;
    address public constant BASE_TOKEN_POOL = 0xd84e1B7e1a7A8D49167884855c3985ef4bCa45aB;
    address public constant OPTIMISM_TOKEN_POOL = 0x8404024d8F74Ad2D20E82c184816B64D4184A018;
    address public constant ARBITRUM_TOKEN_POOL = 0xbbc28DB61DF26B76D5F7D5Eed17eD4D6C278460e;
    address public constant BERACHAIN_TOKEN_POOL = 0x8Bbd036d018657E454F679E7C4726F7a8ECE2773;

    address public constant BASE_TOKEN = 0xCa78ee4544ec5a33Af86F1E786EfC7d3652bf005;
    address public constant OPTIMISM_TOKEN = 0xfc63C9c8Ba44AE89C01265453Ed4F427C80cBd4E;
    address public constant ARBITRUM_TOKEN = 0x7a1e123e41458aabaB8068BFed6010D8f9480898;
    address public constant BERACHAIN_TOKEN = 0x02eaa69646183c069FC2B64F15923F27B9CF3b03;

    address public constant OLD_MAINNET_PROGRAMMABLE_BRIDGE = 0x7A43C13f7Fb3A0bF19cEB3fBC583A0CAda6D29a2;
    address public constant NEW_MAINNET_PROGRAMMABLE_BRIDGE = 0x70F3795c1EF726c58FfeA2e1A51526ac5707C066;
    address public constant BASE_PROGRAMMABLE_BRIDGE = 0x0173804066F7403E0815680F3DDa125a6cd10F7c;
    address public constant OP_PROGRAMMABLE_BRIDGE = 0xb5A998E90AdeD2C97f7ceDbb7c45Bbc27E82dfdD;
    address public constant ARB_PROGRAMMABLE_BRIDGE = 0x0173804066F7403E0815680F3DDa125a6cd10F7c;

    GovernanceSender private immutable GOVERNANCE_SENDER;

    constructor(address owner_, address governanceSender_) ConfirmedOwner(owner_) {
        if (governanceSender_ == address(0)) revert InvalidAddress();
        GOVERNANCE_SENDER = GovernanceSender(payable(governanceSender_));
    }

    receive() external payable {}

    function governanceSender() external view returns (GovernanceSender) {
        return GOVERNANCE_SENDER;
    }

    /// @notice Accepts GovernanceSender ownership and allowlists this contract to send messages.
    function acceptGovernanceSenderOwnership() external onlyOwner {
        GOVERNANCE_SENDER.acceptOwnership();
        GOVERNANCE_SENDER.allowlistCaller(address(this), true);
        emit GovernanceSenderAllowlisted(address(this));
    }

    /// @notice Sets the known destination GovernanceProxy addresses used by the bridge shutdown.
    function setShutdownGovernanceProxies() external onlyOwner {
        _setGovernanceProxy(BASE_CHAIN_SELECTOR, BASE_GOVERNANCE_PROXY);
        _setGovernanceProxy(OPTIMISM_CHAIN_SELECTOR, OPTIMISM_GOVERNANCE_PROXY);
        _setGovernanceProxy(ARBITRUM_CHAIN_SELECTOR, ARBITRUM_GOVERNANCE_PROXY);
        _setGovernanceProxy(BERACHAIN_CHAIN_SELECTOR, BERACHAIN_GOVERNANCE_PROXY);
    }

    /// @notice Builds the fixed L2 bridge shutdown message batch.
    /// @dev Token pool removals are supplied by the caller because this L1 contract cannot read L2 pool state.
    function buildL2ShutdownMessages(TokenPoolRemovals calldata tokenPoolRemovals)
        external
        pure
        returns (ShutdownMessage[] memory messages)
    {
        return _buildL2ShutdownMessages(tokenPoolRemovals);
    }

    /// @notice Builds the fixed mainnet shutdown calls from the bridge shutdown script.
    /// @dev These calls only succeed from the owner of the mainnet token pool and legacy bridge targets.
    function buildMainnetShutdownCalls(uint64[] calldata mainnetTokenPoolRemovals)
        external
        pure
        returns (ShutdownCall[] memory calls)
    {
        calls = new ShutdownCall[](MAINNET_SHUTDOWN_CALL_COUNT);
        uint256 count;

        calls[count++] =
            ShutdownCall({target: MAINNET_TOKEN_POOL, callData: _tokenPoolShutdownCallData(mainnetTokenPoolRemovals)});
        count = _appendMainnetLegacyBridgeShutdown(calls, count, OLD_MAINNET_PROGRAMMABLE_BRIDGE);
        count = _appendMainnetLegacyBridgeShutdown(calls, count, NEW_MAINNET_PROGRAMMABLE_BRIDGE);

        assert(count == MAINNET_SHUTDOWN_CALL_COUNT);
    }

    /// @notice Builds the mainnet legacy bridge shutdown calls for a specific bridge target.
    function buildMainnetLegacyBridgeShutdownCalls(address bridge) external pure returns (ShutdownCall[] memory calls) {
        if (bridge == address(0)) revert InvalidTarget();

        calls = new ShutdownCall[](MAINNET_LEGACY_BRIDGE_CALL_COUNT);
        uint256 count = _appendMainnetLegacyBridgeShutdown(calls, 0, bridge);
        assert(count == MAINNET_LEGACY_BRIDGE_CALL_COUNT);
    }

    /// @notice Sends the fixed L2 bridge shutdown message batch through GovernanceSender.
    /// @dev Token pool removals are supplied by the caller because this L1 contract cannot read L2 pool state.
    function executeL2Shutdown(TokenPoolRemovals calldata tokenPoolRemovals)
        external
        payable
        onlyOwner
        returns (bytes32[] memory messageIds)
    {
        _fundGovernanceSender(msg.value);

        ShutdownMessage[] memory messages = _buildL2ShutdownMessages(tokenPoolRemovals);
        uint256 length = messages.length;
        messageIds = new bytes32[](length);
        for (uint256 i; i < length; ++i) {
            ShutdownMessage memory shutdownMessage = messages[i];
            bytes32 messageId = _sendShutdownMessage(
                shutdownMessage.destinationChainSelector,
                shutdownMessage.target,
                shutdownMessage.callData,
                shutdownMessage.gasLimit
            );
            messageIds[i] = messageId;

            emit ShutdownMessageSent(
                messageId, shutdownMessage.destinationChainSelector, shutdownMessage.target, shutdownMessage.gasLimit
            );
        }
    }

    function governanceProxyFor(uint64 chainSelector) external pure returns (address) {
        return _governanceProxyFor(chainSelector);
    }

    function legacyBridgeFor(uint64 chainSelector) external pure returns (address) {
        return _legacyBridgeFor(chainSelector);
    }

    function legacyRemoteSelectors(uint64 localSelector) external pure returns (uint64[3] memory) {
        return _legacyRemoteSelectors(localSelector);
    }

    function legacySenderSelectors(uint64 localSelector) external pure returns (uint64[4] memory) {
        return _legacySenderSelectors(localSelector);
    }

    function legacyRemoteSenders(uint64 localSelector) external pure returns (address[4] memory) {
        return _legacyRemoteSenders(localSelector);
    }

    /// @notice Withdraws ETH held by this contract and by GovernanceSender.
    function withdraw(address payable beneficiary) external onlyOwner {
        if (beneficiary == address(0)) revert InvalidAddress();

        if (address(GOVERNANCE_SENDER).balance > 0) {
            GOVERNANCE_SENDER.withdraw(beneficiary);
        }

        uint256 amount = address(this).balance;
        if (amount > 0) {
            _sendEth(beneficiary, amount);
            emit EthWithdrawn(beneficiary, amount);
        }
    }

    /// @notice Starts transferring GovernanceSender ownership to a new owner.
    function transferGovernanceSenderOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        GOVERNANCE_SENDER.transferOwnership(newOwner);
        GOVERNANCE_SENDER.allowlistCaller(address(this), false);
        emit GovernanceSenderOwnershipTransferRequested(newOwner);
    }

    function _buildL2ShutdownMessages(TokenPoolRemovals calldata tokenPoolRemovals)
        internal
        pure
        returns (ShutdownMessage[] memory messages)
    {
        messages = new ShutdownMessage[](L2_SHUTDOWN_MESSAGE_COUNT);
        uint256 count;

        count = _appendTokenPoolShutdown(
            messages, count, BASE_CHAIN_SELECTOR, BASE_TOKEN_POOL, tokenPoolRemovals.baseRemovals
        );
        count = _appendTokenPoolShutdown(
            messages, count, OPTIMISM_CHAIN_SELECTOR, OPTIMISM_TOKEN_POOL, tokenPoolRemovals.optimismRemovals
        );
        count = _appendTokenPoolShutdown(
            messages, count, ARBITRUM_CHAIN_SELECTOR, ARBITRUM_TOKEN_POOL, tokenPoolRemovals.arbitrumRemovals
        );
        count = _appendTokenPoolShutdown(
            messages, count, BERACHAIN_CHAIN_SELECTOR, BERACHAIN_TOKEN_POOL, tokenPoolRemovals.berachainRemovals
        );

        count = _appendSetMinter(messages, count, BASE_CHAIN_SELECTOR, BASE_TOKEN, BASE_TOKEN_POOL);
        count = _appendSetMinter(messages, count, OPTIMISM_CHAIN_SELECTOR, OPTIMISM_TOKEN, OPTIMISM_TOKEN_POOL);
        count = _appendSetMinter(messages, count, ARBITRUM_CHAIN_SELECTOR, ARBITRUM_TOKEN, ARBITRUM_TOKEN_POOL);
        count = _appendSetMinter(messages, count, BERACHAIN_CHAIN_SELECTOR, BERACHAIN_TOKEN, BERACHAIN_TOKEN_POOL);

        count = _appendLegacyBridgeShutdown(messages, count, BASE_CHAIN_SELECTOR, BASE_PROGRAMMABLE_BRIDGE);
        count = _appendLegacyBridgeShutdown(messages, count, OPTIMISM_CHAIN_SELECTOR, OP_PROGRAMMABLE_BRIDGE);
        count = _appendLegacyBridgeShutdown(messages, count, ARBITRUM_CHAIN_SELECTOR, ARB_PROGRAMMABLE_BRIDGE);

        assert(count == L2_SHUTDOWN_MESSAGE_COUNT);
    }

    function _appendMainnetLegacyBridgeShutdown(ShutdownCall[] memory buffer, uint256 count, address bridge)
        internal
        pure
        returns (uint256)
    {
        uint64[3] memory remoteSelectors = [BASE_CHAIN_SELECTOR, OPTIMISM_CHAIN_SELECTOR, ARBITRUM_CHAIN_SELECTOR];
        for (uint256 i; i < remoteSelectors.length; ++i) {
            uint64 remoteSelector = remoteSelectors[i];
            buffer[count++] = ShutdownCall({
                target: bridge,
                callData: abi.encodeWithSelector(
                    IBridgeShutdownProgrammableBridge.allowlistDestinationChain.selector, remoteSelector, false
                )
            });
            buffer[count++] = ShutdownCall({
                target: bridge,
                callData: abi.encodeWithSelector(
                    IBridgeShutdownProgrammableBridge.allowlistSourceChain.selector, remoteSelector, false
                )
            });
        }

        buffer[count++] = ShutdownCall({
            target: bridge,
            callData: abi.encodeWithSelector(
                IBridgeShutdownProgrammableBridge.allowlistSender.selector,
                BASE_PROGRAMMABLE_BRIDGE,
                BASE_CHAIN_SELECTOR,
                false
            )
        });
        buffer[count++] = ShutdownCall({
            target: bridge,
            callData: abi.encodeWithSelector(
                IBridgeShutdownProgrammableBridge.allowlistSender.selector,
                OP_PROGRAMMABLE_BRIDGE,
                OPTIMISM_CHAIN_SELECTOR,
                false
            )
        });
        buffer[count++] = ShutdownCall({
            target: bridge,
            callData: abi.encodeWithSelector(
                IBridgeShutdownProgrammableBridge.allowlistSender.selector,
                ARB_PROGRAMMABLE_BRIDGE,
                ARBITRUM_CHAIN_SELECTOR,
                false
            )
        });

        return count;
    }

    function _appendTokenPoolShutdown(
        ShutdownMessage[] memory buffer,
        uint256 count,
        uint64 destinationChainSelector,
        address tokenPool,
        uint64[] calldata removals
    ) internal pure returns (uint256) {
        buffer[count++] = ShutdownMessage({
            destinationChainSelector: destinationChainSelector,
            target: tokenPool,
            callData: _tokenPoolShutdownCallData(removals),
            gasLimit: TOKEN_POOL_GAS_LIMIT
        });

        return count;
    }

    function _appendSetMinter(
        ShutdownMessage[] memory buffer,
        uint256 count,
        uint64 destinationChainSelector,
        address token,
        address tokenPool
    ) internal pure returns (uint256) {
        buffer[count++] = ShutdownMessage({
            destinationChainSelector: destinationChainSelector,
            target: token,
            callData: abi.encodeWithSelector(IBridgeShutdownMintable.setMinter.selector, tokenPool, false),
            gasLimit: SET_MINTER_GAS_LIMIT
        });

        return count;
    }

    function _appendLegacyBridgeShutdown(
        ShutdownMessage[] memory buffer,
        uint256 count,
        uint64 destinationChainSelector,
        address bridge
    ) internal pure returns (uint256) {
        uint64[3] memory remoteSelectors = _legacyRemoteSelectors(destinationChainSelector);
        for (uint256 i; i < remoteSelectors.length; ++i) {
            uint64 remoteSelector = remoteSelectors[i];
            buffer[count++] = _message(
                destinationChainSelector,
                bridge,
                abi.encodeWithSelector(
                    IBridgeShutdownProgrammableBridge.allowlistDestinationChain.selector, remoteSelector, false
                ),
                LEGACY_BRIDGE_GAS_LIMIT
            );
            buffer[count++] = _message(
                destinationChainSelector,
                bridge,
                abi.encodeWithSelector(
                    IBridgeShutdownProgrammableBridge.allowlistSourceChain.selector, remoteSelector, false
                ),
                LEGACY_BRIDGE_GAS_LIMIT
            );
        }

        address[4] memory senders = _legacyRemoteSenders(destinationChainSelector);
        uint64[4] memory senderSelectors = _legacySenderSelectors(destinationChainSelector);
        for (uint256 i; i < senders.length; ++i) {
            buffer[count++] = _message(
                destinationChainSelector,
                bridge,
                abi.encodeWithSelector(
                    IBridgeShutdownProgrammableBridge.allowlistSender.selector, senders[i], senderSelectors[i], false
                ),
                LEGACY_BRIDGE_GAS_LIMIT
            );
        }

        return count;
    }

    function _message(uint64 destinationChainSelector, address target, bytes memory callData, uint256 gasLimit)
        internal
        pure
        returns (ShutdownMessage memory)
    {
        return ShutdownMessage({
            destinationChainSelector: destinationChainSelector, target: target, callData: callData, gasLimit: gasLimit
        });
    }

    function _governanceProxyFor(uint64 chainSelector) internal pure returns (address) {
        if (chainSelector == BASE_CHAIN_SELECTOR) return BASE_GOVERNANCE_PROXY;
        if (chainSelector == OPTIMISM_CHAIN_SELECTOR) return OPTIMISM_GOVERNANCE_PROXY;
        if (chainSelector == ARBITRUM_CHAIN_SELECTOR) return ARBITRUM_GOVERNANCE_PROXY;
        if (chainSelector == BERACHAIN_CHAIN_SELECTOR) return BERACHAIN_GOVERNANCE_PROXY;
        revert UnknownChainSelector(chainSelector);
    }

    function _legacyRemoteSelectors(uint64 localSelector) internal pure returns (uint64[3] memory) {
        if (localSelector == BASE_CHAIN_SELECTOR) {
            return [ARBITRUM_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR, OPTIMISM_CHAIN_SELECTOR];
        }
        if (localSelector == OPTIMISM_CHAIN_SELECTOR) {
            return [ARBITRUM_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR, BASE_CHAIN_SELECTOR];
        }
        if (localSelector == ARBITRUM_CHAIN_SELECTOR) {
            return [OPTIMISM_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR, BASE_CHAIN_SELECTOR];
        }
        revert UnknownChainSelector(localSelector);
    }

    function _legacySenderSelectors(uint64 localSelector) internal pure returns (uint64[4] memory) {
        uint64[3] memory remoteSelectors = _legacyRemoteSelectors(localSelector);
        return [MAINNET_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR, remoteSelectors[0], remoteSelectors[2]];
    }

    function _legacyRemoteSenders(uint64 localSelector) internal pure returns (address[4] memory) {
        uint64[3] memory remoteSelectors = _legacyRemoteSelectors(localSelector);
        return [
            OLD_MAINNET_PROGRAMMABLE_BRIDGE,
            NEW_MAINNET_PROGRAMMABLE_BRIDGE,
            _legacyBridgeFor(remoteSelectors[0]),
            _legacyBridgeFor(remoteSelectors[2])
        ];
    }

    function _legacyBridgeFor(uint64 chainSelector) internal pure returns (address) {
        if (chainSelector == BASE_CHAIN_SELECTOR) return BASE_PROGRAMMABLE_BRIDGE;
        if (chainSelector == OPTIMISM_CHAIN_SELECTOR) return OP_PROGRAMMABLE_BRIDGE;
        if (chainSelector == ARBITRUM_CHAIN_SELECTOR) return ARB_PROGRAMMABLE_BRIDGE;
        revert UnknownChainSelector(chainSelector);
    }

    function _tokenPoolShutdownCallData(uint64[] calldata removals) internal pure returns (bytes memory) {
        BridgeShutdownChainUpdate[] memory noChainAdds = new BridgeShutdownChainUpdate[](0);
        return abi.encodeWithSelector(IBridgeShutdownTokenPool.applyChainUpdates.selector, removals, noChainAdds);
    }

    function _setGovernanceProxy(uint64 destinationChainSelector, address governanceProxy) internal {
        GOVERNANCE_SENDER.allowlistGovernanceProxy(destinationChainSelector, governanceProxy);
        emit GovernanceProxySet(destinationChainSelector, governanceProxy);
    }

    function _fundGovernanceSender(uint256 amount) internal {
        if (amount > 0) {
            _sendEth(payable(address(GOVERNANCE_SENDER)), amount);
            emit GovernanceSenderFunded(amount);
        }
    }

    function _sendShutdownMessage(
        uint64 destinationChainSelector,
        address target,
        bytes memory callData,
        uint256 gasLimit
    ) internal returns (bytes32 messageId) {
        if (target == address(0)) revert InvalidTarget();
        if (callData.length == 0) revert InvalidCallData();
        if (gasLimit == 0) revert InvalidGasLimit();

        messageId = GOVERNANCE_SENDER.sendMessagePayNative(destinationChainSelector, target, callData, gasLimit);
    }

    function _sendEth(address payable target, uint256 amount) internal {
        (bool success,) = target.call{value: amount}("");
        if (!success) revert EthTransferFailed(target, amount);
    }
}
