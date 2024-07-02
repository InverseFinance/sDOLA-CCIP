// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

/// @title - A simple messenger contract for sending calldata across chains.
contract GovernanceSender is OwnerIsCreator {

    // Custom errors to provide more descriptive revert messages.
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees); // Used to make sure contract has enough balance.
    error NothingToWithdraw(); // Used when trying to withdraw Ether but there's nothing to withdraw.
    error FailedToWithdrawEth(address owner, address target, uint256 value); // Used when the withdrawal of Ether fails.
    error GovernanceProxyNotAllowListed(uint64 destinationChainSelector, address governaceProxy); // Used when the destination chain has no allowListed governance proxy at that address
    error CallerNotAllowListed(address caller); // Used when the caller is not allowed to send messages on behalf of governance
    error InvalidReceiverAddress(); // Used when the receiver address is 0.

    // Event emitted when a message is sent to another chain.
    event MessageSent(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
        address receiver, // The address of the receiver on the destination chain.
        address feeToken, // the token address used to pay CCIP fees.
        uint256 fees // The fees paid for sending the CCIP message.
    );

    // Mapping between chainlink chain selectors and address of the governance proxy on the associated chain
    mapping(uint64 => address) public governanceProxies;

    //Mapping of allowListed callers that get to send messages on behalf of governance
    //Will be governance itself and helper contracts
    mapping(address => bool) public allowListedCallers;

    IRouterClient router;

    /// @notice Constructor initializes the contract with the router address.
    /// @param _router The address of the router contract.
    constructor(address _router)  {
        router = IRouterClient(_router);
    }

    modifier onlyAllowListedCaller() {
        if(!allowListedCallers[msg.sender]) revert CallerNotAllowListed(msg.sender);
        _;
    }

    /// @dev Modifier that checks the receiver address is not 0.
    /// @param _proxy The receiver address.
    modifier validateReceiver(address _proxy) {
        if (_proxy == address(0)) revert InvalidReceiverAddress();
        _;
    }

    function allowlistCaller(
        address _caller,
        bool allowed
    ) external onlyOwner {
        allowListedCallers[_caller] = allowed;
    }

    /// @dev Updates the allowlist status of a destination chain for transactions.
    function allowlistGovernanceProxy(
        uint64 _destinationChainSelector,
        address _proxy
    ) external onlyOwner {
        governanceProxies[_destinationChainSelector] = _proxy;
    }

    /// @notice Sends data to receiver on the destination chain.
    /// @notice Pay for fees in native gas.
    /// @dev Assumes your contract has sufficient native gas tokens.
    /// @param _destinationChainSelector The identifier (aka selector) for the destination blockchain.
    /// @param _calledContract The contract to be called
    /// @param _callData The call data to call the called contract with.
    /// @param _additionalGasLimit Additional gas needed for paying for gas used for calls
    /// @return messageId The ID of the CCIP message that was sent.
    function sendMessagePayNative(
        uint64 _destinationChainSelector,
        address _calledContract,
        bytes calldata _callData,
        uint _additionalGasLimit
    )
        external
        onlyAllowListedCaller
        validateReceiver(governanceProxies[_destinationChainSelector])
        returns (bytes32 messageId)
    {
        address governanceProxy = governanceProxies[_destinationChainSelector];
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            governanceProxy,
            _calledContract,
            _callData,
            address(0),
            _additionalGasLimit
        );

        // Get the fee required to send the CCIP message
        uint256 fees = router.getFee(_destinationChainSelector, evm2AnyMessage);

        if (fees > address(this).balance)
            revert NotEnoughBalance(address(this).balance, fees);

        // Send the CCIP message through the router and store the returned CCIP message ID
        messageId = router.ccipSend{value: fees}(
            _destinationChainSelector,
            evm2AnyMessage
        );

        // Emit an event with message details
        emit MessageSent(
            messageId,
            _destinationChainSelector,
            governanceProxy,
            address(0),
            fees
        );

        // Return the CCIP message ID
        return messageId;
    }

    /// @notice Construct a CCIP message.
    /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for sending a text.
    /// @param _proxy The address of the receiver.
    /// @param _callData The string data to be sent.
    /// @param _feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
    /// @param _additionalGasLimit Additional gas needed for paying for gas used for calls
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
    function _buildCCIPMessage(
        address _proxy,
        address _calledContract,
        bytes calldata _callData,
        address _feeTokenAddress,
        uint _additionalGasLimit
    ) private pure returns (Client.EVM2AnyMessage memory) {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        return
            Client.EVM2AnyMessage({
                receiver: abi.encode(_proxy), // ABI-encoded receiver address
                data: abi.encode(_calledContract, _callData),
                tokenAmounts: new Client.EVMTokenAmount[](0), // Empty array as no tokens are transferred
                extraArgs: Client._argsToBytes(
                    // Additional arguments, setting gas limit
                    Client.EVMExtraArgsV1({gasLimit: _additionalGasLimit})
                ),
                // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
                feeToken: _feeTokenAddress
            });
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

