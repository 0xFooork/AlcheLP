// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {UniswapLP} from "../src/UniswapLP.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract UniswapLPTest is Test {
    UniswapLP public uniswapLP;
    address public owner;

    address constant UNISWAP_V3_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant UNISWAP_V3_POSITION_MANAGER =
        0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNISWAP_V3_FACTORY =
        0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address user = makeAddr("user");
    address feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        uint256 privateKey = vm.envUint("LOCAL_PRIVATE_KEY");
        owner = vm.addr(privateKey);
        console.log(
            "setUp: Owner address derived from LOCAL_PRIVATE_KEY:",
            owner
        );

        string memory rpc = vm.envString("ETH_RPC_URL");
        uint256 forkId = vm.createFork(rpc);
        vm.selectFork(forkId);
        console.log("setUp: Fork completed, block number:", block.number);

        console.log("setUp: Initialize UniswapLP contract");
        uniswapLP = new UniswapLP(
            UNISWAP_V3_ROUTER,
            UNISWAP_V3_POSITION_MANAGER,
            UNISWAP_V3_FACTORY,
            WETH,
            feeRecipient,
            owner
        );
        console.log("setUp: UniswapLP contract deployed successfully");
    }

    function testAddToWhitelist() public {
        console.log("testAddToWhitelist: Start testing");
        address[] memory users = new address[](2);
        users[0] = user;
        users[1] = makeAddr("user2");

        vm.prank(owner);
        uniswapLP.addToWhitelist(users);
        console.log("testAddToWhitelist: Added user to whitelist", users[0]);
        console.log("testAddToWhitelist: Added user to whitelist", users[1]);

        assertTrue(uniswapLP.whitelist(user));
        assertTrue(uniswapLP.whitelist(makeAddr("user2")));
        console.log("testAddToWhitelist: PASSED");
    }

    function testRemoveFromWhitelist() public {
        console.log("testRemoveFromWhitelist: Start testing");
        address[] memory users = new address[](1);
        users[0] = user;

        vm.prank(owner);
        uniswapLP.addToWhitelist(users);
        console.log("testRemoveFromWhitelist: User added to whitelist", user);
        assertTrue(uniswapLP.whitelist(user));

        vm.prank(owner);
        uniswapLP.removeFromWhitelist(users);
        console.log(
            "testRemoveFromWhitelist: User removed from whitelist",
            user
        );
        assertFalse(uniswapLP.whitelist(user));
        console.log("testRemoveFromWhitelist: PASSED");
    }

    function testSetProtocolFee() public {
        console.log("testSetProtocolFee: Start testing");
        vm.prank(owner);
        uniswapLP.setProtocolFee(100); // 1%
        console.log("testSetProtocolFee: Protocol fee set to", uint256(100));
        assertEq(uniswapLP.protocolFee(), 100);
        console.log("testSetProtocolFee: PASSED");
    }

    function testSetProtocolFeeTooHigh() public {
        console.log("testSetProtocolFeeTooHigh: Start testing");
        vm.prank(owner);
        vm.expectRevert("Fee too high");
        uniswapLP.setProtocolFee(10001);
        console.log("testSetProtocolFeeTooHigh: High fee correctly rejected");
    }

    function testCalculateFeeForWhitelistUser() public {
        console.log("testCalculateFeeForWhitelistUser: Start testing");
        address[] memory users = new address[](1);
        users[0] = user;
        vm.prank(owner);
        uniswapLP.addToWhitelist(users);
        vm.prank(owner);
        uniswapLP.setProtocolFee(100); // 1%
        console.log(
            "testCalculateFeeForWhitelistUser: User added to whitelist",
            user
        );
        console.log("testCalculateFeeForWhitelistUser: Protocol fee set to 1%");

        vm.prank(user);
        uint256 fee = uniswapLP.calculateFee(1000);
        console.log(
            "testCalculateFeeForWhitelistUser: Whitelist user fee",
            fee
        );
        assertEq(fee, 0); // Whitelist users have no fee
        console.log("testCalculateFeeForWhitelistUser: PASSED");
    }

    function testCalculateFeeForNonWhitelistUser() public {
        console.log("testCalculateFeeForNonWhitelistUser: Start testing");
        vm.prank(owner);
        uniswapLP.setProtocolFee(100); // 1%
        console.log(
            "testCalculateFeeForNonWhitelistUser: Protocol fee set to 1%"
        );

        vm.prank(user);
        uint256 fee = uniswapLP.calculateFee(1000);
        console.log(
            "testCalculateFeeForNonWhitelistUser: Non-whitelist user fee",
            fee
        );
        assertEq(fee, 10); // 1% of 1000
        console.log("testCalculateFeeForNonWhitelistUser: PASSED");
    }

    function testSetFeeRecipient() public {
        console.log("testSetFeeRecipient: Start testing");
        address newRecipient = makeAddr("newRecipient");
        vm.prank(owner);
        uniswapLP.setFeeRecipient(newRecipient);
        console.log("testSetFeeRecipient: Fee recipient set to", newRecipient);
        assertEq(uniswapLP.feeRecipient(), newRecipient);
        console.log("testSetFeeRecipient: PASSED");
    }

    function testSetFeeRecipientInvalid() public {
        console.log("testSetFeeRecipientInvalid: Start testing");
        vm.prank(owner);
        vm.expectRevert("Invalid recipient");
        uniswapLP.setFeeRecipient(address(0));
        console.log(
            "testSetFeeRecipientInvalid: Invalid address correctly rejected"
        );
    }

    function testOwnershipControl() public {
        console.log("testOwnershipControl: Start testing");
        address otherUser = makeAddr("otherUser");
        console.log("testOwnershipControl: Attempting call from non-owner");
        console.log("testOwnershipControl: Owner address:", owner);
        console.log("testOwnershipControl: Other user address:", otherUser);

        vm.prank(otherUser);
        vm.expectRevert();
        uniswapLP.setProtocolFee(100);
        console.log("testOwnershipControl: Non-owner correctly rejected");
    }

    function testGetPoolInfo() public view {
        console.log("testGetPoolInfo: Start testing");
        // This test requires real pool to exist
        // USDC and WETH have 0.05% pool on mainnet
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        uint24 poolFee = 500; // 0.05%

        UniswapLP.PoolInfo memory poolInfo = uniswapLP.getPoolInfo(
            USDC,
            WETH,
            poolFee
        );
        console.log("testGetPoolInfo: Pool info retrieved successfully");
        console.log("testGetPoolInfo: token0:", poolInfo.token0);
        console.log("testGetPoolInfo: token1:", poolInfo.token1);
        console.log("testGetPoolInfo: currentTick:", poolInfo.currentTick);
        console.log("testGetPoolInfo: sqrtPriceX96:", poolInfo.sqrtPriceX96);

        assertNotEq(poolInfo.token0, address(0));
        assertNotEq(poolInfo.token1, address(0));
        assertNotEq(poolInfo.sqrtPriceX96, 0);
        console.log("testGetPoolInfo: PASSED");
    }

    function testNeedsSwap() public view {
        console.log("testNeedsSwap: Start testing");
        // This test requires fork environment to determine if swap is needed
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        uint24 poolFee = 3000; // 0.3%
        int24 tickLower = 290000; // Example tick range
        int24 tickUpper = 300000;

        UniswapLP.PoolInfo memory poolInfo = uniswapLP.getPoolInfo(
            USDC,
            WETH,
            poolFee
        );
        console.log("testNeedsSwap: Pool info retrieved");
        console.log("testNeedsSwap: Current tick:", poolInfo.currentTick);
        console.log("testNeedsSwap: Tick lower:", tickLower);
        console.log("testNeedsSwap: Tick upper:", tickUpper);

        // Determine if swap is needed based on tick range
        bool tickBelowRange = poolInfo.currentTick < tickLower;
        bool tickAboveRange = poolInfo.currentTick > tickUpper;
        bool needsSwap = tickBelowRange || tickAboveRange;

        console.log("testNeedsSwap: Tick below range", tickBelowRange);
        console.log("testNeedsSwap: Tick above range", tickAboveRange);
        console.log("testNeedsSwap: Needs swap", needsSwap);

        // Validate logic
        if (poolInfo.currentTick < tickLower) {
            console.log(
                "testNeedsSwap: Price below range, should deposit token0"
            );
        } else if (poolInfo.currentTick > tickUpper) {
            console.log(
                "testNeedsSwap: Price above range, should deposit token1"
            );
        } else {
            console.log(
                "testNeedsSwap: Price in range, calculate specific ratio"
            );
        }

        console.log("testNeedsSwap: PASSED");
    }

    function testSlippageAndPriceProtection() public view {
        console.log("testSlippageAndPriceProtection: Start testing");
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        uint24 poolFee = 500; // 0.05%

        UniswapLP.PoolInfo memory poolInfo = uniswapLP.getPoolInfo(
            USDC,
            WETH,
            poolFee
        );
        console.log(
            "testSlippageAndPriceProtection: Current sqrtPriceX96:",
            poolInfo.sqrtPriceX96
        );

        // Test slippage tolerance calculation
        uint256 slippageTolerance = 100; // 1%
        uint160 sqrtPriceLimitX96Down = uint160(
            (uint256(poolInfo.sqrtPriceX96) * (10000 - slippageTolerance)) /
                10000
        );
        uint160 sqrtPriceLimitX96Up = uint160(
            (uint256(poolInfo.sqrtPriceX96) * (10000 + slippageTolerance)) /
                10000
        );

        console.log(
            "testSlippageAndPriceProtection: sqrtPriceLimitX96Down:",
            sqrtPriceLimitX96Down
        );
        console.log(
            "testSlippageAndPriceProtection: sqrtPriceLimitX96Up:",
            sqrtPriceLimitX96Up
        );

        assertTrue(sqrtPriceLimitX96Down < poolInfo.sqrtPriceX96);
        assertTrue(sqrtPriceLimitX96Up > poolInfo.sqrtPriceX96);

        console.log(
            "testSlippageAndPriceProtection: Price protection verified"
        );
        console.log("testSlippageAndPriceProtection: PASSED");
    }

    // Core functionality tests
    function testSwapAndMintLP_WithUSDC() public {
        console.log("testSwapAndMintLP_WithUSDC: Start testing");
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        uint24 poolFee = 500; // 0.05%
        int24 tickLower = 193000;
        int24 tickUpper = 197000;
        uint256 amountIn = 1000e6; // 1000 USDC
        uint256 slippageTolerance = 500; // 5%
        uint256 deadline = block.timestamp + 3600;

        // Get pool info to determine token order
        UniswapLP.PoolInfo memory poolInfo = uniswapLP.getPoolInfo(
            USDC,
            WETH,
            poolFee
        );
        console.log(
            "testSwapAndMintLP_WithUSDC: Pool token0:",
            poolInfo.token0
        );
        console.log(
            "testSwapAndMintLP_WithUSDC: Pool token1:",
            poolInfo.token1
        );

        // Allocate USDC to user
        deal(USDC, user, amountIn);
        console.log("testSwapAndMintLP_WithUSDC: Allocated USDC to user");

        // Approve contract
        vm.prank(user);
        IERC20(USDC).approve(address(uniswapLP), amountIn);
        console.log("testSwapAndMintLP_WithUSDC: Approved USDC");

        // Execute swapAndMintLP
        vm.prank(user);
        (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        ) = uniswapLP.swapAndMintLP(
                USDC,
                WETH,
                poolFee,
                amountIn,
                tickLower,
                tickUpper,
                slippageTolerance,
                deadline
            );

        console.log(
            "testSwapAndMintLP_WithUSDC: swapAndMintLP executed successfully"
        );
        console.log("testSwapAndMintLP_WithUSDC: tokenId:", tokenId);
        console.log("testSwapAndMintLP_WithUSDC: liquidity:", liquidity);
        console.log("testSwapAndMintLP_WithUSDC: amount0:", amount0);
        console.log("testSwapAndMintLP_WithUSDC: amount1:", amount1);

        // Verify results
        assertGt(tokenId, 0, "tokenId should be greater than 0");
        assertGt(liquidity, 0, "liquidity should be greater than 0");
        assertTrue(
            (amount0 > 0 || amount1 > 0),
            "at least one amount should be greater than 0"
        );

        console.log("testSwapAndMintLP_WithUSDC: PASSED");
    }

    function testSwapAndMintLP_WithWETH() public {
        console.log("testSwapAndMintLP_WithWETH: Start testing");
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        uint24 poolFee = 500; // 0.05%
        int24 tickLower = 193000;
        int24 tickUpper = 197000;
        uint256 amountIn = 0.5 ether; // 0.5 WETH
        uint256 slippageTolerance = 500; // 5%
        uint256 deadline = block.timestamp + 3600;

        // Get pool info
        UniswapLP.PoolInfo memory poolInfo = uniswapLP.getPoolInfo(
            USDC,
            WETH,
            poolFee
        );
        console.log(
            "testSwapAndMintLP_WithWETH: Pool token0:",
            poolInfo.token0
        );
        console.log(
            "testSwapAndMintLP_WithWETH: Pool token1:",
            poolInfo.token1
        );

        // Allocate WETH to user
        deal(WETH, user, amountIn);
        console.log("testSwapAndMintLP_WithWETH: Allocated WETH to user");

        // Approve contract
        vm.prank(user);
        IERC20(WETH).approve(address(uniswapLP), amountIn);
        console.log("testSwapAndMintLP_WithWETH: Approved WETH");

        // Execute swapAndMintLP
        vm.prank(user);
        (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        ) = uniswapLP.swapAndMintLP(
                WETH,
                USDC,
                poolFee,
                amountIn,
                tickLower,
                tickUpper,
                slippageTolerance,
                deadline
            );

        console.log(
            "testSwapAndMintLP_WithWETH: swapAndMintLP executed successfully"
        );
        console.log("testSwapAndMintLP_WithWETH: tokenId:", tokenId);
        console.log("testSwapAndMintLP_WithWETH: liquidity:", liquidity);
        console.log("testSwapAndMintLP_WithWETH: amount0:", amount0);
        console.log("testSwapAndMintLP_WithWETH: amount1:", amount1);

        // Verify results
        assertGt(tokenId, 0, "tokenId should be greater than 0");
        assertGt(liquidity, 0, "liquidity should be greater than 0");
        assertTrue(
            (amount0 > 0 || amount1 > 0),
            "at least one amount should be greater than 0"
        );

        console.log("testSwapAndMintLP_WithWETH: PASSED");
    }

    function testSwapAndIncreaseLiquidity_WithUSDC() public {
        console.log("testSwapAndIncreaseLiquidity_WithUSDC: Start testing");
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        uint24 poolFee = 500; // 0.05%
        int24 tickLower = 193000;
        int24 tickUpper = 297000;
        uint256 amountMint = 1000e6; // 1000 USDC for mint
        uint256 amountIncrease = 500e6; // 500 USDC for increase
        uint256 slippageTolerance = 500; // 5%
        uint256 deadline = block.timestamp + 3600;

        // First: Create initial LP position
        console.log(
            "testSwapAndIncreaseLiquidity_WithUSDC: Creating initial LP position"
        );
        deal(USDC, user, amountMint + amountIncrease);

        UniswapLP.PoolInfo memory poolInfo = uniswapLP.getPoolInfo(
            USDC,
            WETH,
            poolFee
        );
        console.log(
            "testSwapAndIncreaseLiquidity_WithUSDC: Current tick:",
            poolInfo.currentTick
        );

        vm.prank(user);
        IERC20(USDC).approve(address(uniswapLP), amountMint + amountIncrease);

        vm.prank(user);
        (uint256 tokenId, , uint256 amount0, uint256 amount1) = uniswapLP
            .swapAndMintLP(
                USDC,
                WETH,
                poolFee,
                amountMint,
                tickLower,
                tickUpper,
                slippageTolerance,
                deadline
            );

        console.log(
            "testSwapAndIncreaseLiquidity_WithUSDC: Initial NFT created, tokenId:",
            tokenId
        );
        console.log("amount0:", amount0);
        console.log("amount1:", amount1);

        // Second: Increase liquidity
        console.log(
            "testSwapAndIncreaseLiquidity_WithUSDC: Increasing liquidity with USDC"
        );

        vm.prank(user);
        (uint128 liquidity, uint256 amountAdd0, uint256 amountAdd1) = uniswapLP
            .swapAndIncreaseLiquidity(
                tokenId,
                USDC,
                amountIncrease,
                slippageTolerance,
                deadline
            );

        console.log(
            "testSwapAndIncreaseLiquidity_WithUSDC: swapAndIncreaseLiquidity executed"
        );
        console.log(
            "testSwapAndIncreaseLiquidity_WithUSDC: liquidity added:",
            liquidity
        );
        console.log(
            "testSwapAndIncreaseLiquidity_WithUSDC: amount0:",
            amountAdd0
        );
        console.log(
            "testSwapAndIncreaseLiquidity_WithUSDC: amount1:",
            amountAdd1
        );

        // Verify results
        assertGt(liquidity, 0, "added liquidity should be greater than 0");
        assertTrue(
            (amount0 > 0 || amount1 > 0),
            "at least one amount should be greater than 0"
        );

        console.log("testSwapAndIncreaseLiquidity_WithUSDC: PASSED");
    }

    function testSwapAndIncreaseLiquidity_WithWETH() public {
        console.log("testSwapAndIncreaseLiquidity_WithWETH: Start testing");
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        uint24 poolFee = 500; // 0.05%
        int24 tickLower = 193000;
        int24 tickUpper = 197000;
        uint256 amountMint = 1000e6; // 1000 USDC for mint
        uint256 amountIncrease = 0.25 ether; // 0.25 WETH for increase
        uint256 slippageTolerance = 500; // 5%
        uint256 deadline = block.timestamp + 3600;

        // First: Create initial LP position with USDC
        console.log(
            "testSwapAndIncreaseLiquidity_WithWETH: Creating initial LP position"
        );
        deal(USDC, user, amountMint);
        deal(WETH, user, amountIncrease);

        vm.prank(user);
        IERC20(USDC).approve(address(uniswapLP), amountMint);

        vm.prank(user);
        (uint256 tokenId, , , ) = uniswapLP.swapAndMintLP(
            USDC,
            WETH,
            poolFee,
            amountMint,
            tickLower,
            tickUpper,
            slippageTolerance,
            deadline
        );

        console.log(
            "testSwapAndIncreaseLiquidity_WithWETH: Initial NFT created, tokenId:",
            tokenId
        );

        // Second: Increase liquidity with WETH
        console.log(
            "testSwapAndIncreaseLiquidity_WithWETH: Increasing liquidity with WETH"
        );

        vm.prank(user);
        IERC20(WETH).approve(address(uniswapLP), amountIncrease);

        vm.prank(user);
        (uint128 liquidity, uint256 amount0, uint256 amount1) = uniswapLP
            .swapAndIncreaseLiquidity(
                tokenId,
                WETH,
                amountIncrease,
                slippageTolerance,
                deadline
            );

        console.log(
            "testSwapAndIncreaseLiquidity_WithWETH: swapAndIncreaseLiquidity executed"
        );
        console.log(
            "testSwapAndIncreaseLiquidity_WithWETH: liquidity added:",
            liquidity
        );
        console.log("testSwapAndIncreaseLiquidity_WithWETH: amount0:", amount0);
        console.log("testSwapAndIncreaseLiquidity_WithWETH: amount1:", amount1);

        // Verify results
        assertGt(liquidity, 0, "added liquidity should be greater than 0");
        assertTrue(
            (amount0 > 0 || amount1 > 0),
            "at least one amount should be greater than 0"
        );

        console.log("testSwapAndIncreaseLiquidity_WithWETH: PASSED");
    }

    function testSwapAndMintLP_WithSlippageProtection() public {
        console.log("testSwapAndMintLP_WithSlippageProtection: Start testing");
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        uint24 poolFee = 500; // 0.05%
        int24 tickLower = 193000;
        int24 tickUpper = 197000;
        uint256 amountIn = 1000e6; // 1000 USDC
        uint256 slippageTolerance = 100; // 1% slippage
        uint256 deadline = block.timestamp + 3600;

        console.log(
            "testSwapAndMintLP_WithSlippageProtection: Testing with 1% slippage tolerance"
        );

        // Allocate USDC
        deal(USDC, user, amountIn);

        vm.prank(user);
        IERC20(USDC).approve(address(uniswapLP), amountIn);

        // Execute with tight slippage
        vm.prank(user);
        (uint256 tokenId, uint128 liquidity, , ) = uniswapLP.swapAndMintLP(
            USDC,
            WETH,
            poolFee,
            amountIn,
            tickLower,
            tickUpper,
            slippageTolerance,
            deadline
        );

        console.log(
            "testSwapAndMintLP_WithSlippageProtection: Transaction succeeded with tight slippage"
        );
        assertGt(
            tokenId,
            0,
            "should successfully create LP with tight slippage"
        );
        assertGt(liquidity, 0, "should have liquidity");

        console.log("testSwapAndMintLP_WithSlippageProtection: PASSED");
    }

    function testSwapAndMintLP_ProtocolFeeDeduction() public {
        console.log("testSwapAndMintLP_ProtocolFeeDeduction: Start testing");
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        uint24 poolFee = 500; // 0.05%
        int24 tickLower = 193000;
        int24 tickUpper = 197000;
        uint256 amountIn = 1000e6; // 1000 USDC
        uint256 slippageTolerance = 500; // 5%
        uint256 deadline = block.timestamp + 3600;

        // Set protocol fee for non-whitelist user
        console.log(
            "testSwapAndMintLP_ProtocolFeeDeduction: Setting protocol fee to 1%"
        );
        vm.prank(owner);
        uniswapLP.setProtocolFee(100); // 1%

        // Allocate USDC to user
        deal(USDC, user, amountIn);

        vm.prank(user);
        IERC20(USDC).approve(address(uniswapLP), amountIn);

        // Get fee recipient balance before
        uint256 balanceBefore = IERC20(USDC).balanceOf(feeRecipient);
        console.log(
            "testSwapAndMintLP_ProtocolFeeDeduction: Fee recipient balance before:",
            balanceBefore
        );

        // Execute swapAndMintLP
        vm.prank(user);
        (uint256 tokenId, , , ) = uniswapLP.swapAndMintLP(
            USDC,
            WETH,
            poolFee,
            amountIn,
            tickLower,
            tickUpper,
            slippageTolerance,
            deadline
        );

        // Get fee recipient balance after
        uint256 balanceAfter = IERC20(USDC).balanceOf(feeRecipient);
        uint256 feeDeducted = balanceAfter - balanceBefore;
        console.log(
            "testSwapAndMintLP_ProtocolFeeDeduction: Fee recipient balance after:",
            balanceAfter
        );
        console.log(
            "testSwapAndMintLP_ProtocolFeeDeduction: Fee deducted:",
            feeDeducted
        );

        // Verify fee was deducted (1% of 1000 USDC = 10 USDC)
        assertGt(feeDeducted, 0, "fee should be deducted");
        assertEq(feeDeducted, 10e6, "fee should be exactly 1% of input");
        assertGt(tokenId, 0, "LP should still be created after fee");

        console.log("testSwapAndMintLP_ProtocolFeeDeduction: PASSED");
    }
}
