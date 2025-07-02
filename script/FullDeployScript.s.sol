pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {ERC20Mintable} from "src/ReceiptToken.sol";
import {ExchangeRateUpdater} from "src/ExchangeRateUpdater.sol";
import {ExchangeRateProvider} from "src/ExchangeRateProvider.sol";
import {VaultExchangeRateProvider} from "src/VaultExchangeRateProvider.sol";
import {GovernanceSender} from "src/GovernanceSender.sol";
import {GovernanceProxy} from "src/GovernanceProxy.sol";
import {AddrConfig} from "./AddrConfig.sol";

interface IRegistryModuleOwnerCustom {
    function registerAdminViaOwner(address) external;
}

interface ITokenAdminRegistry {
    function acceptAdminRole(address token) external;
    function setPool(address token, address tokenPool) external;
    function isAdministrator(address token, address admin) external returns(bool);
}

interface ITokenPoolFactory {
    function deployTokenPool(address token) external returns(address tokenPool);
}

interface ITokenPool {
    function applyChainUpdates(uint64[] memory, AddrConfig.ChainUpdate[] memory) external;
}

interface IOwnable {
    function transferOwnership(address) external;
    function acceptOwnership() external;
}

interface IExchangeRateUpdater {
    function setDestinationChainUpdater(uint64, address) external;
    function allowlistSourceChain(uint64, bool) external;
    function allowlistSender(address, uint64, bool) external;
}

contract FullDeploy is Script, AddrConfig {
    
    uint8 decimals = 18;
    string symbol = "sDOLA";
    string name = "Staked DOLA";
    address broadcaster = 0x11EC78492D53c9276dD7a184B1dbfB34E50B710D;
    address canonicalVault = 0xb45ad160634c528Cc3D2926d9807104FA3157305;
    uint canonicalChainId = 1;
    mapping(uint64 => uint) forks;
    NetworkConfig[] networks;
    NetworkConfig networkConfig;

    function run() external {
        networks.push(mainnetSepolia);
        networks.push(arbitrumSepolia);
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        for(uint i; i < networks.length; i++){
            networkConfig = networks[i]; //Inherited from AddrConfig
          
            //deploy token
            forks[networkConfig.chainSelector] = vm.createSelectFork(networkConfig.network);
            vm.startBroadcast(deployerPrivateKey);
            if(networkConfig.token == address(0))
                networkConfig.token = address(new ERC20Mintable(name, symbol, decimals));

            console.log("Deploying on network:", networkConfig.network);
            console.log("Receipt token deployed to address:", networkConfig.token);
            
            if(block.chainid == canonicalChainId){
                VaultExchangeRateProvider erp = new VaultExchangeRateProvider(canonicalVault);
                console.log("Vault Exchange Rate Provider deployed to address:", address(erp));

                if(networkConfig.exchangeRateUpdater == address(0))
                    networkConfig.exchangeRateUpdater = address(new ExchangeRateUpdater(networkConfig.router, networkConfig.link, address(erp), true));
                console.log("ExchangeRateUpdater deployed to address:", networkConfig.exchangeRateUpdater);
            } else {
                if(networkConfig.exchangeRateUpdater == address(0))
                    networkConfig.exchangeRateUpdater = address(new ExchangeRateUpdater(networkConfig.router, networkConfig.link, networkConfig.token, false));
                console.log("ExchangeRateUpdater deployed to address:", networkConfig.exchangeRateUpdater);
                console.log("Setting ExchangeRateUpdater", networkConfig.exchangeRateUpdater, "to be updater of ReceiptToken", networkConfig.token);
                ERC20Mintable(networkConfig.token).setUpdater(networkConfig.exchangeRateUpdater, true);          
            }

            //claim admin via self-serve
            if(!ITokenAdminRegistry(networkConfig.tokenAdminRegistry).isAdministrator(networkConfig.token, broadcaster)){
                console.log("Current token owner:", ERC20Mintable(networkConfig.token).owner());
                console.log("Claiming admin of the token via owner() for signer:", msg.sender);
                IRegistryModuleOwnerCustom(networkConfig.registryModuleOwnerCustom).registerAdminViaOwner(networkConfig.token);
                console.log("Admin claimed successfuly for token:", networkConfig.token);

                //accept admin
                console.log("Accepting admin of:", networkConfig.token);
                ITokenAdminRegistry(networkConfig.tokenAdminRegistry).acceptAdminRole(networkConfig.token);
            }

            //Deploy token pool
            if(networkConfig.tokenPool == address(0)){
                if(networkConfig.tokenPoolFactory == address(0)) revert("Network TokenPoolFactory not set");
                networkConfig.tokenPool = address(ITokenPoolFactory(networkConfig.tokenPoolFactory).deployTokenPool(networkConfig.token));
                console.log("Token pool deployed to:", networkConfig.tokenPool);
                IOwnable(networkConfig.tokenPool).acceptOwnership();
                console.log("Ownership of token pool transferred to:", msg.sender);
                ERC20Mintable(networkConfig.token).setMinter(networkConfig.tokenPool, true);
                console.log("Granted minting rights to tokenPool:", networkConfig.tokenPool);

                //Set pool
                console.log("Setting pool:", networkConfig.tokenPool," for token:", networkConfig.token);
                ITokenAdminRegistry(networkConfig.tokenAdminRegistry).setPool(networkConfig.token, networkConfig.tokenPool);
                networks[i] = networkConfig;
            }
            vm.stopBroadcast();
            console.log("  tokenPool:", networkConfig.tokenPool ,",");
            console.log("  token:", networkConfig.token ,",");
            console.log("  exchangeRateUpdater:", networkConfig.exchangeRateUpdater ,",");
        }

        for(uint i; i < networks.length; i++){
            networkConfig = networks[i];
            vm.selectFork(forks[networkConfig.chainSelector]);
            vm.startBroadcast(deployerPrivateKey);
            for(uint j; j < networks.length; j++){
                NetworkConfig memory destinationNetwork = networks[j];
                if(networkConfig.chainSelector != destinationNetwork.chainSelector){
                    console.log("Configuring chain updates on network", networkConfig.network, "for network", destinationNetwork.network);
                    bytes[] memory remotePoolAddressesEncoded = new bytes[](1);
                    remotePoolAddressesEncoded[0] = abi.encode(destinationNetwork.tokenPool);
                    ChainUpdate[] memory chainUpdates = new ChainUpdate[](1);
                    chainUpdates[0] = ChainUpdate({
                        remoteChainSelector: destinationNetwork.chainSelector, // Chain selector of the remote chain
                        remotePoolAddresses: remotePoolAddressesEncoded, // Array of encoded addresses of the remote pools
                        remoteTokenAddress: abi.encode(destinationNetwork.token), // Encoded address of the remote token
                        outboundRateLimiterConfig: RateLimiterConfig({
                            isEnabled: false, // Set to true to enable outbound rate limiting
                            capacity: 0, // Max tokens allowed in the outbound rate limiter
                            rate: 0 // Refill rate per second for the outbound rate limiter
                        }),
                        inboundRateLimiterConfig: RateLimiterConfig({
                            isEnabled: false, // Set to true to enable inbound rate limiting
                            capacity: 0, // Max tokens allowed in the inbound rate limiter
                            rate: 0 // Refill rate per second for the inbound rate limiter
                        })
                    });
                    uint64[] memory chainSelectorRemovals = new uint64[](0);
                    ITokenPool(networkConfig.tokenPool).applyChainUpdates(chainSelectorRemovals, chainUpdates);
                    IExchangeRateUpdater eru = IExchangeRateUpdater(networkConfig.exchangeRateUpdater);
                    console.log("Configuring ExchangeRateUpdater on network", networkConfig.network, "for network", destinationNetwork.network);
                    eru.setDestinationChainUpdater(
                        destinationNetwork.chainSelector,
                        destinationNetwork.exchangeRateUpdater
                    );
                    eru.allowlistSender(destinationNetwork.exchangeRateUpdater, destinationNetwork.chainSelector, true);
                    eru.allowlistSourceChain(destinationNetwork.chainSelector, true);
                }
            }
            vm.stopBroadcast();
        }
        //Deploy Governance Sender on mainnet
        NetworkConfig memory mainnet = networks[0];
        vm.selectFork(forks[mainnet.chainSelector]);
        vm.startBroadcast(deployerPrivateKey);
        GovernanceSender govSender = new GovernanceSender(mainnet.router);
        payable(govSender).transfer(0.005 ether);
        govSender.allowlistCaller(broadcaster, true);
        govSender.transferOwnership(mainnet.gov);
        vm.stopBroadcast();
        console.log("Deployed GovernanceSender to address:", address(govSender));
        console.log("- On network:", mainnet.network);
        console.log("- Selector:", uint(mainnet.chainSelector));

        //Deploy Governance Proxy on L2s
        for(uint i=1; i < networks.length; i++){
            networkConfig = networks[i];
            vm.selectFork(forks[networkConfig.chainSelector]);
            vm.broadcast(deployerPrivateKey);
            GovernanceProxy govProxy = new GovernanceProxy(networkConfig.router, address(govSender), mainnet.chainSelector);
            console.log("Deployed GovernanceProxy to address:", address(govProxy));
            console.log("- On network:", networkConfig.network);
            console.log("- Selector:", uint(networkConfig.chainSelector));
            vm.selectFork(forks[mainnet.chainSelector]);
            vm.broadcast(deployerPrivateKey);
            govSender.allowlistGovernanceProxy(networkConfig.chainSelector, address(govProxy));
            networks[i].gov = address(govProxy);
        }
        
        //Transfer Governance
        for(uint i; i < networks.length; i++){
            networkConfig = networks[i];
            require(networkConfig.gov != address(0), "Gov not set");
            vm.selectFork(forks[networkConfig.chainSelector]);
            vm.startBroadcast(deployerPrivateKey);
            console.log("Setting pending owner for token, tokenPool and exchangeRateUpdater as:", networkConfig.gov);
            ERC20Mintable(networkConfig.token).setPendingOwner(networkConfig.gov);
            IOwnable(networkConfig.tokenPool).transferOwnership(networkConfig.gov);
            IOwnable(networkConfig.exchangeRateUpdater).transferOwnership(networkConfig.gov);
            vm.stopBroadcast();
            if(networkConfig.chainSelector != mainnet.chainSelector){
                vm.selectFork(forks[mainnet.chainSelector]);
                vm.startBroadcast(deployerPrivateKey);
                bytes memory data = abi.encodeWithSelector(ExchangeRateProvider.acceptOwner.selector);
                bytes32 messageId = govSender.sendMessagePayNative(networkConfig.chainSelector, networkConfig.token, data, 200_000);
                console.log("MessageId for accepting ownership of ReceiptToken on network", networkConfig.network);
                console.logBytes32(messageId);
                data = abi.encodeWithSelector(IOwnable.acceptOwnership.selector);
                govSender.sendMessagePayNative(networkConfig.chainSelector, networkConfig.tokenPool, data, 200_000);
                console.log("MessageId for accepting ownership of tokenPool on network", networkConfig.network);
                console.logBytes32(messageId);
                govSender.sendMessagePayNative(networkConfig.chainSelector, networkConfig.exchangeRateUpdater, data, 200_000);
                console.log("MessageId for accepting ownership of ExchangeRateUpdater on network", networkConfig.network);
                console.logBytes32(messageId);
                vm.stopBroadcast();
            }
        }
        vm.selectFork(forks[mainnet.chainSelector]);
        vm.broadcast(deployerPrivateKey);
        govSender.allowlistCaller(broadcaster, false);
    }
}
