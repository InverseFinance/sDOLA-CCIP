// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";


/// @title - A simple receiver contract for receiving addresses and calldata, then calling them
contract GovernanceProxy is CCIPReceiver {

    // Custom errors to provide more descriptive revert messages.
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees); // Used to make sure contract has enough balance.
    error NothingToWithdraw(); // Used when trying to withdraw Ether but there's nothing to withdraw.
    error FailedToWithdrawEth(address owner, address target, uint256 value); // Used when the withdrawal of Ether fails.
    error SourceChainNotAllowed(uint64 sourceChainSelector); // Used when the source chain has not been allowed by the contract owner.
    error SenderNotAllowed(address sender); // Used when the sender has not been allowed by the contract owner.
    // Event emitted when a message is received from another chain.

    event MessageReceived(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed sourceChainSelector, // The chain selector of the source chain.
        address sender, // The address of the sender from the source chain.
        address target, // The text that was received.
        bool success // Whether or not execution of the received message was a success
    );

    // Chainlink Chainselector of the allowed source chain
    uint64 public immutable allowedSourceChain;

    // Address of governance messenger contract on source chain
    address public immutable allowedSender;

    /// @notice Constructor initializes the contract with the router address.
    /// @param _router The address of the router contract.
    constructor(address _router, address _allowedSender, uint64 _allowedSourceChain) CCIPReceiver(_router) {
        allowedSender = _allowedSender;
        allowedSourceChain = _allowedSourceChain;
    }

    /// @dev Modifier that checks if the chain with the given sourceChainSelector is allowed and if the sender is allowed.
    /// @param _sourceChainSelector The selector of the destination chain.
    /// @param _sender The address of the sender.
    modifier onlyAllowed(uint64 _sourceChainSelector, address _sender) {
        if (allowedSourceChain != _sourceChainSelector)
            revert SourceChainNotAllowed(_sourceChainSelector);
        if (allowedSender != _sender) revert SenderNotAllowed(_sender);
        _;
    }

    ///@notice Handle a received message and call the defined function in the provided address with the provided call data
    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    )
        internal
        override
        onlyAllowed(
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address))
        ) // Make sure source chain and sender are allowed
    {
        (address targetContract, bytes memory callData) = abi.decode(any2EvmMessage.data, ((address), (bytes))); // abi-decoding of the sent text
        (bool success,) = targetContract.call(callData);

        emit MessageReceived(
            any2EvmMessage.messageId,
            any2EvmMessage.sourceChainSelector, // fetch the source chain identifier (aka selector)
            abi.decode(any2EvmMessage.sender, (address)), // abi-decoding of the sender address,
            targetContract,
            success
        );
    }

    /// @notice Fallback function to allow the contract to receive Ether.
    /// @dev This function has no function body, making it a default function for receiving Ether.
    /// It is automatically called when Ether is sent to the contract without any data.
    receive() external payable {}
}

