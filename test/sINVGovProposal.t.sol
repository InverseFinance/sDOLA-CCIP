import {Test, console2} from "forge-std/Test.sol";
import {GovernanceSender} from "src/GovernanceSender.sol";
import {ReceiptTokenHelper} from "src/ReceiptTokenHelper.sol";
import {ProgrammableDataTokenTransfers} from "src/ProgrammableDataTokenTransfers.sol";

contract sINVGovProposalTest is Test {

    GovernanceSender govSender = GovernanceSender(payable(0xAeA8Ae87A34a0fAaEa0e6beD9f4627F576B524Fa));
    ReceiptTokenHelper tokenHelper = ReceiptTokenHelper(0x5554Ea84a0cbA7EB1ff91DB9D9eA16e44cc087b2);
    address gov = 0x926dF14a23BE491164dCF93f4c468A50ef659D5B;
    uint64 baseSelector = 15971525489660198786;
    uint64 opSelector = 3734403246176062136;
    uint64 arbSelector = 4949039107694359620;
    address deployer = 0x11EC78492D53c9276dD7a184B1dbfB34E50B710D;
    address baseSINV = 0x8Bbd036d018657E454F679E7C4726F7a8ECE2773;
    address opSINV = 0x1992AF61FBf8ee38741bcc57d636CAA22A1a7702;
    address arbSINV = 0x4C7b266B4bf0A8758fa85E69292eE55c212236cF;
    address baseProg = 0x0173804066F7403E0815680F3DDa125a6cd10F7c;
    address arbProg = 0x0173804066F7403E0815680F3DDa125a6cd10F7c;
    address opProg = 0xb5A998E90AdeD2C97f7ceDbb7c45Bbc27E82dfdD;
    address baseGovProxy;
    address arbGovProxy;
    address opGovProxy;
    bytes acceptOwnership = vm.parseBytes("0x79ba5097");

    function testBatchCallExecutes() external {
        string memory mainnetL1RPC = vm.envString("RPC_MAINNET");
        vm.createSelectFork(mainnetL1RPC);
        vm.startPrank(gov);
        //Action 0
        govSender.allowlistCaller(gov, true);
        //Action 1
        govSender.allowlistCaller(deployer, false);
        //Action 2
        tokenHelper.setMinter(arbSelector, arbSINV, deployer, false);
        //Action 3
        tokenHelper.setMinter(baseSelector, baseSINV, deployer, false);
        //Action 4
        tokenHelper.setMinter(opSelector, opSINV, deployer, false);
        //Action 5
        tokenHelper.setUpdater(baseSelector, baseSINV, baseProg, true);
        //Action 6
        tokenHelper.setUpdater(opSelector, opSINV, opProg, true);
        //Action 7
        govSender.sendMessagePayNative(arbSelector, arbProg, acceptOwnership, 100000);
        //Action 8
        govSender.sendMessagePayNative(arbSelector, arbGovProxy, acceptOwnership, 100000);
        //Action 9
        govSender.sendMessagePayNative(baseSelector, baseProg, acceptOwnership, 100000);
        //Action 10
        govSender.sendMessagePayNative(baseSelector, baseGovProxy, acceptOwnership, 100000);
        //Action 11
        govSender.sendMessagePayNative(opSelector, opGovProxy, acceptOwnership, 100000);
        //Action 12
        govSender.sendMessagePayNative(opSelector, opProg, acceptOwnership, 100000);
        //Action 13
        tokenHelper.setUpdater(arbSelector, arbSINV, arbProg, true);
        //Action 14
        ProgrammableDataTokenTransfers(payable(0x70F3795c1EF726c58FfeA2e1A51526ac5707C066)).acceptOwnership();
    }
}
