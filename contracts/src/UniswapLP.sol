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
    )
        public
        view
        returns (
            address token0,
            address token1,
            int24 tick,
            uint160 sqrtPriceX96
        )
    {
        if (tokenA == tokenB) revert TokensMustBeDifferent();

        address poolAddress = factory.getPool(tokenA, tokenB, fee);
        if (poolAddress == address(0)) revert PoolDoesNotExist();

        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        (sqrtPriceX96, tick, , , , , ) = pool.slot0();
        if (sqrtPriceX96 == 0) revert InvalidPool();

        token0 = pool.token0();
        token1 = pool.token1();
    }

    // 获取单边资产投入的理论比例 (简化版 - 仅用于参考)
    function getUniDirectionalRatio(
        int24 currentTick,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper
    ) public pure returns (uint256 ratioToken0, uint256 ratioToken1) {
        if (currentTick <= tickLower) {
            // 价格低于区间：全部 token0
            return (PERCENTAGE_BASE, 0);
        }

        if (currentTick >= tickUpper) {
            // 价格高于区间：全部 token1
            return (0, PERCENTAGE_BASE);
        }

        uint256 sc = uint256(sqrtPriceX96);
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
        if (amountIn == 0) revert InvalidAmount();
        if (slippageTolerance > PERCENTAGE_BASE) revert SlippageTooHigh();
        if (deadline < block.timestamp) revert DeadlineExceeded();
        IWETH wethLocal = weth;
        INonfungiblePositionManager positionManagerLocal = positionManager;

        // 处理 ETH 转 WETH
        if (tokenIn == address(wethLocal) && msg.value > 0) {
            if (msg.value != amountIn) revert EthAmountMismatch();
            wethLocal.deposit{value: msg.value}();
        }

        // 获取 pool 信息
        (
            address token0,
            address token1,
            int24 tick,
            uint160 sqrtPriceX96
        ) = getPoolInfo(tokenIn, tokenOut, poolFee);

        // 获取目标价格范围的投入比例
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min = 0;
        uint256 amount1Min = 0;
        {
            (uint256 ratioToken0, uint256 ratioToken1) = getUniDirectionalRatio(
                tick,
                sqrtPriceX96,
                tickLower,
                tickUpper
            );

            // 收取手续费
            uint256 protocolFeeAmount = calculateFee(amountIn);
            uint256 amountInAfterFee = amountIn - protocolFeeAmount;

            // 转入用户的代币（如果不是通过 ETH 已转入）
            if (!(tokenIn == address(wethLocal) && msg.value > 0)) {
                IERC20(tokenIn).safeTransferFrom(
                    msg.sender,
                    address(this),
                    amountIn
                );
            }
            if (protocolFeeAmount > 0) {
                if (tokenIn == address(wethLocal) && msg.value > 0) {
                    // 已从合约的 WETH 余额中支付手续费
                    IERC20(address(wethLocal)).safeTransfer(
                        feeRecipient,
                        protocolFeeAmount
                    );
                } else {
                    // 从用户账户转移代币作为手续费
                    IERC20(tokenIn).safeTransfer(
                        feeRecipient,
                        protocolFeeAmount
                    );
                }
            }

            // 计算需要的 token0 和 token1 的投入量（按比例分配）
            if (tokenIn == token0) {
                // 用户投入 token0，需要 swap 一部分换成 token1
                uint256 token0Amount = (amountInAfterFee * ratioToken0) /
                    PERCENTAGE_BASE;
                uint256 token0ForSwap = amountInAfterFee - token0Amount;

                if (token0ForSwap > 0) {
                    uint256 amountOut = _executeSwap(
                        tokenIn,
                        tokenOut,
                        token0ForSwap,
                        poolFee,
                        slippageTolerance,
                        deadline
                    );
                    amount0Desired = token0Amount;
                    amount1Desired = amountOut;
                } else {
                    // 无需 swap，全部投入 token0
                    amount0Desired = amountInAfterFee;
                    amount1Desired = 0;
                }
            } else {
                // 用户投入 token1，需要 swap 一部分换成 token0
                uint256 token1Amount = (amountInAfterFee * ratioToken1) /
                    PERCENTAGE_BASE;
                uint256 token1ForSwap = amountInAfterFee - token1Amount;

                if (token1ForSwap > 0) {
                    uint256 amountOut = _executeSwap(
                        tokenIn,
                        tokenOut,
                        token1ForSwap,
                        poolFee,
                        slippageTolerance,
                        deadline
                    );
                    amount0Desired = amountOut;
                    amount1Desired = token1Amount;
                } else {
                    // 无需 swap，全部投入 token1
                    amount0Desired = 0;
                    amount1Desired = amountInAfterFee;
                }
            }
        }

        // 计算 amount0Min 和 amount1Min
        if (amount0Desired == 0) {
            amount1Min =
                (amount1Desired * (PERCENTAGE_BASE - slippageTolerance)) /
                PERCENTAGE_BASE;
        } else if (amount1Desired == 0) {
            amount0Min =
                (amount0Desired * (PERCENTAGE_BASE - slippageTolerance)) /
                PERCENTAGE_BASE;
        } else {
            amount0Min = 0;
            amount1Min = 0;
        }

        // 批准 position manager
        if (amount0Desired > 0) {
            if (
                IERC20(token0).allowance(
                    address(this),
                    address(positionManagerLocal)
                ) == 0
            ) {
                IERC20(token0).approve(
                    address(positionManagerLocal),
                    type(uint256).max
                );
            }
        }
        if (amount1Desired > 0) {
            if (
                IERC20(token1).allowance(
                    address(this),
                    address(positionManagerLocal)
                ) == 0
            ) {
                IERC20(token1).approve(
                    address(positionManagerLocal),
                    type(uint256).max
                );
            }
        }

        // Mint LP
        (tokenId, liquidity, amount0, amount1) = positionManagerLocal.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
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

        // 计算并退还剩余代币（按交易链路记账），直接传入 amountDesired - amount
        _cleanupTokens(
            token0,
            token1,
            amount0Desired > amount0 ? amount0Desired - amount0 : 0,
            amount1Desired > amount1 ? amount1Desired - amount1 : 0
        );

        emit LiquidityAdded(tokenId, token0, token1, poolFee, liquidity);
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
        if (
            IERC20(tokenIn).allowance(
                address(this),
                address(swapRouterLocal)
            ) == 0
        ) {
            IERC20(tokenIn).approve(
                address(swapRouterLocal),
                type(uint256).max
            );
        }

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

    // 内部函数：按交易链路记账后，将剩余代币退还给调用者
    // 注意：不再读取合约全部余额，由调用方传入应退还的剩余金额
    function _cleanupTokens(
        address token0,
        address token1,
        uint256 return0,
        uint256 return1
    ) internal {
        if (return0 > 0) {
            IERC20(token0).safeTransfer(msg.sender, return0);
        }
        if (return1 > 0) {
            IERC20(token1).safeTransfer(msg.sender, return1);
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

        // 获取 NFT 位置信息
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min = 0;
        uint256 amount1Min = 0;
        address token0;
        address token1;
        {
            uint24 fee;
            int24 tickLower;
            int24 tickUpper;
            (
                ,
                ,
                token0,
                token1,
                fee,
                tickLower,
                tickUpper,
                ,
                ,
                ,
                ,

            ) = positionManagerLocal.positions(tokenId);

            if (token0 == address(0) || token1 == address(0))
                revert InvalidNFT();
            if (tokenIn != token0 && tokenIn != token1)
                revert InvalidTokenInput();

            // 处理 ETH 转 WETH
            if (tokenIn == address(wethLocal) && msg.value > 0) {
                if (msg.value != amountIn) revert EthAmountMismatch();
                wethLocal.deposit{value: msg.value}();
            }

            // 获取投入比例
            (, , int24 tick, uint160 sqrtPriceX96) = getPoolInfo(
                token0,
                token1,
                fee
            );
            (uint256 ratioToken0, uint256 ratioToken1) = getUniDirectionalRatio(
                tick,
                sqrtPriceX96,
                tickLower,
                tickUpper
            );

            // 收取手续费
            uint256 protocolFeeAmount = calculateFee(amountIn);
            uint256 amountInAfterFee = amountIn - protocolFeeAmount;

            // 转入用户的代币（如果不是通过 ETH 已转入）
            if (!(tokenIn == address(wethLocal) && msg.value > 0)) {
                IERC20(tokenIn).safeTransferFrom(
                    msg.sender,
                    address(this),
                    amountIn
                );
            }
            if (protocolFeeAmount > 0) {
                if (tokenIn == address(wethLocal) && msg.value > 0) {
                    IERC20(address(wethLocal)).safeTransfer(
                        feeRecipient,
                        protocolFeeAmount
                    );
                } else {
                    IERC20(tokenIn).safeTransfer(
                        feeRecipient,
                        protocolFeeAmount
                    );
                }
            }

            // 确定投入的 token 方向（是 token0 还是 token1）
            // 计算需要的投入量
            if (tokenIn == token0) {
                // 用户投入 token0，需要 swap 一部分换成 token1
                uint256 token0Amount = (amountInAfterFee * ratioToken0) /
                    PERCENTAGE_BASE;
                uint256 token0ForSwap = amountInAfterFee - token0Amount;

                if (token0ForSwap > 0) {
                    uint256 amountOut = _executeSwap(
                        token0,
                        token1,
                        token0ForSwap,
                        fee,
                        slippageTolerance,
                        deadline
                    );
                    amount0Desired = token0Amount;
                    amount1Desired = amountOut;
                } else {
                    // 无需 swap
                    amount0Desired = amountInAfterFee;
                    amount1Desired = 0;
                }
            } else {
                // 用户投入 token1，需要 swap 一部分换成 token0
                uint256 token1Amount = (amountInAfterFee * ratioToken1) /
                    PERCENTAGE_BASE;
                uint256 token1ForSwap = amountInAfterFee - token1Amount;

                if (token1ForSwap > 0) {
                    uint256 amountOut = _executeSwap(
                        token1,
                        token0,
                        token1ForSwap,
                        fee,
                        slippageTolerance,
                        deadline
                    );
                    amount0Desired = amountOut;
                    amount1Desired = token1Amount;
                } else {
                    // 无需 swap
                    amount0Desired = 0;
                    amount1Desired = amountInAfterFee;
                }
            }
        }

        // 计算 amount0Min 和 amount1Min
        if (amount0Desired == 0) {
            amount1Min =
                (amount1Desired * (PERCENTAGE_BASE - slippageTolerance)) /
                PERCENTAGE_BASE;
        } else if (amount1Desired == 0) {
            amount0Min =
                (amount0Desired * (PERCENTAGE_BASE - slippageTolerance)) /
                PERCENTAGE_BASE;
        } else {
            amount0Min = 0;
            amount1Min = 0;
        }

        // 批准 position manager
        if (amount0Desired > 0) {
            if (
                IERC20(token0).allowance(
                    address(this),
                    address(positionManagerLocal)
                ) == 0
            ) {
                IERC20(token0).approve(
                    address(positionManagerLocal),
                    type(uint256).max
                );
            }
        }
        if (amount1Desired > 0) {
            if (
                IERC20(token1).allowance(
                    address(this),
                    address(positionManagerLocal)
                ) == 0
            ) {
                IERC20(token1).approve(
                    address(positionManagerLocal),
                    type(uint256).max
                );
            }
        }

        // 增加流动性
        (liquidity, amount0, amount1) = positionManagerLocal.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            })
        );

        // 计算并退还剩余代币（按交易链路记账），直接传入 amountDesired - amount
        _cleanupTokens(
            token0,
            token1,
            amount0Desired > amount0 ? amount0Desired - amount0 : 0,
            amount1Desired > amount1 ? amount1Desired - amount1 : 0
        );

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
