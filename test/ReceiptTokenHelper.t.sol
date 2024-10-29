pragma solidity ^0.8.19;
import "forge-std/Test.sol";
import "src/ReceiptTokenHelper.sol";
import "src/GovernanceSender.sol";

contract ReceiptTokenHelperTest is Test {
    address owner = 0x11EC78492D53c9276dD7a184B1dbfB34E50B710D; //gov
    address l2ReceiptToken;
    GovernanceSender sender = GovernanceSender(payable(0xAeA8Ae87A34a0fAaEa0e6beD9f4627F576B524Fa));
    ReceiptTokenHelper helper;
    uint64 l2ChainSelector = 15971525489660198786;
    address GovernanceProxy = 0x5D5392505ee69f9FE7a6a1c1AF14f17Db3B3e364;
    uint l1Fork;

    function setUp() external {
        string memory mainnetRPC = vm.envString("RPC_MAINNET");
        helper = new ReceiptTokenHelper(owner, address(sender));
        l1Fork = vm.createSelectFork(mainnetRPC);
    }

    function testCallerNotAllowed() external {
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceSender.CallerNotAllowListed.selector, address(helper))
        );
        vm.prank(owner);
        helper.setMinter(l2ChainSelector, l2ReceiptToken, owner, true);
    }

    function testCallerAllowed() external {
        vm.startPrank(owner);
        sender.allowlistCaller(address(helper), true);
        helper.setMinter(l2ChainSelector, l2ReceiptToken, owner, true);
    }

    function testCallerNotOwner() external {
        vm.expectRevert(
            abi.encodeWithSelector(ReceiptTokenHelper.OnlyGovernance.selector)
        );
        helper.setMinter(l2ChainSelector, l2ReceiptToken, owner, true);

        vm.expectRevert(
            abi.encodeWithSelector(ReceiptTokenHelper.OnlyGovernance.selector)
        );
        helper.setUpdater(l2ChainSelector, l2ReceiptToken, owner, true);

        vm.expectRevert(
            abi.encodeWithSelector(ReceiptTokenHelper.OnlyGovernance.selector)
        );
        helper.setPendingOwner(l2ChainSelector, l2ReceiptToken, owner);

        vm.expectRevert(
            abi.encodeWithSelector(ReceiptTokenHelper.OnlyGovernance.selector)
        );
        helper.acceptOwner(l2ChainSelector, l2ReceiptToken);

        vm.expectRevert(
            abi.encodeWithSelector(ReceiptTokenHelper.OnlyGovernance.selector)
        );
        helper.setGov(owner);
    }

    function testSetGov() external {
        address prevGov = helper.gov();
        vm.prank(owner);
        helper.setGov(address(0xdead));
        assert(prevGov != helper.gov());
        assertEq(address(0xdead), helper.gov());
    }
}
