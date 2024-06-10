## Inverse Finance sDOLA Bridge

> **Note**
>
> _This repository is based off of the Chainlink CCIP starter kit, but is modified to be used for the Inverse Finance sDOLA/sINV tokens.
> The bridge uses the Chainlink CCIP protocol to bridge auto-compounding sTokens to L2s along with exchange data, allowing partner protocols to have an updated but lagging estimate of the mainnet value of the tokens.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

## Getting Started

1. Install packages

```
forge install
```

and

```
npm install
```

2. Compile contracts

```
forge build
```

## What is Chainlink CCIP?

**Chainlink Cross-Chain Interoperability Protocol (CCIP)** provides a single, simple, and elegant interface through which dApps and web3 entrepreneurs can securely meet all their cross-chain needs, including token transfers and arbitrary messaging.

![basic-architecture](./img/basic-architecture.png)

With Chainlink CCIP, one can:

- Transfer supported tokens
- Send messages (any data)
- Send messages and tokens

CCIP receiver can be:

- Smart contract that implements `CCIPReceiver.sol`
- EOA

**Note**: If you send a message and token(s) to EOA, only tokens will arrive
