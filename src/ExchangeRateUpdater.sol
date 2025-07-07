// SPDX-License-Identifier: MIT
// Based on the Chainlink ProgrammableTokenTransfers contract
pragma solidity ^0.8.19;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {EnumerableMap} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableMap.sol";

interface IExchangeRateProvider {
    function exchangeRate() external view returns(uint);
    function lastUpdate() external view returns(uint);
    function setExchangeRate(uint) external returns(bool);
    function setLastUpdate(uint) external returns(bool);
}

interface IERC20 {
    function approve(address to, uint amount) external;
    function transferFrom(address from, address to, uint amount) external;
    function balanceOf(address) external view returns(uint);

}

/// @title - A messenger contract for transferring tokens and exchange rate data across chains.
contract ExchangeRateUpdater is CCIPReceiver, OwnerIsCreator {
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;

    // Custom errors to provide more descriptive revert messages.
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees); // Used to make sure contract has enough balance to cover the fees.
    error FailedExchangeRateUpdate(); // Used when the exchange rate fails to update.
    error FailedTimeUpdate(); // Used when the last timestamp fails to update
    error SourceChainNotAllowed(uint64 sourceChainSelector); // Used when the source chain has not been allowlisted by the contract owner.
    error SenderNotAllowed(uint64 sourceChainSelector, address sender); // Used when the sender has not been allowlisted by the contract owner.
    error InvalidUpdaterAddress(); // Used when the receiver address is 0.
    error OnlySelf(); // Used when a function is called outside of the contract itself.
    error MessageNotFailed(bytes32 messageId);

    // Example error code, could have many different error codes.
    enum ErrorCode {
        // RESOLVED is first so that the default value is resolved.
        RESOLVED,
        // Could have any number of error codes here.
        FAILED
    }

    struct FailedMessage {
        bytes32 messageId;
        ErrorCode errorCode;
    }

    // Event emitted when a message is sent to another chain.
    event MessageSent(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
        address updaterContract, // The address of the updater contract on the destination chain.
        uint256 timestamp, // The timestamp being sent.
        uint256 exchangeRate, // The exchange rate that was sent
        address feeToken, // the token address used to pay CCIP fees.
        uint256 fees // The fees paid for sending the message.
    );

    // Event emitted when a message is received from another chain.
    event MessageReceived(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed sourceChainSelector, // The chain selector of the source chain.
        address sender, // The address of the sender from the source chain.
        uint256 timestamp, // The timestamp that was received.
        uint256 exchangeRate // The exchange rate that was received.
    );

    event MessageFailed(bytes32 indexed messageId, bytes reason);
    event MessageRecovered(bytes32 indexed messageId);

    bool public isCanonical; // Indicate whether or not the contract exists on the same chain as the main sDOLA contract
    uint public additionalGasLimit = 400_000; //The additional gas limit used for calling contract functions on the receiving network 
    address public exchangeRateProvider; //Address to call for sDOLA exchange rate reads and updates

    // Mapping to keep track of allowlisted updaters on different destination chains
    mapping(uint64 => address) public destinationChainUpdater;

    // Mapping to keep track of allowlisted source chains.
    mapping(uint64 => bool) public allowlistedSourceChains;

    // Mapping to keep track of allowlisted senders for each network.
    mapping(uint64 => mapping(address => bool)) public allowlistedSenders;

    IERC20 private s_linkToken;

    // The message contents of failed messages are stored here.
    mapping(bytes32 messageId => Client.Any2EVMMessage contents)
        public s_messageContents;

    // Contains failed messages and their state.
    EnumerableMap.Bytes32ToUintMap internal s_failedMessages;

    /// @notice Constructor initializes the contract with the router address.
    /// @param _router The address of the router contract.
    /// @param _link The address of the link contract.
    /// @param _exchangeRateProvider The address of the exchange rate contract.
    /// @param _isCanonical Boolean indicating whether or not this bridge exists on the canonical sDOLA chain
    constructor(address _router, address _link, address _exchangeRateProvider, bool _isCanonical) CCIPReceiver(_router) {
        s_linkToken = IERC20(_link);
        isCanonical = _isCanonical;
        exchangeRateProvider = _exchangeRateProvider;
    }

    /// @dev Modifier that checks if the chain with the given sourceChainSelector is allowlisted and if the sender is allowlisted.
    /// @param _sourceChainSelector The selector of the destination chain.
    /// @param _sender The address of the sender.
    modifier onlyAllowlisted(uint64 _sourceChainSelector, address _sender) {
        if (!allowlistedSourceChains[_sourceChainSelector])
            revert SourceChainNotAllowed(_sourceChainSelector);
        if (!allowlistedSenders[_sourceChainSelector][_sender]) revert SenderNotAllowed(_sourceChainSelector, _sender);
        _;
    }

    /// @dev Modifier that checks the receiver address is not 0.
    /// @param _destinationChainSelector Chain selector of the destination chain. If set to address 0 chain is invalid.
    modifier validateDestinationUpdater(uint64 _destinationChainSelector) {
        if (destinationChainUpdater[_destinationChainSelector] == address(0)) revert InvalidUpdaterAddress();
        _;
    }

    /// @dev Modifier to allow only the contract itself to execute a function.
    /// Throws an exception if called by any account other than the contract itself.
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    /// @dev Updates the allowlist status of a destination chain for transactions.
    /// @notice This function can only be called by the owner.
    /// @param _destinationChainSelector The selector of the destination chain to be updated.
    /// @param _updater The address of the updater on the destination chain. Set to address 0 to remove updater.
    function setDestinationChainUpdater(
        uint64 _destinationChainSelector,
        address _updater
    ) external onlyOwner {
        destinationChainUpdater[_destinationChainSelector] = _updater;
    }

    /// @dev Updates the allowlist status of a source chain
    /// @notice This function can only be called by the owner.
    /// @param _sourceChainSelector The selector of the source chain to be updated.
    /// @param allowed The allowlist status to be set for the source chain.
    function allowlistSourceChain(
        uint64 _sourceChainSelector,
        bool allowed
    ) external onlyOwner {
        allowlistedSourceChains[_sourceChainSelector] = allowed;
    }

    /// @dev Updates the allowlist status of a sender for transactions.
    /// @notice This function can only be called by the owner.
    /// @param _sender The address of the sender to be updated.
    /// @param _sourceChainSelector The chainlink CCIP source chain selector to allow the sender to send messages from
    /// @param allowed The allowlist status to be set for the sender.
    function allowlistSender(address _sender, uint64 _sourceChainSelector, bool allowed) external onlyOwner {
        allowlistedSenders[_sourceChainSelector][_sender] = allowed;
    }

    /// @notice Sends data and transfer tokens to receiver on the destination chain.
    /// @notice Pay for fees in LINK.
    /// @dev Assumes your contract has sufficient LINK to pay for CCIP fees.
    /// @param _destinationChainSelector The identifier (aka selector) for the destination blockchain.
    /// @return messageId The ID of the CCIP message that was sent.
    function updateRatePayLINK(
        uint64 _destinationChainSelector
    )
        external
        validateDestinationUpdater(_destinationChainSelector)
        returns (bytes32 messageId)
    {
        address updaterContract = destinationChainUpdater[_destinationChainSelector];
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // address(linkToken) means fees are paid in LINK
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            address(s_linkToken),
            updaterContract
        );

        // Initialize a router client instance to interact with cross-chain router
        IRouterClient router = IRouterClient(this.getRouter());

        // Get the fee required to send the CCIP message
        uint256 fees = router.getFee(_destinationChainSelector, evm2AnyMessage);

        // Transfer link tokens from sender to contract
        s_linkToken.transferFrom(msg.sender, address(this), fees);

        if (fees > s_linkToken.balanceOf(address(this)))
            revert NotEnoughBalance(s_linkToken.balanceOf(address(this)), fees);

        // approve the Router to transfer LINK tokens on contract's behalf. It will spend the fees in LINK
        s_linkToken.approve(address(router), fees);

        // Send the message through the router and store the returned message ID
        //TODO: Only send message
        messageId = router.ccipSend(_destinationChainSelector, evm2AnyMessage);

        // Emit an event with message details
        emit MessageSent(
            messageId,
            _destinationChainSelector,
            updaterContract,
            block.timestamp,
            getExchangeRate(),
            address(s_linkToken),
            fees
        );

        // Return the message ID
        return messageId;
    }

    /// @notice Sends data and transfer tokens to receiver on the destination chain.
    /// @notice Pay for fees in native gas.
    /// @dev Assumes your contract has sufficient native gas like ETH on Ethereum or MATIC on Polygon.
    /// @param _destinationChainSelector The identifier (aka selector) for the destination blockchain.
    /// @return messageId The ID of the CCIP message that was sent.
    function updateRatePayNative(
        uint64 _destinationChainSelector
    )
        public
        payable
        validateDestinationUpdater(_destinationChainSelector)
        returns (bytes32 messageId)
    {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // address(0) means fees are paid in native gas
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            address(0),
            destinationChainUpdater[_destinationChainSelector]
        );

        // Initialize a router client instance to interact with cross-chain router
        IRouterClient router = IRouterClient(this.getRouter());
        
        // Get the fee required to send the CCIP message
        uint256 fees = router.getFee(_destinationChainSelector, evm2AnyMessage);
        
        if (fees > address(this).balance)
            revert NotEnoughBalance(address(this).balance, fees);
        
        // Send the message through the router and store the returned message ID
        //TODO: Only send message
        messageId = router.ccipSend{value: fees}(
            _destinationChainSelector,
            evm2AnyMessage
        );
        

        // Emit an event with message details
        emit MessageSent(
            messageId,
            _destinationChainSelector,
            destinationChainUpdater[_destinationChainSelector],
            block.timestamp,
            getExchangeRate(),
            address(0),
            fees
        );

        //If contract has excess eth, return it to sender
        if(address(this).balance > 0){
            payable(msg.sender).transfer(address(this).balance);
        }

        // Return the message ID
        return messageId;
    }

    function getFee(uint64 _destinationChainSelector) public view returns(uint){
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            address(0),
            destinationChainUpdater[_destinationChainSelector]
        );

        // Initialize a router client instance to interact with cross-chain router
        IRouterClient router = IRouterClient(this.getRouter());
        
        // Get the fee required to send the CCIP message
        return router.getFee(_destinationChainSelector, evm2AnyMessage);
 
    }

    /**
     * @notice Retrieves a paginated list of failed messages.
     * @dev This function returns a subset of failed messages defined by `offset` and `limit` parameters. It ensures that the pagination parameters are within the bounds of the available data set.
     * @param offset The index of the first failed message to return, enabling pagination by skipping a specified number of messages from the start of the dataset.
     * @param limit The maximum number of failed messages to return, restricting the size of the returned array.
     * @return failedMessages An array of `FailedMessage` struct, each containing a `messageId` and an `errorCode` (RESOLVED or FAILED), representing the requested subset of failed messages. The length of the returned array is determined by the `limit` and the total number of failed messages.
     */
    function getFailedMessages(
        uint256 offset,
        uint256 limit
    ) external view returns (FailedMessage[] memory) {
        uint256 length = s_failedMessages.length();

        // Calculate the actual number of items to return (can't exceed total length or requested limit)
        uint256 returnLength = (offset + limit > length)
            ? length - offset
            : limit;
        FailedMessage[] memory failedMessages = new FailedMessage[](
            returnLength
        );

        // Adjust loop to respect pagination (start at offset, end at offset + limit or total length)
        for (uint256 i = 0; i < returnLength; i++) {
            (bytes32 messageId, uint256 errorCode) = s_failedMessages.at(
                offset + i
            );
            failedMessages[i] = FailedMessage(messageId, ErrorCode(errorCode));
        }
        return failedMessages;
    }

    /// @notice The entrypoint for the CCIP router to call. This function should
    /// never revert, all errors should be handled internally in this contract.
    /// @param any2EvmMessage The message to process.
    /// @dev Extremely important to ensure only router calls this.
    function ccipReceive(
        Client.Any2EVMMessage calldata any2EvmMessage
    )
        external
        override
        onlyRouter
        onlyAllowlisted(
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address))
        ) // Make sure the source chain and sender are allowlisted
    {
        /* solhint-disable no-empty-blocks */
        try this.processMessage(any2EvmMessage) {
            // Intentionally empty in this example; no action needed if processMessage succeeds
        } catch (bytes memory err) {
            // Could set different error codes based on the caught error. Each could be
            // handled differently.
            s_failedMessages.set(
                any2EvmMessage.messageId,
                uint256(ErrorCode.FAILED)
            );
            s_messageContents[any2EvmMessage.messageId] = any2EvmMessage;
            // Don't revert so CCIP doesn't revert. Emit event instead.
            // The message can be retried later without having to do manual execution of CCIP.
            emit MessageFailed(any2EvmMessage.messageId, err);
            return;
        }
    }

    /// @notice Serves as the entry point for this contract to process incoming messages.
    /// @param any2EvmMessage Received CCIP message.
    /// @dev Transfers specified token amounts to the owner of this contract. This function
    /// must be external because of the  try/catch for error handling.
    /// It uses the `onlySelf`: can only be called from the contract.
    function processMessage(
        Client.Any2EVMMessage calldata any2EvmMessage
    )
        external
        onlySelf
        onlyAllowlisted(
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address))
        ) // Make sure the source chain and sender are allowlisted
    {
        _ccipReceive(any2EvmMessage); // process the message - may revert as well
    }

    /// @notice Allows the owner to retry a failed message in order to unblock the associated tokens.
    /// @param messageId The unique identifier of the failed message.
    /// @dev This function is only callable by the contract owner. It changes the status of the message
    /// from 'failed' to 'resolved' to prevent reentry and multiple retries of the same message.
    function retryFailedMessage(
        bytes32 messageId
    ) external onlyOwner {
        // Check if the message has failed; if not, revert the transaction.
        if (s_failedMessages.get(messageId) != uint256(ErrorCode.FAILED))
            revert MessageNotFailed(messageId);

        // Set the error code to RESOLVED to disallow reentry and multiple retries of the same failed message.
        s_failedMessages.set(messageId, uint256(ErrorCode.RESOLVED));

        // Retrieve the content of the failed message.
        Client.Any2EVMMessage memory message = s_messageContents[messageId];
        _ccipReceive(message);

        // Emit an event indicating that the message has been recovered.
        emit MessageRecovered(messageId);
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        (uint256 s_lastReceivedTimestamp, uint256 s_lastReceivedExchangeRate) = abi.decode(any2EvmMessage.data, (uint, uint)); // abi-decoding of the sent timestamp and exchangerate
        if(!isCanonical){
            if(!IExchangeRateProvider(exchangeRateProvider).setExchangeRate(s_lastReceivedExchangeRate)) revert FailedExchangeRateUpdate();
            if(!IExchangeRateProvider(exchangeRateProvider).setLastUpdate(s_lastReceivedTimestamp)) revert FailedTimeUpdate();
        }
        emit MessageReceived(
            any2EvmMessage.messageId,
            any2EvmMessage.sourceChainSelector, // fetch the source chain identifier (aka selector)
            abi.decode(any2EvmMessage.sender, (address)), // abi-decoding of the sender address,
            s_lastReceivedTimestamp,
            s_lastReceivedExchangeRate
        );
    }

    /// @notice Construct a CCIP message.
    /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for programmable tokens transfer.
    /// @param _feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
    function _buildCCIPMessage(
        address _feeTokenAddress,
        address _updaterContract
    ) private view returns (Client.EVM2AnyMessage memory) {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            //TODO: Should receiver contract be the Exchange Rate Updater on target chain?
            receiver: abi.encode(_updaterContract), // ABI-encoded receiver address
            tokenAmounts: new Client.EVMTokenAmount[](0), // Empty array as no tokens are transferred
            data: abi.encode(getLastUpdate(), getExchangeRate()), // ABI-encoded uint
            extraArgs: Client._argsToBytes(
                // Additional arguments, setting gas limit
                Client.EVMExtraArgsV1({gasLimit: additionalGasLimit})
            ),
            // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
            feeToken: _feeTokenAddress
        });
        return evm2AnyMessage;
    }

    /// @notice Get exchange rate from the associated exchange rate provider
    /// @return exchangeRate The exchange rate last recorded in the exchangerate provider
    /// @dev On mainnet this will always return a fresh price, whereas on L2s it will be lagging
    function getExchangeRate() public view returns(uint256 exchangeRate){
        exchangeRate = IExchangeRateProvider(exchangeRateProvider).exchangeRate();
    }

    /// @notice Get last update timestamp of the exchange rate
    /// @return The timestamp of the last exchange rate update
    /// @dev This time will always be the block timestamp on mainnet, whereas on L2s it will be lagging
    function getLastUpdate() public view returns(uint256) {
        if(isCanonical){
            return block.timestamp;
        } else {
            return IExchangeRateProvider(exchangeRateProvider).lastUpdate();
        }
    }

    /// @notice Fallback function to allow the contract to receive Ether.
    /// @dev This function has no function body, making it a default function for receiving Ether.
    /// It is automatically called when Ether is sent to the contract without any data.
    receive() external payable {}

    /// @notice Set the additional gas limit passed along to the receiver of messages
    /// @dev This is used to call contract functions on L2s, most importantly
    /// @param newAdditionalGasLimit The new additional gas limit.
    function setAdditionalGasLimit(uint newAdditionalGasLimit) external onlyOwner {
        additionalGasLimit = newAdditionalGasLimit;
    }
}

