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

    // 常数定义 - 优化 gas 开销
    uint256 private constant PERCENTAGE_BASE = 10000; // 基数：10000 = 100%
    uint256 private constant MAX_PROTOCOL_FEE = 500; // 最高手续费：5%

    // Custom errors
    error InvalidAmount();
    error SlippageTooHigh();
    error DeadlineExceeded();
    error EthAmountMismatch();
    error InvalidRecipient();
    error TokensMustBeDifferent();
    error PoolDoesNotExist();
    error InvalidPool();
    error FeeTooHigh();
    error InvalidRange();
    error NotNFTOwner();
    error InvalidNFT();
    error InvalidTokenInput();

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

    struct MintLocalVars {
        uint256 ratioToken0;
        uint256 ratioToken1;
        uint256 protocolFeeAmount;
        uint256 amountInAfterFee;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
    }
    struct IncreaseLiquidityLocalVars {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 ratioToken0;
        uint256 ratioToken1;
        uint256 protocolFeeAmount;
        uint256 amountInAfterFee;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
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
        if (_fee > MAX_PROTOCOL_FEE) revert FeeTooHigh();
        protocolFee = _fee;
        emit ProtocolFeeUpdated(_fee);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert InvalidRecipient();
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    // 计算需要支付的手续费
    function calculateFee(uint256 amount) public view returns (uint256) {
        if (msg.sender == owner() || whitelist[msg.sender]) {
            return 0;
        }
        return (amount * protocolFee) / PERCENTAGE_BASE;
    }

    // 获取 pool 信息 - token0, token1, 当前 tick, sqrtPrice
    function getPoolInfo(
        address tokenA,
        address tokenB,
        uint24 fee
    ) public view returns (PoolInfo memory) {
        if (tokenA == tokenB) revert TokensMustBeDifferent();

        address poolAddress = factory.getPool(tokenA, tokenB, fee);
        if (poolAddress == address(0)) revert PoolDoesNotExist();

        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        (uint160 sqrtPriceX96, int24 tick, , , , , ) = pool.slot0();
        if (sqrtPriceX96 == 0) revert InvalidPool();

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
            return (PERCENTAGE_BASE, 0);
        }

        if (currentTick >= tickUpper) {
            // 价格高于区间：全部 token1
            return (0, PERCENTAGE_BASE);
        }

        uint256 sc = uint256(poolInfo.sqrtPriceX96);
        uint256 sa = uint256(TickMath.getSqrtRatioAtTick(tickLower));
        uint256 sb = uint256(TickMath.getSqrtRatioAtTick(tickUpper));

        // w0 = sc*(sb-sc)/sb  对应 token0 的价值权重（以 token1 计价）
        // w1 = sc-sa           对应 token1 的价值权重
        uint256 w0 = FullMath.mulDiv(sc, sb - sc, sb);
        uint256 w1 = sc - sa;

        uint256 total = w0 + w1;
        if (total == 0) revert InvalidRange();

        ratioToken0 = (w0 * PERCENTAGE_BASE) / total;
        ratioToken1 = PERCENTAGE_BASE - ratioToken0;
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
        require(slippageTolerance <= PERCENTAGE_BASE, "Slippage too high");
        require(deadline >= block.timestamp, "Deadline exceeded");
        IWETH wethLocal = weth;
        INonfungiblePositionManager positionManagerLocal = positionManager;

        // 处理 ETH 转 WETH
        if (tokenIn == address(wethLocal) && msg.value > 0) {
            require(msg.value == amountIn, "ETH amount mismatch");
            wethLocal.deposit{value: msg.value}();
        }

        // 获取 pool 信息
        PoolInfo memory poolInfo = getPoolInfo(tokenIn, tokenOut, poolFee);
        MintLocalVars memory v;

        // 获取目标价格范围的投入比例
        (v.ratioToken0, v.ratioToken1) = getUniDirectionalRatio(
            tokenIn,
            tokenOut,
            poolFee,
            tickLower,
            tickUpper
        );

        // 收取手续费
        v.protocolFeeAmount = calculateFee(amountIn);
        v.amountInAfterFee = amountIn - v.protocolFeeAmount;

        if (v.protocolFeeAmount > 0) {
            if (tokenIn == address(wethLocal) && msg.value > 0) {
                // 已从合约的 WETH 余额中支付手续费
                IERC20(address(wethLocal)).safeTransfer(
                    feeRecipient,
                    v.protocolFeeAmount
                );
            } else {
                // 从用户账户转移代币作为手续费
                IERC20(tokenIn).safeTransferFrom(
                    msg.sender,
                    feeRecipient,
                    v.protocolFeeAmount
                );
            }
        }

        // 转入用户的代币（如果不是通过 ETH 已转入）
        if (!(tokenIn == address(wethLocal) && msg.value > 0)) {
            IERC20(tokenIn).safeTransferFrom(
                msg.sender,
                address(this),
                v.amountInAfterFee
            );
        }

        // 计算需要的 token0 和 token1 的投入量（按比例分配）
        if (tokenIn == poolInfo.token0) {
            // 用户投入 token0，需要 swap 一部分换成 token1
            uint256 token0Amount = (v.amountInAfterFee * v.ratioToken0) /
                PERCENTAGE_BASE;
            uint256 token0ForSwap = v.amountInAfterFee - token0Amount;

            if (token0ForSwap > 0) {
                uint256 amountOut = _executeSwap(
                    tokenIn,
                    tokenOut,
                    token0ForSwap,
                    poolFee,
                    slippageTolerance,
                    deadline
                );
                v.amount0Desired = token0Amount;
                v.amount1Desired = amountOut;
            } else {
                // 无需 swap，全部投入 token0
                v.amount0Desired = v.amountInAfterFee;
                v.amount1Desired = 0;
            }
        } else {
            // 用户投入 token1，需要 swap 一部分换成 token0
            uint256 token1Amount = (v.amountInAfterFee * v.ratioToken1) /
                PERCENTAGE_BASE;
            uint256 token1ForSwap = v.amountInAfterFee - token1Amount;

            if (token1ForSwap > 0) {
                uint256 amountOut = _executeSwap(
                    tokenIn,
                    tokenOut,
                    token1ForSwap,
                    poolFee,
                    slippageTolerance,
                    deadline
                );
                v.amount0Desired = amountOut;
                v.amount1Desired = token1Amount;
            } else {
                // 无需 swap，全部投入 token1
                v.amount0Desired = 0;
                v.amount1Desired = v.amountInAfterFee;
            }
        }

        // 计算 amount0Min 和 amount1Min
        if (v.amount0Desired == 0) {
            v.amount1Min =
                (v.amount1Desired * (PERCENTAGE_BASE - slippageTolerance)) /
                PERCENTAGE_BASE;
        } else if (v.amount1Desired == 0) {
            v.amount0Min =
                (v.amount0Desired * (PERCENTAGE_BASE - slippageTolerance)) /
                PERCENTAGE_BASE;
        } else {
            v.amount0Min = 0;
            v.amount1Min = 0;
        }

        // 批准 position manager
        if (v.amount0Desired > 0) {
            IERC20(poolInfo.token0).safeIncreaseAllowance(
                address(positionManagerLocal),
                v.amount0Desired
            );
        }
        if (v.amount1Desired > 0) {
            IERC20(poolInfo.token1).safeIncreaseAllowance(
                address(positionManagerLocal),
                v.amount1Desired
            );
        }

        // Mint LP
        (tokenId, liquidity, amount0, amount1) = positionManagerLocal.mint(
            INonfungiblePositionManager.MintParams({
                token0: poolInfo.token0,
                token1: poolInfo.token1,
                fee: poolFee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: v.amount0Desired,
                amount1Desired: v.amount1Desired,
                amount0Min: v.amount0Min,
                amount1Min: v.amount1Min,
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

    // 内部函数：执行单个 swap 操作
    function _executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee,
        uint256 slippageTolerance,
        uint256 deadline
    ) private returns (uint256 amountOut) {
        ISwapRouter swapRouterLocal = swapRouter;
        IERC20(tokenIn).safeIncreaseAllowance(
            address(swapRouterLocal),
            amountIn
        );

        (uint256 quotedAmount, uint160 sqrtPriceX96, , ) = quoterV2
            .quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    amountIn: amountIn,
                    fee: fee,
                    sqrtPriceLimitX96: 0
                })
            );

        uint256 amountOutMinimum = (quotedAmount *
            (PERCENTAGE_BASE - slippageTolerance)) / PERCENTAGE_BASE;

        // 计算价格保护：根据方向调整
        // 如果是 token0->token1，价格会下降，允许更低的价格
        // 如果是 token1->token0，价格会上升，允许更高的价格
        uint160 sqrtPriceLimitX96;
        if (tokenIn < tokenOut) {
            // token0 -> token1: 下行保护
            sqrtPriceLimitX96 = uint160(
                (uint256(sqrtPriceX96) *
                    (PERCENTAGE_BASE - slippageTolerance)) / PERCENTAGE_BASE
            );
        } else {
            // token1 -> token0: 上行保护
            sqrtPriceLimitX96 = uint160(
                (uint256(sqrtPriceX96) *
                    (PERCENTAGE_BASE + slippageTolerance)) / PERCENTAGE_BASE
            );
        }

        amountOut = swapRouterLocal.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );

        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut);
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
        if (amountIn == 0) revert InvalidAmount();
        if (slippageTolerance > PERCENTAGE_BASE) revert SlippageTooHigh();
        if (deadline < block.timestamp) revert DeadlineExceeded();

        INonfungiblePositionManager positionManagerLocal = positionManager;
        if (positionManagerLocal.ownerOf(tokenId) != msg.sender)
            revert NotNFTOwner();

        IWETH wethLocal = weth;
        IncreaseLiquidityLocalVars memory v;

        // 获取 NFT 位置信息
        (
            ,
            ,
            v.token0,
            v.token1,
            v.fee,
            v.tickLower,
            v.tickUpper,
            ,
            ,
            ,
            ,

        ) = positionManagerLocal.positions(tokenId);

        if (v.token0 == address(0) || v.token1 == address(0))
            revert InvalidNFT();
        if (tokenIn != v.token0 && tokenIn != v.token1)
            revert InvalidTokenInput();

        // 处理 ETH 转 WETH
        if (tokenIn == address(wethLocal) && msg.value > 0) {
            if (msg.value != amountIn) revert EthAmountMismatch();
            wethLocal.deposit{value: msg.value}();
        }

        // 获取投入比例
        (v.ratioToken0, v.ratioToken1) = getUniDirectionalRatio(
            v.token0,
            v.token1,
            v.fee,
            v.tickLower,
            v.tickUpper
        );

        // 收取手续费
        v.protocolFeeAmount = calculateFee(amountIn);
        v.amountInAfterFee = amountIn - v.protocolFeeAmount;

        if (v.protocolFeeAmount > 0) {
            if (tokenIn == address(wethLocal) && msg.value > 0) {
                IERC20(address(wethLocal)).safeTransfer(
                    feeRecipient,
                    v.protocolFeeAmount
                );
            } else {
                IERC20(tokenIn).safeTransferFrom(
                    msg.sender,
                    feeRecipient,
                    v.protocolFeeAmount
                );
            }
        }

        // 转入用户的代币（如果不是通过 ETH 已转入）
        if (!(tokenIn == address(wethLocal) && msg.value > 0)) {
            IERC20(tokenIn).safeTransferFrom(
                msg.sender,
                address(this),
                v.amountInAfterFee
            );
        }

        // 确定投入的 token 方向（是 token0 还是 token1）
        // 计算需要的投入量
        if (tokenIn == v.token0) {
            // 用户投入 token0，需要 swap 一部分换成 token1
            uint256 token0Amount = (v.amountInAfterFee * v.ratioToken0) /
                PERCENTAGE_BASE;
            uint256 token0ForSwap = v.amountInAfterFee - token0Amount;

            if (token0ForSwap > 0) {
                uint256 amountOut = _executeSwap(
                    v.token0,
                    v.token1,
                    token0ForSwap,
                    v.fee,
                    slippageTolerance,
                    deadline
                );
                v.amount0Desired = token0Amount;
                v.amount1Desired = amountOut;
            } else {
                // 无需 swap
                v.amount0Desired = v.amountInAfterFee;
                v.amount1Desired = 0;
            }
        } else {
            // 用户投入 token1，需要 swap 一部分换成 token0
            uint256 token1Amount = (v.amountInAfterFee * v.ratioToken1) /
                PERCENTAGE_BASE;
            uint256 token1ForSwap = v.amountInAfterFee - token1Amount;

            if (token1ForSwap > 0) {
                uint256 amountOut = _executeSwap(
                    v.token1,
                    v.token0,
                    token1ForSwap,
                    v.fee,
                    slippageTolerance,
                    deadline
                );
                v.amount0Desired = amountOut;
                v.amount1Desired = token1Amount;
            } else {
                // 无需 swap
                v.amount0Desired = 0;
                v.amount1Desired = v.amountInAfterFee;
            }
        }

        // 计算 amount0Min 和 amount1Min
        if (v.amount0Desired == 0) {
            v.amount1Min =
                (v.amount1Desired * (PERCENTAGE_BASE - slippageTolerance)) /
                PERCENTAGE_BASE;
        } else if (v.amount1Desired == 0) {
            v.amount0Min =
                (v.amount0Desired * (PERCENTAGE_BASE - slippageTolerance)) /
                PERCENTAGE_BASE;
        } else {
            v.amount0Min = 0;
            v.amount1Min = 0;
        }

        // 批准 position manager
        if (v.amount0Desired > 0) {
            IERC20(v.token0).safeIncreaseAllowance(
                address(positionManagerLocal),
                v.amount0Desired
            );
        }
        if (v.amount1Desired > 0) {
            IERC20(v.token1).safeIncreaseAllowance(
                address(positionManagerLocal),
                v.amount1Desired
            );
        }

        // 增加流动性
        (liquidity, amount0, amount1) = positionManagerLocal.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: v.amount0Desired,
                amount1Desired: v.amount1Desired,
                amount0Min: v.amount0Min,
                amount1Min: v.amount1Min,
                deadline: deadline
            })
        );

        // 清理剩余代币
        _cleanupTokens(v.token0, v.token1);

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
