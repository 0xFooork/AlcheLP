## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```
forge test --match-path test/UniswapLP.t.sol --match-test testSwapAndIncreaseLiquidity_WithWETH -vvvv --gas-report

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>

forge script script/DeployUniswapLP.s.sol:DeployUniswapLP \
  --rpc-url sepolia \
  --broadcast \
  --slow \
  --verify \
  -vvvv

forge script script/DeployUniswapLP.s.sol:DeployUniswapLP \
  --rpc-url mainnet \
  --broadcast \
  --slow \
  --verify \
  -vvvv

```

### Cast

```shell
cast to-unit $(cast gas-price --rpc-url sepolia) gwei

cast send $SEPOLIA_CONTRACT_ADDRESS \
"addToWhitelist(address[])" \
"[0xde05927035b51C5f6dE27b427e4649123723e141,0x5639Bc2D96c7bA37EECA625599B183241A2bBE6c]" \
--rpc-url sepolia \
--private-key $SEPOLIA_PRIVATE_KEY

cast send $SEPOLIA_CONTRACT_ADDRESS \
"swapAndMintLP(address,address,uint24,uint256,int24,int24,uint256,uint256)" \
0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 \
0xBF6e248D2CD92BC9930f0B0330d9C3B23Bc5B1F2 \
500 \
120000000000000000 \
191140 \
199360 \
50 \
$(date +%s --date='60 minutes') \
--value 120000000000000000 \
--rpc-url sepolia \
--gas-price 1gwei \
--priority-gas-price 0.05gwei \
--private-key $SEPOLIA_PRIVATE_KEY

cast send 0x1238536071E1c677A632429e3655c799b22cDA52 \
"createAndInitializePoolIfNecessary(address,address,uint24,uint160)" \
0xBF6e248D2CD92BC9930f0B0330d9C3B23Bc5B1F2 \
0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 \
500 \
1621018471240347964836283533141481 \
--rpc-url sepolia \
--private-key $SEPOLIA_PRIVATE_KEY

DEADLINE=$(($(cast block --rpc-url sepolia latest --field timestamp) + 3600))


cast send 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 \
"deposit()" \
--value 500000000000000000 \
--rpc-url sepolia \
--private-key $SEPOLIA_PRIVATE_KEY

cast send 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 \
"withdraw(uint256)" \
108000000000000000 \
--rpc-url sepolia \
--private-key $SEPOLIA_PRIVATE_KEY

cast send 0xBF6e248D2CD92BC9930f0B0330d9C3B23Bc5B1F2 \
"approve(address,uint256)" \
0x1238536071E1c677A632429e3655c799b22cDA52 \
1000000000000000000 \
--rpc-url sepolia \
--private-key $SEPOLIA_PRIVATE_KEY

cast send 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 \
"approve(address,uint256)" \
0x1238536071E1c677A632429e3655c799b22cDA52 \
500000000000000000 \
--rpc-url sepolia \
--private-key $SEPOLIA_PRIVATE_KEY

cast send 0x1238536071E1c677A632429e3655c799b22cDA52 \
"mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))" \
"(0xBF6e248D2CD92BC9930f0B0330d9C3B23Bc5B1F2,0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,500,191140,199360,1000000000000000000,500000000000000000,0,0,0x5639Bc2D96c7bA37EECA625599B183241A2bBE6c,$DEADLINE)" \
--rpc-url sepolia \
--private-key $SEPOLIA_PRIVATE_KEY


cast send 0x1238536071E1c677A632429e3655c799b22cDA52 \
"decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))" \
"(226658,16330183676448,21040998,108031210949569551,$DEADLINE)" \
--private-key $SEPOLIA_PRIVATE_KEY \
--rpc-url sepolia

cast call 0x1238536071E1c677A632429e3655c799b22cDA52 \
"decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))" \
"(226658,16330183676448,0,0,$DEADLINE)" \
--rpc-url sepolia

cast send 0x1238536071E1c677A632429e3655c799b22cDA52 \
"collect((uint256,address,uint128,uint128))" \
"(226658,0x5639Bc2D96c7bA37EECA625599B183241A2bBE6c,21040998,108032163031085095)" \
--private-key $SEPOLIA_PRIVATE_KEY \
--rpc-url sepolia

```

```shell
mainnet

cast send $ETHEREUM_CONTRACT_ADDRESS \
"addToWhitelist(address[])" \
"[0xde05927035b51C5f6dE27b427e4649123723e141]" \
--gas-price 0.5gwei \
--priority-gas-price 0.05gwei \
--rpc-url mainnet \
--private-key $ETHEREUM_PRIVATE_KEY

cast send $ETHEREUM_CONTRACT_ADDRESS \
"swapAndMintLP(address,address,uint24,uint256,int24,int24,uint256,uint256)" \
0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 \
500 \
124000000000000000 \
191140 \
199360 \
30 \
$(date +%s --date='60 minutes') \
--value 124000000000000000 \
--rpc-url mainnet \
--gas-price 0.5gwei \
--priority-gas-price 0.05gwei \
--private-key $ETHEREUM_PRIVATE_KEY

cast call 0xC36442b4a4522E871399CD717aBDD847Ab11FE88 \
"decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))" \
"(1267475,17275948505868,0,0,$DEADLINE)" \
--rpc-url mainnet

cast call 0xC36442b4a4522E871399CD717aBDD847Ab11FE88 \
"collect((uint256,address,uint128,uint128))" \
"(1267475,0xde05927035b51C5f6dE27b427e4649123723e141,340282366920938463463374607431768211455,340282366920938463463374607431768211455)" \
--from 0xde05927035b51C5f6dE27b427e4649123723e141 \
--rpc-url mainnet

```


### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```


forge remove OpenZeppelin/openzeppelin-contracts

forge install OpenZeppelin/openzeppelin-contracts@v3.4.2-solc-0.7
forge install OpenZeppelin/openzeppelin-contracts@v4.9.6
forge install Uniswap/v3-core
forge install Uniswap/v3-periphery



forge inspect UniswapLP bytecode | wc -c

### deploy
require
forge inspect UniswapLP bytecode | wc -c
23575

error
forge inspect UniswapLP bytecode | wc -c
22753