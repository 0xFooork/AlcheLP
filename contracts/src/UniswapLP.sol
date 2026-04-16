// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {
    ISwapRouter
} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {
    INonfungiblePositionManager
} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {
    IUniswapV3Factory
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {
    IUniswapV3Pool
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {
    FixedPoint96
} from "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";

contract UniswapLP is Ownable {
    using SafeERC20 for IERC20;

    ISwapRouter public swapRouter;
    INonfungiblePositionManager public positionManager;
    IUniswapV3Factory public factory;

    uint256 public protocolFee;
    address public feeRecipient;

    mapping(address => bool) public whitelist;

    struct PoolInfo {
        address token0;
        address token1;
        int24 currentTick;
        uint160 sqrtPriceX96;
    }

    event WhitelistUpdated(address indexed user, bool status);
    event ProtocolFeeUpdated(uint256 newFee);
    event FeeRecipientUpdated(address newRecipient);
    event LiquidityAdded(
        uint256 indexed tokenId,
        address token0,
        address token1,
        uint24 fee,
        uint256 liquidity
    );
    event FeesCollected(address indexed token, uint256 amount);
    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(
        address _swapRouter,
        address _positionManager,
        address _factory,
        address _feeRecipient
    ) {
        swapRouter = ISwapRouter(_swapRouter);
        positionManager = INonfungiblePositionManager(_positionManager);
        factory = IUniswapV3Factory(_factory);
        feeRecipient = _feeRecipient;
        protocolFee = 10;
    }

    // 白名单管理
    function addToWhitelist(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            whitelist[users[i]] = true;
            emit WhitelistUpdated(users[i], true);
        }
    }

    function removeFromWhitelist(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            whitelist[users[i]] = false;
            emit WhitelistUpdated(users[i], false);
        }
    }

    // 手续费管理
    function setProtocolFee(uint256 _fee) external onlyOwner {
        require(_fee <= 10000, "Fee too high"); // 最高100%
        protocolFee = _fee;
        emit ProtocolFeeUpdated(_fee);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid recipient");
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    // 计算需要支付的手续费
    function calculateFee(uint256 amount) public view returns (uint256) {
        if (msg.sender == owner() || whitelist[msg.sender]) {
            return 0;
        }
        return (amount * protocolFee) / 10000;
    }

    // 获取 pool 信息 - token0, token1, 当前 tick, sqrtPrice
    function getPoolInfo(
        address tokenA,
        address tokenB,
        uint24 fee
    ) public view returns (PoolInfo memory) {
        require(tokenA != tokenB, "Tokens must be different");

        address poolAddress = factory.getPool(tokenA, tokenB, fee);
        require(poolAddress != address(0), "Pool does not exist");

        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        (uint160 sqrtPriceX96, int24 tick, , , , , ) = pool.slot0();
        require(sqrtPriceX96 > 0, "Invalid pool");

        address token0 = pool.token0();
        address token1 = pool.token1();

        return
            PoolInfo({
                token0: token0,
                token1: token1,
                currentTick: tick,
                sqrtPriceX96: sqrtPriceX96
            });
    }

    // 获取单边资产投入的理论比例 (简化版 - 仅用于参考)
    function getUniDirectionalRatio(
        address tokenA,
        address tokenB,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper
    ) public view returns (uint256 ratioToken0, uint256 ratioToken1) {
        PoolInfo memory poolInfo = getPoolInfo(tokenA, tokenB, fee);

        if (poolInfo.currentTick < tickLower) {
            // 价格低于范围，应该投入 token0（较便宜的）
            ratioToken0 = 100;
            ratioToken1 = 0;
        } else if (poolInfo.currentTick > tickUpper) {
            // 价格高于范围，应该投入 token1（较便宜的）
            ratioToken0 = 0;
            ratioToken1 = 100;
        } else {
            // 当前价格在区间内，用 sqrtPrice 计算真实比例
            uint160 sqrtPriceCurrent = poolInfo.sqrtPriceX96;
            uint160 sqrtPriceLower = TickMath.getSqrtRatioAtTick(tickLower);
            uint160 sqrtPriceUpper = TickMath.getSqrtRatioAtTick(tickUpper);

            // 用 Q96 精度计算，避免溢出
            // amount0 ∝ (sqrtUpper - sqrtCurrent) / (sqrtCurrent * sqrtUpper)
            // amount1 ∝ (sqrtCurrent - sqrtLower)
            //
            // 将两者统一到同一量纲再做比较：
            // value0 ≈ amount0 * sqrtCurrent^2   (折算成 token1 计价)
            // value1 ≈ amount1

            // 先用 uint256 防止溢出
            uint256 sqrtCurrent = uint256(sqrtPriceCurrent);
            uint256 sqrtLower = uint256(sqrtPriceLower);
            uint256 sqrtUpper = uint256(sqrtPriceUpper);

            // amount0 份额（单位：Q96 / sqrtPrice 量纲，待折算）
            uint256 amount0Part = FullMath.mulDiv(
                sqrtUpper - sqrtCurrent,
                FixedPoint96.Q96,
                FullMath.mulDiv(sqrtCurrent, sqrtUpper, FixedPoint96.Q96)
            );

            // amount1 份额（直接是 sqrtPrice 量纲）
            uint256 amount1Part = sqrtCurrent - sqrtLower;

            // 折算 amount0 到 token1 计价：乘以 (sqrtCurrent/Q96)^2
            // value0 = amount0Part * sqrtCurrent^2 / Q96^2
            uint256 value0 = FullMath.mulDiv(
                amount0Part,
                FullMath.mulDiv(sqrtCurrent, sqrtCurrent, FixedPoint96.Q96),
                FixedPoint96.Q96
            );

            // value1 = amount1Part（量纲本身就是 token1）
            uint256 value1 = amount1Part;

            uint256 total = value0 + value1;
            require(total > 0, "zero range");

            ratioToken0 = (value0 * 100) / total;
            ratioToken1 = 100 - ratioToken0;
        }
    }

    // 核心功能：单边资产自动配比 swap 然后 mint LP
    function swapAndMintLP(
        address tokenIn,
        address tokenOut,
        uint24 poolFee,
        uint256 amountIn,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 slippageTolerance,
        uint256 deadline
    )
        external
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        require(amountIn > 0, "Invalid amount");
        require(slippageTolerance <= 10000, "Slippage too high");
        require(deadline >= block.timestamp, "Deadline exceeded");

        // 获取 pool 信息
        PoolInfo memory poolInfo = getPoolInfo(tokenIn, tokenOut, poolFee);

        // 获取目标价格范围的投入比例
        (uint256 ratioToken0, uint256 ratioToken1) = getUniDirectionalRatio(
            tokenIn,
            tokenOut,
            poolFee,
            tickLower,
            tickUpper
        );

        // 收取手续费
        uint256 protocolFeeAmount = calculateFee(amountIn);
        uint256 amountInAfterFee = amountIn - protocolFeeAmount;

        if (protocolFeeAmount > 0) {
            IERC20(tokenIn).safeTransferFrom(
                msg.sender,
                feeRecipient,
                protocolFeeAmount
            );
        }

        // 转入用户的代币
        IERC20(tokenIn).safeTransferFrom(
            msg.sender,
            address(this),
            amountInAfterFee
        );

        uint256 amount0Desired;
        uint256 amount1Desired;

        // 计算需要的 token0 和 token1 的投入量（按比例分配）
        if (tokenIn == poolInfo.token0) {
            // 用户投入 token0，需要 swap 一部分换成 token1
            uint256 token0Amount = (amountInAfterFee * ratioToken0) / 100;
            uint256 token0ForSwap = amountInAfterFee - token0Amount;

            if (token0ForSwap > 0) {
                // 需要 swap
                IERC20(tokenIn).safeApprove(address(swapRouter), token0ForSwap);

                // 计算最小输出（考虑滑点）
                // 这里简化处理：按照比例计算理论输出，然后应用滑点容限
                uint256 token1Amount = (amountInAfterFee * ratioToken1) / 100;
                uint256 amountOutMinimum = token1Amount -
                    (token1Amount * slippageTolerance) /
                    10000;

                uint256 amountOut = swapRouter.exactInputSingle(
                    ISwapRouter.ExactInputSingleParams({
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        fee: poolFee,
                        recipient: address(this),
                        deadline: deadline,
                        amountIn: token0ForSwap,
                        amountOutMinimum: amountOutMinimum,
                        sqrtPriceLimitX96: 0
                    })
                );

                emit SwapExecuted(tokenIn, tokenOut, token0ForSwap, amountOut);
                amount0Desired = token0Amount;
                amount1Desired = amountOut;
            } else {
                // 无需 swap，全部投入 token0
                amount0Desired = amountInAfterFee;
                amount1Desired = 0;
            }
        } else {
            // 用户投入 token1，需要 swap 一部分换成 token0
            uint256 token1Amount = (amountInAfterFee * ratioToken1) / 100;
            uint256 token1ForSwap = amountInAfterFee - token1Amount;

            if (token1ForSwap > 0) {
                // 需要 swap
                IERC20(tokenIn).safeApprove(address(swapRouter), token1ForSwap);

                // 计算最小输出
                uint256 token0Amount = (amountInAfterFee * ratioToken0) / 100;
                uint256 amountOutMinimum = token0Amount -
                    (token0Amount * slippageTolerance) /
                    10000;

                uint256 amountOut = swapRouter.exactInputSingle(
                    ISwapRouter.ExactInputSingleParams({
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        fee: poolFee,
                        recipient: address(this),
                        deadline: deadline,
                        amountIn: token1ForSwap,
                        amountOutMinimum: amountOutMinimum,
                        sqrtPriceLimitX96: 0
                    })
                );

                emit SwapExecuted(tokenIn, tokenOut, token1ForSwap, amountOut);
                amount0Desired = amountOut;
                amount1Desired = token1Amount;
            } else {
                // 无需 swap，全部投入 token1
                amount0Desired = 0;
                amount1Desired = amountInAfterFee;
            }
        }

        // 批准 position manager
        IERC20(poolInfo.token0).safeApprove(
            address(positionManager),
            amount0Desired
        );
        IERC20(poolInfo.token1).safeApprove(
            address(positionManager),
            amount1Desired
        );

        // Mint LP
        (tokenId, liquidity, amount0, amount1) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: poolInfo.token0,
                token1: poolInfo.token1,
                fee: poolFee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                recipient: msg.sender,
                deadline: deadline
            })
        );

        // 清理剩余代币
        _cleanupTokens(poolInfo.token0, poolInfo.token1);

        emit LiquidityAdded(
            tokenId,
            poolInfo.token0,
            poolInfo.token1,
            poolFee,
            liquidity
        );
    }

    // 内部函数：清理合约内的剩余代币
    function _cleanupTokens(address token0, address token1) internal {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        if (balance0 > 0) {
            IERC20(token0).safeTransfer(msg.sender, balance0);
        }
        if (balance1 > 0) {
            IERC20(token1).safeTransfer(msg.sender, balance1);
        }
    }

    // 紧急提取函数
    function emergencyWithdraw(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(owner(), balance);
        }
    }

    // 接收 ETH
    receive() external payable {}
}
