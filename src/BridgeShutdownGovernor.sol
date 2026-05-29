// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ConfirmedOwner} from "@chainlink/contracts-ccip/src/v0.8/shared/access/ConfirmedOwner.sol";
import {GovernanceSender} from "src/GovernanceSender.sol";

/// @notice L1 owner of GovernanceSender used to send bridge wind-down messages.
contract BridgeShutdownGovernor is ConfirmedOwner {
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

    event GovernanceSenderFunded(uint256 amount);
    event GovernanceSenderAllowlisted(address caller);
    event GovernanceProxySet(uint64 indexed destinationChainSelector, address indexed governanceProxy);
    event ShutdownMessageSent(
        bytes32 indexed messageId, uint64 indexed destinationChainSelector, address indexed target, uint256 gasLimit
    );
    event GovernanceSenderOwnershipTransferRequested(address indexed newOwner);
    event EthWithdrawn(address indexed beneficiary, uint256 amount);

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

    /// @notice Updates the destination GovernanceProxy used by GovernanceSender.
    function setGovernanceProxy(uint64 destinationChainSelector, address governanceProxy) external onlyOwner {
        GOVERNANCE_SENDER.allowlistGovernanceProxy(destinationChainSelector, governanceProxy);
        emit GovernanceProxySet(destinationChainSelector, governanceProxy);
    }

    /// @notice Sends a batch of CCIP governance messages through GovernanceSender.
    function executeMessages(ShutdownMessage[] calldata messages)
        external
        payable
        onlyOwner
        returns (bytes32[] memory messageIds)
    {
        if (msg.value > 0) {
            _sendEth(payable(address(GOVERNANCE_SENDER)), msg.value);
            emit GovernanceSenderFunded(msg.value);
        }

        uint256 length = messages.length;
        messageIds = new bytes32[](length);
        for (uint256 i; i < length; ++i) {
            ShutdownMessage calldata shutdownMessage = messages[i];
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

    function _sendEth(address payable target, uint256 amount) internal {
        (bool success,) = target.call{value: amount}("");
        if (!success) revert EthTransferFailed(target, amount);
    }
}
