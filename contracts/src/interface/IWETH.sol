// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

interface IWETH {
    function deposit() external payable;

    function withdraw(uint256 amount) external;

    function approve(address spender, uint256 amount) external returns (bool);

    function transfer(address to, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);
}
