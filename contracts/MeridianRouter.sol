// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IMeridianPool {
    function swap(address tokenIn, uint256 amountIn) external returns (uint256);
    function addLiquidity(uint256 amount0, uint256 amount1) external returns (uint256);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IMeridianVault {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

interface IMeridianLendingPool {
    function deposit(address token, uint256 amount) external;
    function borrow(address token, uint256 amount) external;
    function repay(address token, uint256 amount) external;
}

/// @title MeridianRouter
/// @author Meridian Finance Team
/// @notice Convenience router for multi-step Meridian operations
/// @dev Aggregates swap → deposit → borrow workflows into single transactions.
///      Users must approve the router for relevant tokens before calling.
contract MeridianRouter {
    address public immutable pool;
    address public immutable vault;
    address public immutable lendingPool;

    error InsufficientOutput();
    error ZeroAmount();

    constructor(address _pool, address _vault, address _lendingPool) {
        require(_pool != address(0) && _vault != address(0) && _lendingPool != address(0));
        pool = _pool;
        vault = _vault;
        lendingPool = _lendingPool;
    }

    /// @notice Swap tokens with slippage protection
    /// @param tokenIn Input token address
    /// @param amountIn Amount to swap
    /// @param minAmountOut Minimum acceptable output amount
    function swapExact(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(pool, amountIn);

        amountOut = IMeridianPool(pool).swap(tokenIn, amountIn);
        if (amountOut < minAmountOut) revert InsufficientOutput();

        // Forward output tokens to user
        address tokenOut = tokenIn == IMeridianPool(pool).token0()
            ? IMeridianPool(pool).token1()
            : IMeridianPool(pool).token0();

        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }

    /// @notice Swap tokens and deposit output directly into the vault
    function swapAndDeposit(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 shares) {
        if (amountIn == 0) revert ZeroAmount();

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(pool, amountIn);

        uint256 amountOut = IMeridianPool(pool).swap(tokenIn, amountIn);
        if (amountOut < minAmountOut) revert InsufficientOutput();

        address tokenOut = tokenIn == IMeridianPool(pool).token0()
            ? IMeridianPool(pool).token1()
            : IMeridianPool(pool).token0();

        IERC20(tokenOut).approve(vault, amountOut);
        shares = IMeridianVault(vault).deposit(amountOut, msg.sender);
    }

    /// @notice Add liquidity to the AMM pool through the router
    function addLiquidity(
        uint256 amount0,
        uint256 amount1,
        uint256 minLiquidity
    ) external returns (uint256 liquidity) {
        address token0 = IMeridianPool(pool).token0();
        address token1 = IMeridianPool(pool).token1();

        IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        IERC20(token1).transferFrom(msg.sender, address(this), amount1);

        IERC20(token0).approve(pool, amount0);
        IERC20(token1).approve(pool, amount1);

        liquidity = IMeridianPool(pool).addLiquidity(amount0, amount1);
        require(liquidity >= minLiquidity, "Insufficient liquidity");
    }

    /// @notice Deposit collateral to lending pool and immediately borrow
    function depositAndBorrow(
        address collateralToken,
        uint256 collateralAmount,
        address borrowToken,
        uint256 borrowAmount
    ) external {
        if (collateralAmount == 0) revert ZeroAmount();

        IERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
        IERC20(collateralToken).approve(lendingPool, collateralAmount);

        IMeridianLendingPool(lendingPool).deposit(collateralToken, collateralAmount);
        IMeridianLendingPool(lendingPool).borrow(borrowToken, borrowAmount);

        IERC20(borrowToken).transfer(msg.sender, borrowAmount);
    }
}
