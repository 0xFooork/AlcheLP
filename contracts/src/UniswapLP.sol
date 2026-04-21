// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISwapRouter} from "./interface/ISwapRouter.sol";
import {
    INonfungiblePositionManager
} from "./interface/INonfungiblePositionManager.sol";
import {IUniswapV3Factory} from "./interface/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "./interface/IUniswapV3Pool.sol";
import {IWETH} from "./interface/IWETH.sol";
import {IQuoterV2} from "./interface/IQuoterV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {FixedPoint96} from "./libraries/FixedPoint96.sol";

contract UniswapLP is Ownable {
    using SafeERC20 for IERC20;

    ISwapRouter public swapRouter;
    INonfungiblePositionManager public positionManager;
    IUniswapV3Factory public factory;
    IWETH public weth;
    IQuoterV2 public quoterV2;

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
    event LiquidityIncreased(
        uint256 indexed tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
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
        address _weth,
        address _quoterV2,
        address _feeRecipient,
        address _initialOwner
    ) Ownable(_initialOwner) {
        swapRouter = ISwapRouter(_swapRouter);
        positionManager = INonfungiblePositionManager(_positionManager);
        factory = IUniswapV3Factory(_factory);
        weth = IWETH(_weth);
        quoterV2 = IQuoterV2(_quoterV2);
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
        require(_fee <= 500, "Fee too high"); // 最高5%
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

        int24 currentTick = poolInfo.currentTick;

        if (currentTick <= tickLower) {
            // 价格低于区间：全部 token0
            return (10000, 0);
        }

        if (currentTick >= tickUpper) {
            // 价格高于区间：全部 token1
            return (0, 10000);
        }

        uint256 sc = uint256(poolInfo.sqrtPriceX96);
        uint256 sa = uint256(TickMath.getSqrtRatioAtTick(tickLower));
        uint256 sb = uint256(TickMath.getSqrtRatioAtTick(tickUpper));

        // w0 = sc*(sb-sc)/sb  对应 token0 的价值权重（以 token1 计价）
        // w1 = sc-sa           对应 token1 的价值权重
        uint256 w0 = FullMath.mulDiv(sc, sb - sc, sb);
        uint256 w1 = sc - sa;

        uint256 total = w0 + w1;
        require(total > 0, "invalid range");

        ratioToken0 = (w0 * 10000) / total;
        ratioToken1 = 10000 - ratioToken0;
    }

    // 核心功能：单边资产自动配比 swap 然后 mint LP
    function swapAndMintLP(
        address tokenIn,
        address tokenOut,
        uint24 poolFee,
        uint256 amountIn,
        int24 tickLower,
        int24 tickUpper,
        uint256 slippageTolerance,
        uint256 deadline
    )
        external
        payable
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

        // 处理 ETH 转 WETH
        if (tokenIn == address(weth) && msg.value > 0) {
            require(msg.value == amountIn, "ETH amount mismatch");
            weth.deposit{value: msg.value}();
        }

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
            if (tokenIn == address(weth) && msg.value > 0) {
                // 已从合约的 WETH 余额中支付手续费
                IERC20(address(weth)).safeTransfer(
                    feeRecipient,
                    protocolFeeAmount
                );
            } else {
                // 从用户账户转移代币作为手续费
                IERC20(tokenIn).safeTransferFrom(
                    msg.sender,
                    feeRecipient,
                    protocolFeeAmount
                );
            }
        }

        // 转入用户的代币（如果不是通过 ETH 已转入）
        if (!(tokenIn == address(weth) && msg.value > 0)) {
            IERC20(tokenIn).safeTransferFrom(
                msg.sender,
                address(this),
                amountInAfterFee
            );
        }

        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min = 0;
        uint256 amount1Min = 0;

        // 计算需要的 token0 和 token1 的投入量（按比例分配）
        if (tokenIn == poolInfo.token0) {
            // 用户投入 token0，需要 swap 一部分换成 token1
            uint256 token0Amount = (amountInAfterFee * ratioToken0) / 10000;
            uint256 token0ForSwap = amountInAfterFee - token0Amount;

            if (token0ForSwap > 0) {
                // 需要 swap
                IERC20(tokenIn).safeIncreaseAllowance(
                    address(swapRouter),
                    token0ForSwap
                );

                // 计算最小输出和价格保护
                (uint256 token1Amount, uint160 sqrtPriceX96, , ) = quoterV2
                    .quoteExactInputSingle(
                        IQuoterV2.QuoteExactInputSingleParams({
                            tokenIn: tokenIn,
                            tokenOut: tokenOut,
                            amountIn: token0ForSwap,
                            fee: poolFee,
                            sqrtPriceLimitX96: 0
                        })
                    );
                uint256 amountOutMinimum = token1Amount -
                    (token1Amount * slippageTolerance) /
                    10000;

                // 计算价格保护：允许的最低价格
                uint160 sqrtPriceLimitX96 = uint160(
                    (sqrtPriceX96 * (10000 - slippageTolerance)) / 10000
                );

                uint256 amountOut = swapRouter.exactInputSingle(
                    ISwapRouter.ExactInputSingleParams({
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        fee: poolFee,
                        recipient: address(this),
                        deadline: deadline,
                        amountIn: token0ForSwap,
                        amountOutMinimum: amountOutMinimum,
                        sqrtPriceLimitX96: sqrtPriceLimitX96
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
            uint256 token1Amount = (amountInAfterFee * ratioToken1) / 10000;
            uint256 token1ForSwap = amountInAfterFee - token1Amount;

            if (token1ForSwap > 0) {
                // 需要 swap
                IERC20(tokenIn).safeIncreaseAllowance(
                    address(swapRouter),
                    token1ForSwap
                );

                // 计算最小输出和价格保护
                (uint256 token0Amount, uint160 sqrtPriceX96, , ) = quoterV2
                    .quoteExactInputSingle(
                        IQuoterV2.QuoteExactInputSingleParams({
                            tokenIn: tokenIn,
                            tokenOut: tokenOut,
                            amountIn: token1ForSwap,
                            fee: poolFee,
                            sqrtPriceLimitX96: 0
                        })
                    );
                uint256 amountOutMinimum = token0Amount -
                    (token0Amount * slippageTolerance) /
                    10000;

                // 计算价格保护：允许的最高价格（token1兑token0）
                uint160 sqrtPriceLimitX96 = uint160(
                    (uint256(sqrtPriceX96) * (10000 + slippageTolerance)) /
                        10000
                );

                uint256 amountOut = swapRouter.exactInputSingle(
                    ISwapRouter.ExactInputSingleParams({
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        fee: poolFee,
                        recipient: address(this),
                        deadline: deadline,
                        amountIn: token1ForSwap,
                        amountOutMinimum: amountOutMinimum,
                        sqrtPriceLimitX96: sqrtPriceLimitX96
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

        // 计算 amount0Min 和 amount1Min
        // 计算 amount0Min 和 amount1Min
        if (amount0Desired == 0) {
            amount1Min =
                amount1Desired -
                (amount1Desired * slippageTolerance) /
                10000;
        } else if (amount1Desired == 0) {
            amount0Min =
                amount0Desired -
                (amount0Desired * slippageTolerance) /
                10000;
        }

        // 批准 position manager
        IERC20(poolInfo.token0).safeIncreaseAllowance(
            address(positionManager),
            amount0Desired
        );
        IERC20(poolInfo.token1).safeIncreaseAllowance(
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

    // 增加指定 NFT LP 的流动性 - 支持单边资产投入，自动 swap 调整比例
    function swapAndIncreaseLiquidity(
        uint256 tokenId,
        address tokenIn,
        uint256 amountIn,
        uint256 slippageTolerance,
        uint256 deadline
    )
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        require(amountIn > 0, "Invalid amount");
        require(slippageTolerance <= 10000, "Slippage too high");
        require(deadline >= block.timestamp, "Deadline exceeded");
        require(
            positionManager.ownerOf(tokenId) == msg.sender,
            "Not NFT owner"
        );

        // 获取 NFT 位置信息
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            ,
            ,
            ,
            ,

        ) = positionManager.positions(tokenId);

        require(token0 != address(0) && token1 != address(0), "Invalid NFT");
        require(
            (tokenIn == token0 || tokenIn == token1),
            "Invalid token input"
        );

        // 处理 ETH 转 WETH
        if (tokenIn == address(weth) && msg.value > 0) {
            require(msg.value == amountIn, "ETH amount mismatch");
            weth.deposit{value: msg.value}();
        }

        // 获取投入比例
        (uint256 ratioToken0, uint256 ratioToken1) = getUniDirectionalRatio(
            token0,
            token1,
            fee,
            tickLower,
            tickUpper
        );

        // 收取手续费
        uint256 protocolFeeAmount = calculateFee(amountIn);
        uint256 amountInAfterFee = amountIn - protocolFeeAmount;

        if (protocolFeeAmount > 0) {
            if (tokenIn == address(weth) && msg.value > 0) {
                IERC20(address(weth)).safeTransfer(
                    feeRecipient,
                    protocolFeeAmount
                );
            } else {
                IERC20(tokenIn).safeTransferFrom(
                    msg.sender,
                    feeRecipient,
                    protocolFeeAmount
                );
            }
        }

        // 转入用户的代币（如果不是通过 ETH 已转入）
        if (!(tokenIn == address(weth) && msg.value > 0)) {
            IERC20(tokenIn).safeTransferFrom(
                msg.sender,
                address(this),
                amountInAfterFee
            );
        }

        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min = 0;
        uint256 amount1Min = 0;

        // 确定投入的 token 方向（是 token0 还是 token1）
        bool isToken0Input = (tokenIn == token0);

        // 计算需要的投入量
        if (isToken0Input) {
            // 用户投入 token0，需要 swap 一部分换成 token1
            uint256 token0Amount = (amountInAfterFee * ratioToken0) / 10000;
            uint256 token0ForSwap = amountInAfterFee - token0Amount;

            if (token0ForSwap > 0) {
                // 需要 swap
                IERC20(token0).safeIncreaseAllowance(
                    address(swapRouter),
                    token0ForSwap
                );

                (uint256 token1Amount, uint160 sqrtPriceX96, , ) = quoterV2
                    .quoteExactInputSingle(
                        IQuoterV2.QuoteExactInputSingleParams({
                            tokenIn: token0,
                            tokenOut: token1,
                            amountIn: token0ForSwap,
                            fee: fee,
                            sqrtPriceLimitX96: 0
                        })
                    );
                uint256 amountOutMinimum = token1Amount -
                    (token1Amount * slippageTolerance) /
                    10000;

                // 计算价格保护：允许的最低价格
                uint160 sqrtPriceLimitX96 = uint160(
                    (sqrtPriceX96 * (10000 - slippageTolerance)) / 10000
                );

                uint256 amountOut = swapRouter.exactInputSingle(
                    ISwapRouter.ExactInputSingleParams({
                        tokenIn: token0,
                        tokenOut: token1,
                        fee: fee,
                        recipient: address(this),
                        deadline: deadline,
                        amountIn: token0ForSwap,
                        amountOutMinimum: amountOutMinimum,
                        sqrtPriceLimitX96: sqrtPriceLimitX96
                    })
                );

                emit SwapExecuted(token0, token1, token0ForSwap, amountOut);
                amount0Desired = token0Amount;
                amount1Desired = amountOut;
            } else {
                // 无需 swap
                amount0Desired = amountInAfterFee;
                amount1Desired = 0;
            }
        } else {
            // 用户投入 token1，需要 swap 一部分换成 token0
            uint256 token1Amount = (amountInAfterFee * ratioToken1) / 10000;
            uint256 token1ForSwap = amountInAfterFee - token1Amount;

            if (token1ForSwap > 0) {
                // 需要 swap
                IERC20(token1).safeIncreaseAllowance(
                    address(swapRouter),
                    token1ForSwap
                );

                (uint256 token0Amount, uint160 sqrtPriceX96, , ) = quoterV2
                    .quoteExactInputSingle(
                        IQuoterV2.QuoteExactInputSingleParams({
                            tokenIn: token1,
                            tokenOut: token0,
                            amountIn: token1ForSwap,
                            fee: fee,
                            sqrtPriceLimitX96: 0
                        })
                    );
                uint256 amountOutMinimum = token0Amount -
                    (token0Amount * slippageTolerance) /
                    10000;

                // 计算价格保护：允许的最高价格（token1兑token0）
                uint160 sqrtPriceLimitX96 = uint160(
                    (uint256(sqrtPriceX96) * (10000 + slippageTolerance)) /
                        10000
                );

                uint256 amountOut = swapRouter.exactInputSingle(
                    ISwapRouter.ExactInputSingleParams({
                        tokenIn: token1,
                        tokenOut: token0,
                        fee: fee,
                        recipient: address(this),
                        deadline: deadline,
                        amountIn: token1ForSwap,
                        amountOutMinimum: amountOutMinimum,
                        sqrtPriceLimitX96: sqrtPriceLimitX96
                    })
                );

                emit SwapExecuted(token1, token0, token1ForSwap, amountOut);
                amount0Desired = amountOut;
                amount1Desired = token1Amount;
            } else {
                // 无需 swap
                amount0Desired = 0;
                amount1Desired = amountInAfterFee;
            }
        }

        // 计算 amount0Min 和 amount1Min
        if (amount0Desired == 0) {
            amount1Min =
                amount1Desired -
                (amount1Desired * slippageTolerance) /
                10000;
        } else if (amount1Desired == 0) {
            amount0Min =
                amount0Desired -
                (amount0Desired * slippageTolerance) /
                10000;
        }

        // 批准 position manager
        IERC20(token0).safeIncreaseAllowance(
            address(positionManager),
            amount0Desired
        );
        IERC20(token1).safeIncreaseAllowance(
            address(positionManager),
            amount1Desired
        );

        // 增加流动性
        (liquidity, amount0, amount1) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            })
        );

        // 清理剩余代币
        _cleanupTokens(token0, token1);

        emit LiquidityIncreased(tokenId, liquidity, amount0, amount1);
    }

    function emergencyWithdraw(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(owner(), balance);
        }
    }

    // 接收 ETH
    receive() external payable {}
}
