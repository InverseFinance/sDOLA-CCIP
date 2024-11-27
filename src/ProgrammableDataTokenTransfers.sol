// SPDX-License-Identifier: MIT
// Based on the Chainlink ProgrammableTokenTransfers contract
pragma solidity ^0.8.19;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {EnumerableMap} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableMap.sol";


interface IERC20 {
    function transfer(address, uint) external;
    function transferFrom(address, address, uint) external;
    function balanceOf(address) external returns(uint);
    function approve(address, uint) external;
}

interface IExchangeRateProvider {
    function exchangeRate() external view returns(uint);
    function lastUpdate() external view returns(uint);
    function setExchangeRate(uint) external returns(bool);
    function setLastUpdate(uint) external returns(bool);
}

/// @title - A messenger contract for transferring tokens and exchange rate data across chains.
contract ProgrammableDataTokenTransfers is CCIPReceiver, OwnerIsCreator {
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;

    // Custom errors to provide more descriptive revert messages.
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees); // Used to make sure contract has enough balance to cover the fees.
    error NothingToWithdraw(); // Used when trying to withdraw Ether but there's nothing to withdraw.
    error FailedToWithdrawEth(address owner, address target, uint256 value); // Used when the withdrawal of Ether fails.
    error DestinationChainNotAllowed(uint64 destinationChainSelector); // Used when the destination chain has not been allowlisted by the contract owner.
    error SourceChainNotAllowed(uint64 sourceChainSelector); // Used when the source chain has not been allowlisted by the contract owner.
    error SenderNotAllowed(uint64 sourceChainSelector, address sender); // Used when the sender has not been allowlisted by the contract owner.
    error InvalidReceiverAddress(); // Used when the receiver address is 0.
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
        address receiverContract, // The address of the receiver contract on the destination chain.
        address receiver, //The final receiver of sent tokens
        uint256 timestamp, // The timestamp being sent.
        uint256 exchangeRate, // The exchange rate that was sent
        address token, // The token address that was transferred.
        uint256 tokenAmount, // The token amount that was transferred.
        address feeToken, // the token address used to pay CCIP fees.
        uint256 fees // The fees paid for sending the message.
    );

    // Event emitted when a message is received from another chain.
    event MessageReceived(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed sourceChainSelector, // The chain selector of the source chain.
        address sender, // The address of the sender from the source chain.
        address receiver, //The final receiver of sent tokens.
        uint256 timestamp, // The timestamp that was received.
        uint256 exchangeRate, // The exchange rate that was received.
        address token, // The token address that was transferred.
        uint256 tokenAmount // The token amount that was transferred.
    );

    event MessageFailed(bytes32 indexed messageId, bytes reason);
    event MessageRecovered(bytes32 indexed messageId);

    bool public isCanonical; // Indicate whether or not the contract exists on the same chain as the main sDOLA contract
    uint public additionalGasLimit = 400_000; //The additional gas limit used for calling contract functions on the receiving network 
    address public exchangeRateProvider; //Address to call for sDOLA exchange rate reads and updates

    // Mapping to keep track of allowlisted destination chains.
    mapping(uint64 => bool) public allowlistedDestinationChains;

    // Mapping to keep track of allowlisted source chains.
    mapping(uint64 => bool) public allowlistedSourceChains;

    // Mapping to keep track of allowlisted senders for each network.
    mapping(uint64 => mapping(address => bool)) public allowlistedSenders;

    // Mapping to keep track of when another network was last updated.
    mapping(uint64 => uint256) public lastUpdate;

    IERC20 private s_linkToken;
    IERC20 public token;

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
    constructor(address _router, address _token, address _link, address _exchangeRateProvider, bool _isCanonical) CCIPReceiver(_router) {
        s_linkToken = IERC20(_link);
        token = IERC20(_token);
        isCanonical = _isCanonical;
        exchangeRateProvider = _exchangeRateProvider;
    }

    /// @dev Modifier that checks if the chain with the given destinationChainSelector is allowlisted.
    /// @param _destinationChainSelector The selector of the destination chain.
    modifier onlyAllowlistedDestinationChain(uint64 _destinationChainSelector) {
        if (!allowlistedDestinationChains[_destinationChainSelector])
            revert DestinationChainNotAllowed(_destinationChainSelector);
        _;
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
    /// @param _receiver The receiver address.
    modifier validateReceiver(address _receiver) {
        if (_receiver == address(0)) revert InvalidReceiverAddress();
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
    /// @param allowed The allowlist status to be set for the destination chain.
    function allowlistDestinationChain(
        uint64 _destinationChainSelector,
        bool allowed
    ) external onlyOwner {
        allowlistedDestinationChains[_destinationChainSelector] = allowed;
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
    /// @param _receiver The address of the recipient on the destination blockchain.
    /// @param _amount token amount.
    /// @return messageId The ID of the CCIP message that was sent.
    function sendMessagePayLINK(
        uint64 _destinationChainSelector,
        address _receiverContract,
        address _receiver,
        uint256 _amount
    )
        external
        onlyAllowlistedDestinationChain(_destinationChainSelector)
        validateReceiver(_receiverContract)
        returns (bytes32 messageId)
    {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // address(linkToken) means fees are paid in LINK
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            _receiverContract,
            _receiver,
            address(token),
            _amount,
            address(s_linkToken)
        );

        //Update the last time this network had its price updated
        lastUpdate[_destinationChainSelector] = block.timestamp;

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

        // Transfer sender tokens to contract from msg.sender
        token.transferFrom(msg.sender, address(this), _amount);

        // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
        token.approve(address(router), _amount);

        // Send the message through the router and store the returned message ID
        messageId = router.ccipSend(_destinationChainSelector, evm2AnyMessage);

        // Emit an event with message details
        emit MessageSent(
            messageId,
            _destinationChainSelector,
            _receiverContract,
            _receiver,
            block.timestamp,
            getExchangeRate(),
            address(token),
            _amount,
            address(s_linkToken),
            fees
        );

        // Return the message ID
        return messageId;
    }

    /// @notice Sends data and transfer tokens to message sender on the destination chain.
    /// @notice Pay for fees in native gas.
    /// @dev Assumes your contract has sufficient native gas like ETH on Ethereum or MATIC on Polygon.
    /// @param _destinationChainSelector The identifier (aka selector) for the destination blockchain.
    /// @param _receiverContract The address of the recipient contract on the destination blockchain.
    /// @param _amount token amount.
    /// @return messageId The ID of the CCIP message that was sent.
    function sendMessagePayNative(
        uint64 _destinationChainSelector,
        address _receiverContract,
        uint256 _amount
    )
        public
        payable
        returns (bytes32 messageId)
    {
        return sendMessagePayNative(_destinationChainSelector, _receiverContract, msg.sender, _amount);
    }

    /// @notice Sends data and transfer tokens to receiver on the destination chain.
    /// @notice Pay for fees in native gas.
    /// @dev Assumes your contract has sufficient native gas like ETH on Ethereum or MATIC on Polygon.
    /// @param _destinationChainSelector The identifier (aka selector) for the destination blockchain.
    /// @param _receiverContract The address of the recipient contract on the destination blockchain.
    /// @param _receiver The address to send tokens to
    /// @param _amount token amount.
    /// @return messageId The ID of the CCIP message that was sent.
    function sendMessagePayNative(
        uint64 _destinationChainSelector,
        address _receiverContract,
        address _receiver,
        uint256 _amount
    )
        public
        payable
        onlyAllowlistedDestinationChain(_destinationChainSelector)
        validateReceiver(_receiverContract)
        returns (bytes32 messageId)
    {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // address(0) means fees are paid in native gas
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            _receiverContract,
            _receiver,
            address(token),
            _amount,
            address(0)
        );

        //Update the last time this network had its price updated
        lastUpdate[_destinationChainSelector] = getLastUpdate();

        // Initialize a router client instance to interact with cross-chain router
        IRouterClient router = IRouterClient(this.getRouter());
        
        // Get the fee required to send the CCIP message
        uint256 fees = router.getFee(_destinationChainSelector, evm2AnyMessage);
        
        if (fees > address(this).balance)
            revert NotEnoughBalance(address(this).balance, fees);
        
        // Transfer sender tokens to contract from msg.sender
        token.transferFrom(msg.sender, address(this), _amount);
        
        // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
        token.approve(address(router), _amount);

        // Send the message through the router and store the returned message ID
        messageId = router.ccipSend{value: fees}(
            _destinationChainSelector,
            evm2AnyMessage
        );
        

        // Emit an event with message details
        emit MessageSent(
            messageId,
            _destinationChainSelector,
            _receiverContract,
            _receiver,
            block.timestamp,
            getExchangeRate(),
            address(token),
            _amount,
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
    /// @param tokenReceiver The address to which the tokens will be sent.
    /// @dev This function is only callable by the contract owner. It changes the status of the message
    /// from 'failed' to 'resolved' to prevent reentry and multiple retries of the same message.
    function retryFailedMessage(
        bytes32 messageId,
        address tokenReceiver
    ) external onlyOwner {
        // Check if the message has failed; if not, revert the transaction.
        if (s_failedMessages.get(messageId) != uint256(ErrorCode.FAILED))
            revert MessageNotFailed(messageId);

        // Set the error code to RESOLVED to disallow reentry and multiple retries of the same failed message.
        s_failedMessages.set(messageId, uint256(ErrorCode.RESOLVED));

        // Retrieve the content of the failed message.
        Client.Any2EVMMessage memory message = s_messageContents[messageId];

        // This example expects one token to have been sent, but you can handle multiple tokens.
        // Transfer the associated tokens to the specified receiver as an escape hatch.
        IERC20(message.destTokenAmounts[0].token).transfer(
            tokenReceiver,
            message.destTokenAmounts[0].amount
        );

        // Emit an event indicating that the message has been recovered.
        emit MessageRecovered(messageId);
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        (uint256 s_lastReceivedTimestamp, uint256 s_lastReceivedExchangeRate, address s_lastReceiver) = abi.decode(any2EvmMessage.data, (uint, uint, address)); // abi-decoding of the sent timestamp and exchangerate
        // Expect one token to be transferred at once, but you can transfer several tokens.
        uint256 s_lastReceivedTokenAmount = any2EvmMessage.destTokenAmounts[0].amount;
        token.transfer(s_lastReceiver, s_lastReceivedTokenAmount);
        if(!isCanonical){
            IExchangeRateProvider(exchangeRateProvider).setExchangeRate(s_lastReceivedExchangeRate);
            IExchangeRateProvider(exchangeRateProvider).setLastUpdate(s_lastReceivedTimestamp);
        }
        emit MessageReceived(
            any2EvmMessage.messageId,
            any2EvmMessage.sourceChainSelector, // fetch the source chain identifier (aka selector)
            abi.decode(any2EvmMessage.sender, (address)), // abi-decoding of the sender address,
            s_lastReceiver,
            s_lastReceivedTimestamp,
            s_lastReceivedExchangeRate,
            address(token),
            s_lastReceivedTokenAmount
        );
    }

    /// @notice Construct a CCIP message.
    /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for programmable tokens transfer.
    /// @param _receiver The address of the receiver.
    /// @param _token The token to be transferred.
    /// @param _amount The amount of the token to be transferred.
    /// @param _feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
    function _buildCCIPMessage(
        address _receiverContract,
        address _receiver,
        address _token,
        uint256 _amount,
        address _feeTokenAddress
    ) private view returns (Client.EVM2AnyMessage memory) {
        // Set the token amounts
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({
            token: _token,
            amount: _amount
        });
        tokenAmounts[0] = tokenAmount;
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiverContract), // ABI-encoded receiver address
            data: abi.encode(getLastUpdate(), getExchangeRate(), _receiver), // ABI-encoded uint
            tokenAmounts: tokenAmounts, // The amount and type of token being transferred
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

    /// @notice Allows the owner of the contract to withdraw all tokens of a specific ERC20 token.
    /// @dev This function reverts with a 'NothingToWithdraw' error if there are no tokens to withdraw.
    /// @param _beneficiary The address to which the tokens will be sent.
    /// @param _token The contract address of the ERC20 token to be withdrawn.
    function withdrawToken(
        address _beneficiary,
        address _token
    ) public onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = IERC20(_token).balanceOf(address(this));

        // Revert if there is nothing to withdraw
        if (amount == 0) revert NothingToWithdraw();

        IERC20(_token).transfer(_beneficiary, amount);
    }
}

