// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

interface IUniswapV2Factory {
    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairsLength() external view returns (uint256);
}

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

/// @title DeployV2 — Deploy the full Uniswap V2 stack to a new chain
/// @notice Deployment order: WMON → UniswapV2Factory → UniswapV2Router02
///
/// Usage (local anvil):
///   forge script script/DeployV2.s.sol --broadcast --rpc-url http://127.0.0.1:8545 --private-key <KEY>
///
/// Usage (live chain, with existing WMON):
///   WMON=0x... FEE_TO_SETTER=0x... forge script script/DeployV2.s.sol --broadcast --rpc-url <RPC> --private-key <KEY>
///
/// Environment variables:
///   WMON            — address of the existing wrapped-native token; if unset, a new WMON is deployed
///   FEE_TO_SETTER   — address that will control the protocol fee switch; defaults to the deployer
contract DeployV2 is Script {
    function run() external {
        address deployer = msg.sender;
        address feeToSetter = vm.envOr("FEE_TO_SETTER", deployer);
        address wmonAddr = vm.envOr("WMON", address(0));

        vm.startBroadcast();

        // 1. WMON — deploy only if no existing address was provided
        if (wmonAddr == address(0)) {
            wmonAddr = deployCode("WMON.sol:WMON");
            console.log("WMON deployed at:", wmonAddr);
        } else {
            console.log("Using existing WETH at:", wmonAddr);
        }

        // 2. UniswapV2Factory
        address factoryAddr = deployCode("UniswapV2Factory.sol:UniswapV2Factory", abi.encode(feeToSetter));
        console.log("UniswapV2Factory deployed at:", factoryAddr);

        // Log the init code hash — needed for UniswapV2Library.pairFor()
        bytes32 initCodeHash = keccak256(vm.getCode("UniswapV2Pair.sol:UniswapV2Pair"));
        console.log("UniswapV2Pair init code hash:");
        console.logBytes32(initCodeHash);

        // 3. UniswapV2Router02
        address routerAddr = deployCode("UniswapV2Router02.sol:UniswapV2Router02", abi.encode(factoryAddr, wmonAddr));
        console.log("UniswapV2Router02 deployed at:", routerAddr);

        vm.stopBroadcast();

        // ---- Post-deployment sanity checks ----
        IUniswapV2Factory factory = IUniswapV2Factory(factoryAddr);
        IUniswapV2Router02 router = IUniswapV2Router02(routerAddr);

        require(factory.feeToSetter() == feeToSetter, "factory feeToSetter mismatch");
        require(router.factory() == factoryAddr, "router factory mismatch");
        require(router.WETH() == wmonAddr, "router WMON mismatch");

        console.log("\n=== Deployment Summary ===");
        console.log("  WMON:              ", wmonAddr);
        console.log("  UniswapV2Factory:   ", factoryAddr);
        console.log("  UniswapV2Router02:  ", routerAddr);
        console.log("  feeToSetter:        ", feeToSetter);
        console.log("==========================");
    }
}
