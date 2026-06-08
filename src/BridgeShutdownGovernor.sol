// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ConfirmedOwner} from "@chainlink/contracts-ccip/src/v0.8/shared/access/ConfirmedOwner.sol";
import {GovernanceSender} from "src/GovernanceSender.sol";

// Minimal copy of the token-pool rate-limiter struct. It is included only because
// applyChainUpdates takes this shape for "chains to add"; shutdown always passes an empty array.
struct BridgeShutdownRateLimiterConfig {
    bool isEnabled;
    uint128 capacity;
    uint128 rate;
}

// Minimal copy of the token-pool chain update struct. Shutdown removes chains and never adds chains,
// but the token-pool function requires this type in its second argument.
struct BridgeShutdownChainUpdate {
    uint64 remoteChainSelector;
    bytes[] remotePoolAddresses;
    bytes remoteTokenAddress;
    BridgeShutdownRateLimiterConfig outboundRateLimiterConfig;
    BridgeShutdownRateLimiterConfig inboundRateLimiterConfig;
}

// Minimal interfaces for the exact external calls this contract prepares or sends.
// Keeping these interfaces small makes the shutdown surface easier to audit.
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

/// @notice Temporary L1 owner of GovernanceSender used to send the fixed bridge wind-down messages.
/// @dev This contract is intentionally a hardcoded shutdown plan:
///      - it cannot choose arbitrary destination chains;
///      - it cannot choose arbitrary target contracts;
///      - it cannot choose arbitrary calldata;
///      - it can only send the fixed L2 shutdown batch assembled below.
contract BridgeShutdownGovernor is ConfirmedOwner {
    // One CCIP message that GovernanceSender will relay to a GovernanceProxy on the destination chain.
    // The GovernanceProxy then calls `target` with `callData` using the requested gas limit.
    struct ShutdownMessage {
        uint64 destinationChainSelector;
        address target;
        bytes callData;
        uint256 gasLimit;
    }

    // The remote chain selectors removed from each L2 token pool. These arrays are deliberately
    // hardcoded so the shutdown cannot be changed by calldata supplied to executeL2Shutdown().
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

    // Events are limited to operational milestones: funding the sender, becoming an allowed caller,
    // each CCIP shutdown message sent, ownership cleanup, and ETH recovery.
    event GovernanceSenderFunded(uint256 amount);
    event GovernanceSenderAllowlisted(address caller);
    event ShutdownMessageSent(
        bytes32 indexed messageId, uint64 indexed destinationChainSelector, address indexed target, uint256 gasLimit
    );
    event GovernanceSenderOwnershipTransferRequested(address indexed newOwner);
    event EthWithdrawn(address indexed beneficiary, uint256 amount);

    // Existing mainnet GovernanceSender. This contract never deploys or configures a sender.
    // The shutdown script verifies that this sender already points each chain selector to the
    // expected GovernanceProxy before broadcasting.
    address public constant GOVERNANCE_SENDER_ADDRESS = 0x4e521Fe7A9084067096d45A312B8FEeE39D5F1f3;

    // Gas limits for each class of destination-chain action. They are fixed as part of the
    // shutdown plan and cannot be changed by the caller.
    uint256 public constant TOKEN_POOL_GAS_LIMIT = 600_000;
    uint256 public constant SET_MINTER_GAS_LIMIT = 250_000;
    uint256 public constant LEGACY_BRIDGE_GAS_LIMIT = 250_000;

    // Message/call counts document the expected size of the shutdown plan:
    // L2: 4 token-pool removals + 4 minter revocations + 30 legacy bridge allowlist removals.
    // Mainnet: 1 token-pool removal + 18 legacy bridge allowlist removals built by the script.
    uint256 public constant L2_SHUTDOWN_MESSAGE_COUNT = 38;
    uint256 public constant MAINNET_SHUTDOWN_CALL_COUNT = 19;

    // Chainlink CCIP chain selectors. These are not EVM chain IDs.
    uint64 public constant MAINNET_CHAIN_SELECTOR = 5009297550715157269;
    uint64 public constant BASE_CHAIN_SELECTOR = 15971525489660198786;
    uint64 public constant OPTIMISM_CHAIN_SELECTOR = 3734403246176062136;
    uint64 public constant ARBITRUM_CHAIN_SELECTOR = 4949039107694359620;
    uint64 public constant BERACHAIN_CHAIN_SELECTOR = 1294465214383781161;

    // GovernanceProxy contracts that receive CCIP messages on each L2. GovernanceSender must already
    // map each chain selector to these proxies for executeL2Shutdown() to succeed.
    address public constant BASE_GOVERNANCE_PROXY = 0x1C064265E053D23d120c518fDBB542e6537f82d1;
    address public constant OPTIMISM_GOVERNANCE_PROXY = 0xaF956837AF704D825c1FCbE2651D5c3c37AD5289;
    address public constant ARBITRUM_GOVERNANCE_PROXY = 0x607bCd974bB69C78eCdbf0B68748B791bBa24d94;
    address public constant BERACHAIN_GOVERNANCE_PROXY = 0x1992AF61FBf8ee38741bcc57d636CAA22A1a7702;

    // Token pools that currently support bridging. Shutdown removes their remote-chain connections.
    address public constant MAINNET_TOKEN_POOL = 0x05eEe76f456C51Be0459EC1c0a78bf177B2c877C;
    address public constant BASE_TOKEN_POOL = 0xd84e1B7e1a7A8D49167884855c3985ef4bCa45aB;
    address public constant OPTIMISM_TOKEN_POOL = 0x8404024d8F74Ad2D20E82c184816B64D4184A018;
    address public constant ARBITRUM_TOKEN_POOL = 0xbbc28DB61DF26B76D5F7D5Eed17eD4D6C278460e;
    address public constant BERACHAIN_TOKEN_POOL = 0x8Bbd036d018657E454F679E7C4726F7a8ECE2773;

    // L2 receipt tokens. Shutdown revokes each token pool's minter permission on its local token.
    address public constant BASE_TOKEN = 0xCa78ee4544ec5a33Af86F1E786EfC7d3652bf005;
    address public constant OPTIMISM_TOKEN = 0xfc63C9c8Ba44AE89C01265453Ed4F427C80cBd4E;
    address public constant ARBITRUM_TOKEN = 0x7a1e123e41458aabaB8068BFed6010D8f9480898;
    address public constant BERACHAIN_TOKEN = 0x02eaa69646183c069FC2B64F15923F27B9CF3b03;

    // Legacy programmable bridge contracts. Shutdown removes their destination/source chain
    // allowlists and accepted sender allowlists so legacy message passing is disabled.
    address public constant OLD_MAINNET_PROGRAMMABLE_BRIDGE = 0x7A43C13f7Fb3A0bF19cEB3fBC583A0CAda6D29a2;
    address public constant NEW_MAINNET_PROGRAMMABLE_BRIDGE = 0x70F3795c1EF726c58FfeA2e1A51526ac5707C066;
    address public constant BASE_PROGRAMMABLE_BRIDGE = 0x0173804066F7403E0815680F3DDa125a6cd10F7c;
    address public constant OP_PROGRAMMABLE_BRIDGE = 0xb5A998E90AdeD2C97f7ceDbb7c45Bbc27E82dfdD;
    address public constant ARB_PROGRAMMABLE_BRIDGE = 0x0173804066F7403E0815680F3DDa125a6cd10F7c;

    // Cached immutable pointer to the hardcoded GovernanceSender.
    GovernanceSender private immutable GOVERNANCE_SENDER;

    constructor(address owner_) ConfirmedOwner(owner_) {
        GOVERNANCE_SENDER = GovernanceSender(payable(GOVERNANCE_SENDER_ADDRESS));
    }

    // Allows this contract to receive ETH for CCIP fees or refunds.
    receive() external payable {}

    function governanceSender() external view returns (GovernanceSender) {
        return GOVERNANCE_SENDER;
    }

    /// @notice Accepts GovernanceSender ownership and allowlists this contract to send messages.
    /// @dev This is required before executeL2Shutdown(), because GovernanceSender only accepts
    ///      send requests from allowlisted callers.
    function acceptGovernanceSenderOwnership() external onlyOwner {
        GOVERNANCE_SENDER.acceptOwnership();
        GOVERNANCE_SENDER.allowlistCaller(address(this), true);
        emit GovernanceSenderAllowlisted(address(this));
    }

    /// @notice Sends the fixed L2 bridge shutdown message batch through GovernanceSender.
    /// @dev The caller supplies only ETH for CCIP fees. The caller does not supply targets,
    ///      chains, calldata, or gas limits.
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

            // These checks should never fail for the hardcoded plan. They are left here as
            // explicit safety rails in case a future edit accidentally creates an invalid message.
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
    /// @dev Used after shutdown to recover unused CCIP fee budget or refunds.
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
    /// @dev This also removes this contract from GovernanceSender's caller allowlist so it cannot
    ///      continue sending messages after ownership is handed away.
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

        // The token-pool function has two arguments: chains to remove and chains to add.
        // Shutdown only removes lanes, so every message passes an empty "chains to add" array.
        BridgeShutdownChainUpdate[] memory noChainAdds = new BridgeShutdownChainUpdate[](0);

        // Phase 1: remove every known remote chain from each L2 token pool. This prevents
        // the CCIP token-pool bridge from treating those remote lanes as supported.
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

        // Phase 2: revoke each L2 token pool's minting permission on its receipt token.
        // After this, the pool can no longer mint new receipt tokens even if another path called it.
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

        // The fixed count is an audit guard: adding, removing, or skipping a message changes this assert.
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

        // Every L2 legacy bridge accepted both old and new mainnet programmable bridges as senders.
        // Those mainnet senders are always removed first for each L2.
        senders[0] = OLD_MAINNET_PROGRAMMABLE_BRIDGE;
        senderSelectors[0] = MAINNET_CHAIN_SELECTOR;
        senders[1] = NEW_MAINNET_PROGRAMMABLE_BRIDGE;
        senderSelectors[1] = MAINNET_CHAIN_SELECTOR;

        // For each L2 bridge, identify:
        // - remoteSelectors: chains that should no longer be valid destinations or sources;
        // - senders: remote bridge contracts that should no longer be accepted as message senders;
        // - senderSelectors: the source chain selector paired with each sender address.
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

        // Phase 3a: stop the legacy bridge from sending to or receiving from every remote chain.
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

        // Phase 3b: stop every known remote legacy bridge from being accepted as a sender.
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

    // Hardcoded token-pool lanes to remove on each L2. The order is part of the fixed plan and
    // matches the expected supported-chain arrays checked by the shutdown script before broadcast.
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
