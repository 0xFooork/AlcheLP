// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import "forge-std/console.sol";
import {UniswapLP} from "../src/UniswapLP.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract UniswapLPScript is Script {
    using stdJson for string;

    string public constant MAINNET = "ethereum";
    string public constant TESTNET = "sepolia";

    struct NetworkConfig {
        string chainName;
        uint256 chainId;
        address uniswapV3Router;
        address uniswapV3Factory;
        address uniswapV3PositionManager;
        address weth;
    }

    function run() public {
        // 从环境变量获取网络选择，默认为 sepolia
        string memory network = vm.envOr("NETWORK", string("sepolia"));

        // 确定部署网络
        require(
            keccak256(abi.encodePacked(network)) ==
                keccak256(abi.encodePacked(MAINNET)) ||
                keccak256(abi.encodePacked(network)) ==
                keccak256(abi.encodePacked(TESTNET)),
            "Invalid network"
        );

        // 读取部署配置
        NetworkConfig memory config = readNetworkConfig(network);

        vm.startBroadcast();

        // 部署合约
        address feeRecipient = msg.sender;
        UniswapLP uniswapLP = new UniswapLP(
            config.uniswapV3Router,
            config.uniswapV3PositionManager,
            config.uniswapV3Factory,
            feeRecipient,
            msg.sender
        );

        vm.stopBroadcast();

        // 记录部署地址
        recordDeployment(network, address(uniswapLP));

        console.log("UniswapLP deployed at:", address(uniswapLP));
        console.log("Network:", config.chainName);
        console.log("Chain ID:", config.chainId);
        console.log("Fee Recipient:", feeRecipient);
    }

    function readNetworkConfig(
        string memory network
    ) internal view returns (NetworkConfig memory) {
        // 获取配置文件路径
        string memory path = string(
            abi.encodePacked("./deployments/", network, ".json")
        );

        // 读取 JSON 文件
        string memory json = vm.readFile(path);

        // 解析 JSON
        NetworkConfig memory config;
        config.chainName = json.readString(".chainName");
        config.chainId = json.readUint(".chainId");
        config.uniswapV3Router = json.readAddress(".uniswapV3Router");
        config.uniswapV3Factory = json.readAddress(".uniswapV3Factory");
        config.uniswapV3PositionManager = json.readAddress(
            ".uniswapV3PositionManager"
        );
        config.weth = json.readAddress(".weth");

        return config;
    }

    function recordDeployment(
        string memory network,
        address contractAddress
    ) internal {
        // 创建部署记录
        string memory deploymentRecord = string(
            abi.encodePacked(
                "{\n",
                '  "network": "',
                network,
                '",\n',
                '  "contractAddress": "',
                Strings.toHexString(contractAddress),
                '",\n',
                '  "deploymentBlock": "',
                Strings.toString(block.number),
                '",\n',
                '  "deploymentTime": "',
                Strings.toString(block.timestamp),
                '",\n',
                '  "deployer": "',
                Strings.toHexString(msg.sender),
                '"\n',
                "}"
            )
        );

        // 保存到文件
        string memory filename = string(
            abi.encodePacked("./deployments/deployment-", network, ".json")
        );
        vm.writeFile(filename, deploymentRecord);
    }
}
