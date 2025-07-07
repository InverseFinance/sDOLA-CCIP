pragma solidity ^0.8.20;

contract AddrConfig {

    struct NetworkConfig {
        string network;
        uint64 chainSelector;
        address tokenAdminRegistry;
        address registryModuleOwnerCustom;
        address rmnProxy;
        address router;
        address link;
        address tokenPoolFactory;
        address gov;
        address tokenPool;
        address token;
        address exchangeRateUpdater;
    }

    struct RateLimiterConfig {
        bool isEnabled;
        uint128 capacity; //TODO: Make sure uint is correct type
        uint128 rate; //TODO: Make sure uint is correct type
    }

    struct ChainUpdate {
        uint64 remoteChainSelector;
        bytes[] remotePoolAddresses;
        bytes remoteTokenAddress;
        RateLimiterConfig outboundRateLimiterConfig;
        RateLimiterConfig inboundRateLimiterConfig;
    }

    struct EVMTokenAmount {
        address token;
        uint256 amount;
    }

    struct EVM2AnyMessage {
        bytes receiver;
        bytes data;
        EVMTokenAmount[] tokenAmounts;
        address feeToken;
        bytes extraArgs;
    }

    RateLimiterConfig public basicRateLimiterConfig = RateLimiterConfig({
        isEnabled:false,
        capacity:0,
        rate:0
    });

    NetworkConfig public mainnetSepolia = NetworkConfig({
        network: "ethereumSepolia",
        chainSelector:16015286601757825753,
        tokenAdminRegistry:0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82,
        registryModuleOwnerCustom:0x62e731218d0D47305aba2BE3751E7EE9E5520790,
        rmnProxy:0xba3f6251de62dED61Ff98590cB2fDf6871FbB991,
        router:0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59,
        link:0x779877A7B0D9E8603169DdbD7836e478b4624789,
        tokenPoolFactory:0xB86905871AfFef6b12FcF964bfCD415f211894FF,
        gov: address(1),
        tokenPool: address(0),
        token: address(0),
        exchangeRateUpdater: address(0)
    });

    NetworkConfig public arbitrumSepolia = NetworkConfig({
        network: "arbitrumSepolia",
        chainSelector: 3478487238524512106,
        tokenAdminRegistry:0x8126bE56454B628a88C17849B9ED99dd5a11Bd2f,
        registryModuleOwnerCustom:0xE625f0b8b0Ac86946035a7729Aba124c8A64cf69,
        rmnProxy:0x9527E2d01A3064ef6b50c1Da1C0cC523803BCFF2,
        router:0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165,
        link:0xb1D4538B4571d411F07960EF2838Ce337FE1E80E,
        tokenPoolFactory:0xC898BCf960c871C6b5d87249f4c76561F9f20299,
        gov: address(0),
        tokenPool: address(0),
        token: address(0),
        exchangeRateUpdater: address(0) 
    });

    NetworkConfig public mainnet = NetworkConfig({
        network: "mainnet",
        chainSelector:5009297550715157269,
        tokenAdminRegistry:0xb22764f98dD05c789929716D677382Df22C05Cb6,
        registryModuleOwnerCustom:0x4855174E9479E211337832E109E7721d43A4CA64,
        rmnProxy:0x411dE17f12D1A34ecC7F45f49844626267c75e81,
        router:0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D,
        link:0x514910771AF9Ca656af840dff83E8264EcF986CA,
        tokenPoolFactory: address(0),
        gov: 0x926dF14a23BE491164dCF93f4c468A50ef659D5B,
        tokenPool: address(0),
        token: 0xb45ad160634c528Cc3D2926d9807104FA3157305,
        exchangeRateUpdater: address(0)      
    });

    NetworkConfig public base = NetworkConfig({
        network: "base",
        chainSelector:15971525489660198786,
        tokenAdminRegistry:0x6f6C373d09C07425BaAE72317863d7F6bb731e37,
        registryModuleOwnerCustom:0xAFEd606Bd2CAb6983fC6F10167c98aaC2173D77f,
        rmnProxy:0xC842c69d54F83170C42C4d556B4F6B2ca53Dd3E8,
        router:0x881e3A65B4d4a04dD529061dd0071cf975F58bCD,
        link:0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196,
        tokenPoolFactory: address(0),
        gov: address(0),
        tokenPool: address(0),
        token: address(0),
        exchangeRateUpdater: address(0)
    });

    NetworkConfig public optimism = NetworkConfig({
        network: "optimism",
        chainSelector:3734403246176062136,
        tokenAdminRegistry:0x657c42abE4CD8aa731Aec322f871B5b90cf6274F,
        registryModuleOwnerCustom:0xAFEd606Bd2CAb6983fC6F10167c98aaC2173D77f,
        rmnProxy:0x55b3FCa23EdDd28b1f5B4a3C7975f63EFd2d06CE,
        router:0x3206695CaE29952f4b0c22a169725a865bc8Ce0f,
        link:0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6,
        tokenPoolFactory: address(0),
        gov: address(0),
        tokenPool: address(0),
        token: address(0),
        exchangeRateUpdater: address(0)        
    });

    NetworkConfig public arbitrum = NetworkConfig({
        network: "arbitrum",
        chainSelector:4949039107694359620,
        tokenAdminRegistry:0x39AE1032cF4B334a1Ed41cdD0833bdD7c7E7751E,
        registryModuleOwnerCustom:0x1f1df9f7fc939E71819F766978d8F900B816761b,
        rmnProxy:0xC311a21e6fEf769344EB1515588B9d535662a145,
        router:0x141fa059441E0ca23ce184B6A78bafD2A517DdE8,
        link:0xf97f4df75117a78c1A5a0DBb814Af92458539FB4,
        tokenPoolFactory: address(0),
        gov: address(0),
        tokenPool: address(0),
        token: address(0),
        exchangeRateUpdater: address(0)        
    });

    function getEVM2AnyMessage(uint amount, address token, address receiver) public pure returns(EVM2AnyMessage memory){
        EVM2AnyMessage memory message = EVM2AnyMessage({
            receiver: abi.encode(receiver), // Receiver address on the destination chain
            data: abi.encode(), // No additional data
            tokenAmounts: new EVMTokenAmount[](1), // Array of tokens to transfer
            feeToken: address(0), // Fee token (native or LINK)
            extraArgs: abi.encodePacked(
                bytes4(keccak256("CCIP EVMExtraArgsV1")), // Extra arguments for CCIP (versioned)
                abi.encode(uint256(0)) // Placeholder for future use
            )
        });

        // Set the token and amount to transfer
        message.tokenAmounts[0] = EVMTokenAmount({token: token, amount: amount});
        return message;
    }
}
