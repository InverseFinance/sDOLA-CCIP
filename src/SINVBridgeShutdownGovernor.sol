// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ConfirmedOwner} from "@chainlink/contracts-ccip/src/v0.8/shared/access/ConfirmedOwner.sol";
import {GovernanceSender} from "src/GovernanceSender.sol";

interface ISINVBridgeShutdownProgrammableBridge {
    function allowlistDestinationChain(uint64 destinationChainSelector, bool allowed) external;
    function allowlistSourceChain(uint64 sourceChainSelector, bool allowed) external;
    function allowlistSender(address sender, uint64 sourceChainSelector, bool allowed) external;
}

/// @notice Temporary L1 owner of the sINV GovernanceSender used to wind down legacy sINV PDTT routes.
/// @dev This contract sends only the fixed sINV programmable bridge allowlist-removal batch.
contract SINVBridgeShutdownGovernor is ConfirmedOwner {
    struct ShutdownMessage {
        uint64 destinationChainSelector;
        address target;
        bytes callData;
        uint256 gasLimit;
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

    address public constant GOVERNANCE_SENDER_ADDRESS = 0xAeA8Ae87A34a0fAaEa0e6beD9f4627F576B524Fa;

    uint256 public constant LEGACY_BRIDGE_GAS_LIMIT = 250_000;
    uint256 public constant L2_SHUTDOWN_MESSAGE_COUNT = 30;

    uint64 public constant MAINNET_CHAIN_SELECTOR = 5009297550715157269;
    uint64 public constant BASE_CHAIN_SELECTOR = 15971525489660198786;
    uint64 public constant OPTIMISM_CHAIN_SELECTOR = 3734403246176062136;
    uint64 public constant ARBITRUM_CHAIN_SELECTOR = 4949039107694359620;

    address public constant BASE_GOVERNANCE_PROXY = 0x5D5392505ee69f9FE7a6a1c1AF14f17Db3B3e364;
    address public constant OPTIMISM_GOVERNANCE_PROXY = 0xCbB162B761B83578b2a0226cbAf4C1adE0d60B2e;
    address public constant ARBITRUM_GOVERNANCE_PROXY = 0x1230bd56bf23Bf7adF95b9F861711301E3CCd6b3;

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

    function acceptGovernanceSenderOwnership() external onlyOwner {
        GOVERNANCE_SENDER.acceptOwnership();
        GOVERNANCE_SENDER.allowlistCaller(address(this), true);
        emit GovernanceSenderAllowlisted(address(this));
    }

    function executeL2Shutdown() external payable onlyOwner returns (bytes32[] memory messageIds) {
        if (msg.value > 0) {
            (bool success,) = payable(address(GOVERNANCE_SENDER)).call{value: msg.value}("");
            if (!success) revert EthTransferFailed(address(GOVERNANCE_SENDER), msg.value);
            emit GovernanceSenderFunded(msg.value);
        }

        ShutdownMessage[] memory messages = _buildL2ShutdownMessages();
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

    function transferGovernanceSenderOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        GOVERNANCE_SENDER.transferOwnership(newOwner);
        GOVERNANCE_SENDER.allowlistCaller(address(this), false);
        emit GovernanceSenderOwnershipTransferRequested(newOwner);
    }

    function _buildL2ShutdownMessages() internal pure returns (ShutdownMessage[] memory messages) {
        messages = new ShutdownMessage[](L2_SHUTDOWN_MESSAGE_COUNT);
        uint256 count;

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

        for (uint256 i; i < remoteSelectors.length; ++i) {
            uint64 remoteSelector = remoteSelectors[i];
            buffer[count++] = ShutdownMessage({
                destinationChainSelector: destinationChainSelector,
                target: bridge,
                callData: abi.encodeWithSelector(
                    ISINVBridgeShutdownProgrammableBridge.allowlistDestinationChain.selector, remoteSelector, false
                ),
                gasLimit: LEGACY_BRIDGE_GAS_LIMIT
            });
            buffer[count++] = ShutdownMessage({
                destinationChainSelector: destinationChainSelector,
                target: bridge,
                callData: abi.encodeWithSelector(
                    ISINVBridgeShutdownProgrammableBridge.allowlistSourceChain.selector, remoteSelector, false
                ),
                gasLimit: LEGACY_BRIDGE_GAS_LIMIT
            });
        }

        for (uint256 i; i < senders.length; ++i) {
            buffer[count++] = ShutdownMessage({
                destinationChainSelector: destinationChainSelector,
                target: bridge,
                callData: abi.encodeWithSelector(
                    ISINVBridgeShutdownProgrammableBridge.allowlistSender.selector,
                    senders[i],
                    senderSelectors[i],
                    false
                ),
                gasLimit: LEGACY_BRIDGE_GAS_LIMIT
            });
        }

        return count;
    }
}
