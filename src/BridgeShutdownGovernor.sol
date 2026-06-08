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
    event ShutdownMessageSent(
        bytes32 indexed messageId, uint64 indexed destinationChainSelector, address indexed target, uint256 gasLimit
    );
    event GovernanceSenderOwnershipTransferRequested(address indexed newOwner);
    event EthWithdrawn(address indexed beneficiary, uint256 amount);

    address public constant GOVERNANCE_SENDER_ADDRESS = 0x4e521Fe7A9084067096d45A312B8FEeE39D5F1f3;

    uint256 public constant TOKEN_POOL_GAS_LIMIT = 600_000;
    uint256 public constant SET_MINTER_GAS_LIMIT = 250_000;
    uint256 public constant LEGACY_BRIDGE_GAS_LIMIT = 250_000;
    uint256 public constant L2_SHUTDOWN_MESSAGE_COUNT = 38;
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

    constructor(address owner_) ConfirmedOwner(owner_) {
        GOVERNANCE_SENDER = GovernanceSender(payable(GOVERNANCE_SENDER_ADDRESS));
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

    /// @notice Sends the fixed L2 bridge shutdown message batch through GovernanceSender.
    function executeL2Shutdown() external payable onlyOwner returns (bytes32[] memory messageIds) {
        // Forward the caller's ETH to GovernanceSender so it can pay CCIP native fees.
        if (msg.value > 0) {
            (bool success,) = payable(address(GOVERNANCE_SENDER)).call{value: msg.value}("");
            if (!success) revert EthTransferFailed(address(GOVERNANCE_SENDER), msg.value);
            emit GovernanceSenderFunded(msg.value);
        }

        ShutdownMessage[] memory messages = _buildL2ShutdownMessages(_hardcodedL2TokenPoolRemovals());
        uint256 length = messages.length;
        messageIds = new bytes32[](length);
        for (uint256 i; i < length; ++i) {
            ShutdownMessage memory shutdownMessage = messages[i];

            if (shutdownMessage.target == address(0)) revert InvalidTarget();
            if (shutdownMessage.callData.length == 0) revert InvalidCallData();
            if (shutdownMessage.gasLimit == 0) revert InvalidGasLimit();

            bytes32 messageId = GOVERNANCE_SENDER.sendMessagePayNative(
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

    /// @notice Withdraws ETH held by this contract and by GovernanceSender.
    function withdraw(address payable beneficiary) external onlyOwner {
        if (beneficiary == address(0)) revert InvalidAddress();

        if (address(GOVERNANCE_SENDER).balance > 0) {
            GOVERNANCE_SENDER.withdraw(beneficiary);
        }

        uint256 amount = address(this).balance;
        if (amount > 0) {
            (bool success,) = beneficiary.call{value: amount}("");
            if (!success) revert EthTransferFailed(beneficiary, amount);
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

    function _buildL2ShutdownMessages(TokenPoolRemovals memory tokenPoolRemovals)
        internal
        pure
        returns (ShutdownMessage[] memory messages)
    {
        messages = new ShutdownMessage[](L2_SHUTDOWN_MESSAGE_COUNT);
        uint256 count;

        BridgeShutdownChainUpdate[] memory noChainAdds = new BridgeShutdownChainUpdate[](0);

        // Remove every known remote chain from each L2 token pool.
        messages[count++] = ShutdownMessage({
            destinationChainSelector: BASE_CHAIN_SELECTOR,
            target: BASE_TOKEN_POOL,
            callData: abi.encodeWithSelector(
                IBridgeShutdownTokenPool.applyChainUpdates.selector, tokenPoolRemovals.baseRemovals, noChainAdds
            ),
            gasLimit: TOKEN_POOL_GAS_LIMIT
        });
        messages[count++] = ShutdownMessage({
            destinationChainSelector: OPTIMISM_CHAIN_SELECTOR,
            target: OPTIMISM_TOKEN_POOL,
            callData: abi.encodeWithSelector(
                IBridgeShutdownTokenPool.applyChainUpdates.selector, tokenPoolRemovals.optimismRemovals, noChainAdds
            ),
            gasLimit: TOKEN_POOL_GAS_LIMIT
        });
        messages[count++] = ShutdownMessage({
            destinationChainSelector: ARBITRUM_CHAIN_SELECTOR,
            target: ARBITRUM_TOKEN_POOL,
            callData: abi.encodeWithSelector(
                IBridgeShutdownTokenPool.applyChainUpdates.selector, tokenPoolRemovals.arbitrumRemovals, noChainAdds
            ),
            gasLimit: TOKEN_POOL_GAS_LIMIT
        });
        messages[count++] = ShutdownMessage({
            destinationChainSelector: BERACHAIN_CHAIN_SELECTOR,
            target: BERACHAIN_TOKEN_POOL,
            callData: abi.encodeWithSelector(
                IBridgeShutdownTokenPool.applyChainUpdates.selector, tokenPoolRemovals.berachainRemovals, noChainAdds
            ),
            gasLimit: TOKEN_POOL_GAS_LIMIT
        });

        // Revoke each L2 token pool's minting permission on its receipt token.
        messages[count++] = ShutdownMessage({
            destinationChainSelector: BASE_CHAIN_SELECTOR,
            target: BASE_TOKEN,
            callData: abi.encodeWithSelector(IBridgeShutdownMintable.setMinter.selector, BASE_TOKEN_POOL, false),
            gasLimit: SET_MINTER_GAS_LIMIT
        });
        messages[count++] = ShutdownMessage({
            destinationChainSelector: OPTIMISM_CHAIN_SELECTOR,
            target: OPTIMISM_TOKEN,
            callData: abi.encodeWithSelector(IBridgeShutdownMintable.setMinter.selector, OPTIMISM_TOKEN_POOL, false),
            gasLimit: SET_MINTER_GAS_LIMIT
        });
        messages[count++] = ShutdownMessage({
            destinationChainSelector: ARBITRUM_CHAIN_SELECTOR,
            target: ARBITRUM_TOKEN,
            callData: abi.encodeWithSelector(IBridgeShutdownMintable.setMinter.selector, ARBITRUM_TOKEN_POOL, false),
            gasLimit: SET_MINTER_GAS_LIMIT
        });
        messages[count++] = ShutdownMessage({
            destinationChainSelector: BERACHAIN_CHAIN_SELECTOR,
            target: BERACHAIN_TOKEN,
            callData: abi.encodeWithSelector(IBridgeShutdownMintable.setMinter.selector, BERACHAIN_TOKEN_POOL, false),
            gasLimit: SET_MINTER_GAS_LIMIT
        });

        count = _appendLegacyBridgeShutdown(messages, count, BASE_CHAIN_SELECTOR, BASE_PROGRAMMABLE_BRIDGE);
        count = _appendLegacyBridgeShutdown(messages, count, OPTIMISM_CHAIN_SELECTOR, OP_PROGRAMMABLE_BRIDGE);
        count = _appendLegacyBridgeShutdown(messages, count, ARBITRUM_CHAIN_SELECTOR, ARB_PROGRAMMABLE_BRIDGE);

        assert(count == L2_SHUTDOWN_MESSAGE_COUNT);
    }

    function _appendLegacyBridgeShutdown(
        ShutdownMessage[] memory buffer,
        uint256 count,
        uint64 destinationChainSelector,
        address bridge
    ) internal pure returns (uint256) {
        uint64[3] memory remoteSelectors;
        address[4] memory senders;
        uint64[4] memory senderSelectors;

        senders[0] = OLD_MAINNET_PROGRAMMABLE_BRIDGE;
        senderSelectors[0] = MAINNET_CHAIN_SELECTOR;
        senders[1] = NEW_MAINNET_PROGRAMMABLE_BRIDGE;
        senderSelectors[1] = MAINNET_CHAIN_SELECTOR;

        if (destinationChainSelector == BASE_CHAIN_SELECTOR) {
            remoteSelectors = [ARBITRUM_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR, OPTIMISM_CHAIN_SELECTOR];
            senders[2] = ARB_PROGRAMMABLE_BRIDGE;
            senderSelectors[2] = ARBITRUM_CHAIN_SELECTOR;
            senders[3] = OP_PROGRAMMABLE_BRIDGE;
            senderSelectors[3] = OPTIMISM_CHAIN_SELECTOR;
        } else if (destinationChainSelector == OPTIMISM_CHAIN_SELECTOR) {
            remoteSelectors = [ARBITRUM_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR, BASE_CHAIN_SELECTOR];
            senders[2] = ARB_PROGRAMMABLE_BRIDGE;
            senderSelectors[2] = ARBITRUM_CHAIN_SELECTOR;
            senders[3] = BASE_PROGRAMMABLE_BRIDGE;
            senderSelectors[3] = BASE_CHAIN_SELECTOR;
        } else if (destinationChainSelector == ARBITRUM_CHAIN_SELECTOR) {
            remoteSelectors = [OPTIMISM_CHAIN_SELECTOR, MAINNET_CHAIN_SELECTOR, BASE_CHAIN_SELECTOR];
            senders[2] = OP_PROGRAMMABLE_BRIDGE;
            senderSelectors[2] = OPTIMISM_CHAIN_SELECTOR;
            senders[3] = BASE_PROGRAMMABLE_BRIDGE;
            senderSelectors[3] = BASE_CHAIN_SELECTOR;
        } else {
            revert UnknownChainSelector(destinationChainSelector);
        }

        // Stop the legacy bridge from sending to or receiving from every remote chain.
        for (uint256 i; i < remoteSelectors.length; ++i) {
            uint64 remoteSelector = remoteSelectors[i];
            buffer[count++] = ShutdownMessage({
                destinationChainSelector: destinationChainSelector,
                target: bridge,
                callData: abi.encodeWithSelector(
                    IBridgeShutdownProgrammableBridge.allowlistDestinationChain.selector, remoteSelector, false
                ),
                gasLimit: LEGACY_BRIDGE_GAS_LIMIT
            });
            buffer[count++] = ShutdownMessage({
                destinationChainSelector: destinationChainSelector,
                target: bridge,
                callData: abi.encodeWithSelector(
                    IBridgeShutdownProgrammableBridge.allowlistSourceChain.selector, remoteSelector, false
                ),
                gasLimit: LEGACY_BRIDGE_GAS_LIMIT
            });
        }

        // Stop every known remote legacy bridge from being accepted as a sender.
        for (uint256 i; i < senders.length; ++i) {
            buffer[count++] = ShutdownMessage({
                destinationChainSelector: destinationChainSelector,
                target: bridge,
                callData: abi.encodeWithSelector(
                    IBridgeShutdownProgrammableBridge.allowlistSender.selector, senders[i], senderSelectors[i], false
                ),
                gasLimit: LEGACY_BRIDGE_GAS_LIMIT
            });
        }

        return count;
    }

    function _hardcodedL2TokenPoolRemovals() internal pure returns (TokenPoolRemovals memory removals) {
        removals.baseRemovals = new uint64[](4);
        removals.baseRemovals[0] = ARBITRUM_CHAIN_SELECTOR;
        removals.baseRemovals[1] = OPTIMISM_CHAIN_SELECTOR;
        removals.baseRemovals[2] = MAINNET_CHAIN_SELECTOR;
        removals.baseRemovals[3] = BERACHAIN_CHAIN_SELECTOR;

        removals.optimismRemovals = new uint64[](3);
        removals.optimismRemovals[0] = ARBITRUM_CHAIN_SELECTOR;
        removals.optimismRemovals[1] = BASE_CHAIN_SELECTOR;
        removals.optimismRemovals[2] = MAINNET_CHAIN_SELECTOR;

        removals.arbitrumRemovals = new uint64[](4);
        removals.arbitrumRemovals[0] = BASE_CHAIN_SELECTOR;
        removals.arbitrumRemovals[1] = OPTIMISM_CHAIN_SELECTOR;
        removals.arbitrumRemovals[2] = MAINNET_CHAIN_SELECTOR;
        removals.arbitrumRemovals[3] = BERACHAIN_CHAIN_SELECTOR;

        removals.berachainRemovals = new uint64[](3);
        removals.berachainRemovals[0] = ARBITRUM_CHAIN_SELECTOR;
        removals.berachainRemovals[1] = BASE_CHAIN_SELECTOR;
        removals.berachainRemovals[2] = MAINNET_CHAIN_SELECTOR;
    }
}
