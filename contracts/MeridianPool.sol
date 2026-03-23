// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title MeridianPool
/// @author Meridian Finance Team
/// @notice Constant-product AMM pool for token pair trading
/// @dev Implements the x * y = k invariant with a 0.3% swap fee.
///      Liquidity providers receive proportional LP shares.
contract MeridianPool {
    address public immutable token0;
    address public immutable token1;

    uint256 public reserve0;
    uint256 public reserve1;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    uint256 public constant SWAP_FEE_BPS = 30; // 0.3%
    uint256 public constant BPS = 10000;
    uint256 private constant MINIMUM_LIQUIDITY = 1000;

    uint256 private _unlocked = 1;

    event Mint(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Burn(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Swap(
        address indexed sender,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut
    );
    event Sync(uint256 reserve0, uint256 reserve1);

    error Locked();
    error InsufficientLiquidity();
    error InsufficientInput();
    error InvalidToken();
    error KDecreased();

    modifier lock() {
        if (_unlocked != 1) revert Locked();
        _unlocked = 0;
        _;
        _unlocked = 1;
    }

    constructor(address _token0, address _token1) {
        require(_token0 != address(0) && _token1 != address(0), "Zero address");
        require(_token0 != _token1, "Identical tokens");
        token0 = _token0;
        token1 = _token1;
    }

    function getReserves() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }

    /// @notice Provide liquidity to the pool and receive LP tokens
    /// @param amount0 Amount of token0 to deposit
    /// @param amount1 Amount of token1 to deposit
    /// @return liquidity Amount of LP tokens minted
    function addLiquidity(
        uint256 amount0,
        uint256 amount1
    ) external lock returns (uint256 liquidity) {
        require(amount0 > 0 && amount1 > 0, "Zero amounts");

        IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        IERC20(token1).transferFrom(msg.sender, address(this), amount1);

        if (totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            balanceOf[address(0)] += MINIMUM_LIQUIDITY;
            totalSupply += MINIMUM_LIQUIDITY;
        } else {
            liquidity =
                _min((amount0 * totalSupply) / reserve0, (amount1 * totalSupply) / reserve1);
        }

        require(liquidity > 0, "Insufficient liquidity minted");
        balanceOf[msg.sender] += liquidity;
        totalSupply += liquidity;

        reserve0 += amount0;
        reserve1 += amount1;

        emit Mint(msg.sender, amount0, amount1, liquidity);
        emit Sync(reserve0, reserve1);
    }

    /// @notice Remove liquidity and receive underlying tokens
    /// @param liquidity Amount of LP tokens to burn
    function removeLiquidity(
        uint256 liquidity
    ) external lock returns (uint256 amount0, uint256 amount1) {
        require(balanceOf[msg.sender] >= liquidity, "Insufficient LP balance");

        amount0 = (liquidity * reserve0) / totalSupply;
        amount1 = (liquidity * reserve1) / totalSupply;
        require(amount0 > 0 && amount1 > 0, "Insufficient liquidity burned");

        balanceOf[msg.sender] -= liquidity;
        totalSupply -= liquidity;

        reserve0 -= amount0;
        reserve1 -= amount1;

        IERC20(token0).transfer(msg.sender, amount0);
        IERC20(token1).transfer(msg.sender, amount1);

        emit Burn(msg.sender, amount0, amount1, liquidity);
        emit Sync(reserve0, reserve1);
    }

    /// @notice Swap one token for the other using constant-product pricing
    /// @param tokenIn Address of the token being sold
    /// @param amountIn Amount of tokenIn to sell
    /// @return amountOut Amount of the other token received
    function swap(address tokenIn, uint256 amountIn) external lock returns (uint256 amountOut) {
        if (tokenIn != token0 && tokenIn != token1) revert InvalidToken();
        if (amountIn == 0) revert InsufficientInput();

        bool isToken0 = tokenIn == token0;
        (uint256 resIn, uint256 resOut) = isToken0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);

        // Transfer input tokens
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Calculate output with fee
        uint256 amountInWithFee = amountIn * (BPS - SWAP_FEE_BPS) / BPS;
        amountOut = (resOut * amountInWithFee) / (resIn + amountInWithFee);

        require(amountOut > 0 && amountOut < resOut, "Insufficient output");

        // Transfer output tokens
        address tokenOut = isToken0 ? token1 : token0;
        IERC20(tokenOut).transfer(msg.sender, amountOut);

        // Update reserves
        if (isToken0) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            reserve1 += amountIn;
            reserve0 -= amountOut;
        }

        // Verify constant product invariant held
        if (reserve0 * reserve1 < resIn * resOut) revert KDecreased();

        emit Swap(msg.sender, tokenIn, amountIn, amountOut);
        emit Sync(reserve0, reserve1);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
