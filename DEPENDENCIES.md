# 依赖安装指南

为了使用 UniswapLP 合约，你需要安装以下依赖库。

## 前置要求

- [Foundry](https://getfoundry.sh/)：Ethereum 开发框架
- Git

## 安装步骤

### 1. 进入 contracts 目录

```bash
cd contracts
```

### 2. 安装 Forge Standard Library（如果还未安装）

```bash
forge install foundry-rs/forge-std
```

### 3. 安装 OpenZeppelin Contracts

```bash
forge install OpenZeppelin/openzeppelin-contracts
```

### 4. 安装 Uniswap V3 Core

```bash
forge install Uniswap/v3-core
```

### 5. 安装 Uniswap V3 Periphery

```bash
forge install Uniswap/v3-periphery
```

## 验证安装

运行测试来验证所有依赖都已正确安装：

```bash
forge test
```

你应该看到测试通过的输出。

## 依赖详情

| 库名 | 用途 | 版本 |
|------|------|------|
| forge-std | Foundry 标准库 | 最新 |
| openzeppelin-contracts | ERC20、Ownable 等标准合约 | v4.x |
| v3-core | Uniswap V3 核心逻辑 | 最新 |
| v3-periphery | Uniswap V3 外围合约 (Router, PositionManager) | 最新 |

## 常见问题

### 问：安装后还是找不到导入路径？

答：检查 `remappings.txt` 文件是否存在且格式正确。可以运行：

```bash
forge remappings
```

来验证映射是否正确。

### 问：编译失败，说找不到某个文件？

答：可能是 git submodule 没有初始化。运行：

```bash
git submodule update --init --recursive
```

### 问：如何更新依赖到最新版本？

答：删除 lib 目录中对应的库，然后重新安装：

```bash
rm -rf lib/openzeppelin-contracts
forge install OpenZeppelin/openzeppelin-contracts
```

## 编译合约

安装完所有依赖后，编译合约：

```bash
forge build
```

## 运行测试

```bash
forge test -vvv
```

## 部署

```bash
forge script script/UniswapLP.s.sol:UniswapLPScript --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```
