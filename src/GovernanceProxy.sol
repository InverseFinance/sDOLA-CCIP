// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";


/// @title - A simple receiver contract for receiving addresses and calldata, then calling them
contract GovernanceProxy is CCIPReceiver, OwnerIsCreator {

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
    uint64 allowedSourceChain;

    // Address of governance messenger contract on source chain
    address public allowedSender;

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

    /// @notice Allows the contract owner to withdraw the entire balance of Ether from the contract.
    /// @dev This function reverts if there are no funds to withdraw or if the transfer fails.
    /// It should only be callable by the owner of the contract.
    /// @param _beneficiary The address to which the Ether should be sent.
    function withdraw(address _beneficiary) public onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = address(this).balance;

        // Revert if there is nothing to withdraw
        if (amount == 0) revert NothingToWithdraw();

        // Attempt to send the funds, capturing the success status and discarding any return data
        (bool sent, ) = _beneficiary.call{value: amount}("");

        // Revert if the send failed, with information about the attempted transfer
        if (!sent) revert FailedToWithdrawEth(msg.sender, _beneficiary, amount);
    }
}

