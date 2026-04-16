# UniswapLP 合约使用指南

## 概述

`UniswapLP` 是一个集成了白名单免手续费、协议手续费调整和 Uniswap V3 交互功能的智能合约。它支持用户使用单边资产通过原子化的 swap 和 mint 操作成为 LP，或直接使用双边资产 mint LP。

## 主要特性

### 1. 白名单管理
- **免手续费**：白名单中的地址可以免去协议手续费
- **灵活管理**：支持批量添加和删除白名单地址

```solidity
// 添加白名单
uniswapLP.addToWhitelist([address1, address2]);

// 移除白名单
uniswapLP.removeFromWhitelist([address1]);
```

### 2. 协议手续费管理
- **动态调整**：管理员可以随时调整协议手续费
- **安全上限**：手续费上限为 10000 basis points (100%)
- **自动计算**：合约自动根据用户是否在白名单中计算手续费

```solidity
// 设置手续费为 1% (100 basis points)
uniswapLP.setProtocolFee(100);

// 更新手续费接收地址
uniswapLP.setFeeRecipient(newRecipient);
```

### 3. 核心功能：单边资产自动配比后 Mint LP

#### 函数签名
```solidity
function swapAndMintLP(
    address tokenIn,      // 输入代币
    address tokenOut,     // 输出代币
    uint24 poolFee,       // Uniswap V3 费率 (500/3000/10000)
    uint256 amountIn,     // 单边资产投入数量
    int24 tickLower,      // 流动性范围下界
    int24 tickUpper,      // 流动性范围上界
    uint256 amount0Min,   // token0 最少数量（mint 时的保护）
    uint256 amount1Min,   // token1 最少数量（mint 时的保护）
    uint256 slippageTolerance, // 滑点容限 (e.g., 100 = 1%)
    uint256 deadline      // 超时时间戳
) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
```

#### 工作流程
1. **获取投入比例**：通过 `getUniDirectionalRatio()` 计算在目标价格范围内应该投入 token0 和 token1 各多少比例
2. **智能拆分**：根据比例自动拆分单边资产
   - 若比例为 60% token0 + 40% token1
   - 用户投入 1000 token0，则需要 600 token0 + 400 token0 的 swap 产出
3. **自动 Swap**：如果需要，自动执行 swap，并根据滑点容限计算 amountOutMinimum
4. **Mint LP**：组合后的双边资产进行 mint
5. **退余**：返回任何未使用的代币

#### 使用示例
```javascript
// 用 1000 USDC 投入 USDC/WETH LP（价格范围内自动计算比例）
const tx = await uniswapLP.swapAndMintLP(
  USDC,           // tokenIn
  WETH,           // tokenOut
  3000,           // 0.3% pool fee
  ethers.parseUnits("1000", 6),  // 1000 USDC
  -887220,        // tickLower (全范围下界)
  887220,         // tickUpper (全范围上界)
  0,              // amount0Min (mint 时保护)
  0,              // amount1Min (mint 时保护)
  100,            // 1% 滑点容限
  Math.floor(Date.now() / 1000) + 300  // 5分钟后过期
);

const { tokenId, liquidity } = await tx.wait();
console.log(`成功创建 LP NFT #${tokenId}，流动性: ${liquidity}`);
```

### 4. 双边资产直接 Mint LP

#### 函数签名
```solidity
function mintLP(
    address token0,       // token0 地址
    address token1,       // token1 地址
    uint24 fee,           // Uniswap V3 费率
    uint256 amount0,      // token0 数量
    uint256 amount1,      // token1 数量
    int24 tickLower,      // 流动性范围下界
    int24 tickUpper,      // 流动性范围上界
    uint256 amount0Min,   // 最少 token0 数量
    uint256 amount1Min,   // 最少 token1 数量
    uint256 deadline      // 超时时间戳
) external returns (uint256 tokenId, uint128 liquidity, uint256 actualAmount0, uint256 actualAmount1)
```

## 网络配置

合约支持多网络部署，配置文件存储在 `deployments/` 目录：

- **ethereum.json**：以太坊主网配置
- **sepolia.json**：Sepolia 测试网配置

每个配置文件包含：
- `chainId`：链 ID
- `chainName`：链名称
- `uniswapV3Router`：Uniswap V3 Router 地址
- `uniswapV3Factory`：Uniswap V3 Factory 地址
- `uniswapV3PositionManager`：NFT Position Manager 地址
- `weth`：WETH 代币地址

## 部署

### 部署到 Sepolia 测试网

```bash
# 设置环境变量
export SEPOLIA_RPC_URL="your_rpc_url"
export PRIVATE_KEY="your_private_key"

# 部署合约
forge script script/UniswapLP.s.sol:UniswapLPScript --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

### 部署到以太坊主网

```bash
export MAINNET_RPC_URL="your_rpc_url"
export PRIVATE_KEY="your_private_key"

forge script script/UniswapLP.s.sol:UniswapLPScript --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

## 辅助函数

### getPoolInfo(tokenA, tokenB, fee)
获取 Uniswap V3 Pool 的基础信息。

**返回值：**
- `token0`: Pool 中的 token0 地址
- `token1`: Pool 中的 token1 地址  
- `currentTick`: 当前价格的 tick 值
- `sqrtPriceX96`: 当前价格的平方根（Q96 格式）

```javascript
const poolInfo = await uniswapLP.getPoolInfo(USDC, WETH, 3000);
console.log(`Token0: ${poolInfo.token0}`);
console.log(`Token1: ${poolInfo.token1}`);
console.log(`Current Tick: ${poolInfo.currentTick}`);
```

### getUniDirectionalRatio(tokenA, tokenB, fee, tickLower, tickUpper)
计算在指定价格范围内，单边资产应该如何分配到 token0 和 token1。

**工作原理：**
- 如果当前价格 < tickLower：应该 100% 投入 token0（较便宜）
- 如果当前价格 > tickUpper：应该 100% 投入 token1（较便宜）
- 如果价格在范围内：根据 Uniswap V3 的 Liquidity Math 精确计算比例

**返回值：**
- `ratioToken0`: token0 的投入比例（0-100）
- `ratioToken1`: token1 的投入比例（0-100）

```javascript
const [ratio0, ratio1] = await uniswapLP.getUniDirectionalRatio(
  USDC,
  WETH,
  3000,
  -887220,  // 全范围下界
  887220    // 全范围上界
);
console.log(`应该投入 ${ratio0}% token0 和 ${ratio1}% token1`);
```

## 运行测试

```bash
forge test
```

## 合约安全特性

1. **所有权保护**：关键管理函数只能由合约所有者调用
2. **手续费上限**：手续费不能超过 10000 basis points
3. **Deadline 检查**：所有交互都有时间限制防止过期
4. **SafeERC20 使用**：使用 OpenZeppelin 的 SafeERC20 确保 ERC20 操作安全
5. **紧急提取**：支持紧急提取合约内的代币

## 事件日志

合约发出以下事件便于链上监控：

```solidity
event WhitelistUpdated(address indexed user, bool status);
event ProtocolFeeUpdated(uint256 newFee);
event FeeRecipientUpdated(address newRecipient);
event LiquidityAdded(uint256 indexed tokenId, address token0, address token1, uint24 fee, uint256 liquidity);
event FeesCollected(address indexed token, uint256 amount);
```

## 常见问题

### Q: 为什么我的交易失败了？
A: 可能的原因：
- Deadline 已过期
- 滑点保护触发（实际输出小于 minimum）
- 允额不足（没有 approve 足够的代币）
- 价格变动（在等待期间）

### Q: 如何计算正确的 tick 范围？
A: 使用 Uniswap V3 的 tickSpacing 计算：
- 0.01% fee：tickSpacing = 1
- 0.05% fee：tickSpacing = 10
- 0.30% fee：tickSpacing = 60
- 1.00% fee：tickSpacing = 200

tick 必须是 tickSpacing 的倍数。

## 依赖

- OpenZeppelin Contracts
- Uniswap V3 Core
- Uniswap V3 Periphery
- Foundry (用于开发和测试)

## 许可证

MIT
