// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

interface IERC20Like {
    function approve(address spender, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface IUniswapV2FactoryLike {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Router02Like {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract MarketMaker is Script {
    uint256 internal constant DEFAULT_SUPPLY = 1_000_000 ether;
    uint256 internal constant AB_LIQUIDITY_A = 10_000 ether;
    uint256 internal constant AB_LIQUIDITY_B = 20_000 ether;
    uint256 internal constant BC_LIQUIDITY_B = 15_000 ether;
    uint256 internal constant BC_LIQUIDITY_C = 30_000 ether;
    uint256 internal constant AB_SWAP_IN = 100 ether;
    uint256 internal constant AC_SWAP_IN = 75 ether;

    struct RunState {
        address tokenA;
        address tokenB;
        address tokenC;
        address pairAB;
        address pairBC;
        uint256 liquidityAB;
        uint256 liquidityBC;
        uint256 swapABIn;
        uint256 swapABOut;
        uint256 swapACIn;
        uint256 swapACOut;
    }

    function run() external {
        address factoryAddr = vm.envAddress("FACTORY");
        address routerAddr = vm.envAddress("ROUTER");
        uint256 initialSupply = vm.envOr("INITIAL_SUPPLY", DEFAULT_SUPPLY);
        uint256 deadline = block.timestamp + 1 hours;
        RunState memory state;

        IUniswapV2FactoryLike factory = IUniswapV2FactoryLike(factoryAddr);
        IUniswapV2Router02Like router = IUniswapV2Router02Like(routerAddr);

        vm.startBroadcast();

        state.tokenA = _deployToken("Token A", "TKA", initialSupply);
        state.tokenB = _deployToken("Token B", "TKB", initialSupply);
        state.tokenC = _deployToken("Token C", "TKC", initialSupply);

        _approveRouter(state.tokenA, routerAddr);
        _approveRouter(state.tokenB, routerAddr);
        _approveRouter(state.tokenC, routerAddr);

        state.pairAB = _createPairIfMissing(factory, state.tokenA, state.tokenB);
        state.pairBC = _createPairIfMissing(factory, state.tokenB, state.tokenC);

        (state.liquidityAB, state.liquidityBC) =
            _addLiquidityPositions(router, state.tokenA, state.tokenB, state.tokenC, deadline);
        (state.swapABIn, state.swapABOut) = _swapAToB(router, state.tokenA, state.tokenB, deadline);
        (state.swapACIn, state.swapACOut) =
            _swapAToCThroughB(router, state.tokenA, state.tokenB, state.tokenC, deadline);

        vm.stopBroadcast();

        console.log("Factory:", factoryAddr);
        console.log("Router:", routerAddr);
        console.log("Token A:", state.tokenA);
        console.log("Token B:", state.tokenB);
        console.log("Token C:", state.tokenC);
        console.log("Pair A/B:", state.pairAB);
        console.log("Pair B/C:", state.pairBC);
        console.log("LP minted A/B:", state.liquidityAB);
        console.log("LP minted B/C:", state.liquidityBC);
        console.log("Swap A->B in:", state.swapABIn);
        console.log("Swap A->B out:", state.swapABOut);
        console.log("Swap A->B->C in:", state.swapACIn);
        console.log("Swap A->B->C out:", state.swapACOut);
        console.log("Deployer Token A balance:", IERC20Like(state.tokenA).balanceOf(msg.sender));
        console.log("Deployer Token B balance:", IERC20Like(state.tokenB).balanceOf(msg.sender));
        console.log("Deployer Token C balance:", IERC20Like(state.tokenC).balanceOf(msg.sender));
    }

    function _addLiquidityPositions(
        IUniswapV2Router02Like router,
        address tokenA,
        address tokenB,
        address tokenC,
        uint256 deadline
    ) internal returns (uint256 liquidityAB, uint256 liquidityBC) {
        (,, liquidityAB) = router.addLiquidity(
            tokenA, tokenB, AB_LIQUIDITY_A, AB_LIQUIDITY_B, 0, 0, msg.sender, deadline
        );

        (,, liquidityBC) =
            router.addLiquidity(tokenB, tokenC, BC_LIQUIDITY_B, BC_LIQUIDITY_C, 0, 0, msg.sender, deadline);
    }

    function _swapAToB(IUniswapV2Router02Like router, address tokenA, address tokenB, uint256 deadline)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        address[] memory path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;
        return _swapAlongPath(router, path, AB_SWAP_IN, deadline);
    }

    function _swapAToCThroughB(
        IUniswapV2Router02Like router,
        address tokenA,
        address tokenB,
        address tokenC,
        uint256 deadline
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        address[] memory path = new address[](3);
        path[0] = tokenA;
        path[1] = tokenB;
        path[2] = tokenC;
        return _swapAlongPath(router, path, AC_SWAP_IN, deadline);
    }

    function _swapAlongPath(IUniswapV2Router02Like router, address[] memory path, uint256 amountIn, uint256 deadline)
        internal
        returns (uint256 spentAmount, uint256 receivedAmount)
    {
        uint256[] memory quotedAmounts = router.getAmountsOut(amountIn, path);
        uint256[] memory swapAmounts = router.swapExactTokensForTokens(
            amountIn, quotedAmounts[quotedAmounts.length - 1], path, msg.sender, deadline
        );

        spentAmount = swapAmounts[0];
        receivedAmount = swapAmounts[swapAmounts.length - 1];
    }

    function _deployToken(string memory name, string memory symbol, uint256 totalSupply)
        internal
        returns (address token)
    {
        token = deployCode("out/UniswapV2ERC20Test.sol/UniswapV2ERC20Test.json", abi.encode(name, symbol, totalSupply));
    }

    function _approveRouter(address token, address router) internal {
        IERC20Like(token).approve(router, type(uint256).max);
    }

    function _createPairIfMissing(IUniswapV2FactoryLike factory, address tokenA, address tokenB)
        internal
        returns (address pair)
    {
        pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) {
            pair = factory.createPair(tokenA, tokenB);
        }
    }
}
