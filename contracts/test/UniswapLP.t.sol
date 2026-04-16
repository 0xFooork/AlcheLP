// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {UniswapLP} from "../src/UniswapLP.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract UniswapLPTest is Test {
    UniswapLP public uniswapLP;

    address constant UNISWAP_V3_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant UNISWAP_V3_POSITION_MANAGER =
        0xC36442b4A4522E871399CD717ABd90098588639F;
    address constant UNISWAP_V3_FACTORY =
        0x1F98431c8aD98523631AE4a59f267346ea31F984;

    address user = makeAddr("user");
    address feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        uniswapLP = new UniswapLP(
            UNISWAP_V3_ROUTER,
            UNISWAP_V3_POSITION_MANAGER,
            UNISWAP_V3_FACTORY,
            feeRecipient,
            msg.sender
        );
    }

    function testAddToWhitelist() public {
        address[] memory users = new address[](2);
        users[0] = user;
        users[1] = makeAddr("user2");

        uniswapLP.addToWhitelist(users);

        assertTrue(uniswapLP.whitelist(user));
        assertTrue(uniswapLP.whitelist(makeAddr("user2")));
    }

    function testRemoveFromWhitelist() public {
        address[] memory users = new address[](1);
        users[0] = user;

        uniswapLP.addToWhitelist(users);
        assertTrue(uniswapLP.whitelist(user));

        uniswapLP.removeFromWhitelist(users);
        assertFalse(uniswapLP.whitelist(user));
    }

    function testSetProtocolFee() public {
        uniswapLP.setProtocolFee(100); // 1%
        assertEq(uniswapLP.protocolFee(), 100);
    }

    function testSetProtocolFeeTooHigh() public {
        vm.expectRevert("Fee too high");
        uniswapLP.setProtocolFee(10001);
    }

    function testCalculateFeeForWhitelistUser() public {
        address[] memory users = new address[](1);
        users[0] = user;
        uniswapLP.addToWhitelist(users);
        uniswapLP.setProtocolFee(100); // 1%

        vm.prank(user);
        uint256 fee = uniswapLP.calculateFee(1000);
        assertEq(fee, 0); // 白名单用户无手续费
    }

    function testCalculateFeeForNonWhitelistUser() public {
        uniswapLP.setProtocolFee(100); // 1%

        vm.prank(user);
        uint256 fee = uniswapLP.calculateFee(1000);
        assertEq(fee, 10); // 1% of 1000
    }

    function testSetFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        uniswapLP.setFeeRecipient(newRecipient);
        assertEq(uniswapLP.feeRecipient(), newRecipient);
    }

    function testSetFeeRecipientInvalid() public {
        vm.expectRevert("Invalid recipient");
        uniswapLP.setFeeRecipient(address(0));
    }

    function testOwnershipControl() public {
        address otherUser = makeAddr("otherUser");

        vm.prank(otherUser);
        vm.expectRevert();
        uniswapLP.setProtocolFee(100);
    }

    function testGetPoolInfo() public {
        // 这个测试需要真实的 pool 存在
        // USDC 和 WETH 在主网上有 0.3% pool
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        uint24 poolFee = 3000; // 0.3%

        // 这个测试应该在 fork 测试中运行
        // vm.createSelectFork(mainnet);
        // UniswapLP.PoolInfo memory poolInfo = uniswapLP.getPoolInfo(USDC, WETH, poolFee);
        // assertNotEq(poolInfo.token0, address(0));
        // assertNotEq(poolInfo.token1, address(0));
    }

    function testNeedsSwap() public {
        // 这个测试也需要 fork 环境
        // 用于判断是否需要 swap
    }
}
