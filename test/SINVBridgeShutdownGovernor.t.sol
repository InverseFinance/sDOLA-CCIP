// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {GovernanceSender} from "src/GovernanceSender.sol";
import {SINVBridgeShutdownGovernor} from "src/SINVBridgeShutdownGovernor.sol";

contract SINVMockRouter is IRouterClient {
    uint256 public fee = 0.1 ether;
    uint256 public sends;
    uint64 public lastDestinationChainSelector;
    bytes public lastReceiver;
    bytes public lastData;
    bytes public lastExtraArgs;
    mapping(uint256 sendIndex => uint64 destinationChainSelector) public destinationChainSelectorsBySend;
    mapping(uint256 sendIndex => bytes receiver) public receiversBySend;
    mapping(uint256 sendIndex => bytes data) public dataBySend;
    mapping(uint256 sendIndex => bytes extraArgs) public extraArgsBySend;

    function setFee(uint256 newFee) external {
        fee = newFee;
    }

    function isChainSupported(uint64) external pure returns (bool) {
        return true;
    }

    function getSupportedTokens(uint64) external pure returns (address[] memory tokens) {
        tokens = new address[](0);
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external view returns (uint256) {
        return fee;
    }

    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32 messageId)
    {
        require(msg.value == fee, "unexpected fee");

        ++sends;
        lastDestinationChainSelector = destinationChainSelector;
        lastReceiver = message.receiver;
        lastData = message.data;
        lastExtraArgs = message.extraArgs;
        destinationChainSelectorsBySend[sends] = destinationChainSelector;
        receiversBySend[sends] = message.receiver;
        dataBySend[sends] = message.data;
        extraArgsBySend[sends] = message.extraArgs;

        messageId = keccak256(abi.encode(sends, destinationChainSelector, message.receiver, message.data));
    }
}

contract SINVBridgeShutdownGovernorTest is Test {
    address internal owner = address(0xA11CE);
    address payable internal beneficiary = payable(address(0xBEEF));

    SINVMockRouter internal router;
    GovernanceSender internal governanceSender;
    SINVBridgeShutdownGovernor internal shutdownGovernor;

    function setUp() external {
        router = new SINVMockRouter();
        governanceSender = _installGovernanceSender(address(router));
        shutdownGovernor = new SINVBridgeShutdownGovernor(owner);

        assertEq(address(shutdownGovernor.governanceSender()), shutdownGovernor.GOVERNANCE_SENDER_ADDRESS());

        governanceSender.allowlistGovernanceProxy(
            shutdownGovernor.BASE_CHAIN_SELECTOR(), shutdownGovernor.BASE_GOVERNANCE_PROXY()
        );
        governanceSender.allowlistGovernanceProxy(
            shutdownGovernor.OPTIMISM_CHAIN_SELECTOR(), shutdownGovernor.OPTIMISM_GOVERNANCE_PROXY()
        );
        governanceSender.allowlistGovernanceProxy(
            shutdownGovernor.ARBITRUM_CHAIN_SELECTOR(), shutdownGovernor.ARBITRUM_GOVERNANCE_PROXY()
        );

        governanceSender.transferOwnership(address(shutdownGovernor));

        vm.prank(owner);
        shutdownGovernor.acceptGovernanceSenderOwnership();
    }

    function testAcceptGovernanceSenderOwnershipAllowlistsShutdownGovernor() external {
        assertEq(governanceSender.owner(), address(shutdownGovernor));
        assertTrue(governanceSender.allowListedCallers(address(shutdownGovernor)));
    }

    function testGovernanceProxiesArePreConfiguredOnSender() external {
        assertEq(
            governanceSender.governanceProxies(shutdownGovernor.BASE_CHAIN_SELECTOR()),
            shutdownGovernor.BASE_GOVERNANCE_PROXY()
        );
        assertEq(
            governanceSender.governanceProxies(shutdownGovernor.OPTIMISM_CHAIN_SELECTOR()),
            shutdownGovernor.OPTIMISM_GOVERNANCE_PROXY()
        );
        assertEq(
            governanceSender.governanceProxies(shutdownGovernor.ARBITRUM_CHAIN_SELECTOR()),
            shutdownGovernor.ARBITRUM_GOVERNANCE_PROXY()
        );
    }

    function testExecuteL2ShutdownFundsSenderAndSendsFixedBatch() external {
        router.setFee(0.1 ether);

        uint256 messageCount = shutdownGovernor.L2_SHUTDOWN_MESSAGE_COUNT();
        uint256 feeBudget = messageCount * router.fee();

        vm.deal(owner, feeBudget);
        vm.prank(owner);
        bytes32[] memory messageIds = shutdownGovernor.executeL2Shutdown{value: feeBudget}();

        assertEq(messageIds.length, messageCount);
        assertEq(router.sends(), messageCount);
        assertEq(address(governanceSender).balance, 0);
        assertEq(router.lastDestinationChainSelector(), shutdownGovernor.ARBITRUM_CHAIN_SELECTOR());
        assertEq(router.lastReceiver(), abi.encode(shutdownGovernor.ARBITRUM_GOVERNANCE_PROXY()));
        assertEq(
            router.lastData(),
            abi.encode(
                shutdownGovernor.ARB_PROGRAMMABLE_BRIDGE(),
                abi.encodeWithSignature(
                    "allowlistSender(address,uint64,bool)",
                    shutdownGovernor.BASE_PROGRAMMABLE_BRIDGE(),
                    shutdownGovernor.BASE_CHAIN_SELECTOR(),
                    false
                )
            )
        );
        assertGt(uint256(messageIds[0]), 0);
        assertGt(uint256(messageIds[messageIds.length - 1]), 0);
        assertTrue(messageIds[0] != messageIds[messageIds.length - 1]);

        assertEq(router.destinationChainSelectorsBySend(1), shutdownGovernor.BASE_CHAIN_SELECTOR());
        assertEq(router.receiversBySend(1), abi.encode(shutdownGovernor.BASE_GOVERNANCE_PROXY()));
        assertEq(
            router.dataBySend(1),
            abi.encode(
                shutdownGovernor.BASE_PROGRAMMABLE_BRIDGE(),
                abi.encodeWithSignature(
                    "allowlistDestinationChain(uint64,bool)", shutdownGovernor.ARBITRUM_CHAIN_SELECTOR(), false
                )
            )
        );
    }

    function testWithdrawPullsFromShutdownGovernorAndGovernanceSender() external {
        vm.deal(address(governanceSender), 1 ether);
        vm.deal(address(shutdownGovernor), 0.5 ether);

        uint256 beforeBalance = beneficiary.balance;

        vm.prank(owner);
        shutdownGovernor.withdraw(beneficiary);

        assertEq(beneficiary.balance - beforeBalance, 1.5 ether);
        assertEq(address(governanceSender).balance, 0);
        assertEq(address(shutdownGovernor).balance, 0);
    }

    function testTransferGovernanceSenderOwnershipDisablesShutdownCaller() external {
        address nextOwner = address(0x1234);

        vm.prank(owner);
        shutdownGovernor.transferGovernanceSenderOwnership(nextOwner);

        assertFalse(governanceSender.allowListedCallers(address(shutdownGovernor)));

        vm.prank(nextOwner);
        governanceSender.acceptOwnership();

        assertEq(governanceSender.owner(), nextOwner);
    }

    function testOnlyOwnerCanExecuteL2Shutdown() external {
        vm.expectRevert("Only callable by owner");
        shutdownGovernor.executeL2Shutdown();
    }

    function _installGovernanceSender(address router_) internal returns (GovernanceSender installedGovernanceSender) {
        GovernanceSender implementation = new GovernanceSender(router_);
        address senderAddress = 0xAeA8Ae87A34a0fAaEa0e6beD9f4627F576B524Fa;

        vm.etch(senderAddress, address(implementation).code);
        vm.store(senderAddress, bytes32(uint256(0)), bytes32(uint256(uint160(address(this)))));
        vm.store(senderAddress, bytes32(uint256(4)), bytes32(uint256(uint160(router_))));

        installedGovernanceSender = GovernanceSender(payable(senderAddress));
    }
}
