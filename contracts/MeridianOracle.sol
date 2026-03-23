// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMeridianPool {
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @title MeridianOracle
/// @author Meridian Finance Team
/// @notice Time-Weighted Average Price (TWAP) oracle for on-chain price feeds
/// @dev Tracks cumulative prices from AMM pools with configurable observation windows.
///      Designed for use by lending pools, vaults, and liquidation engines.
contract MeridianOracle {
    struct Observation {
        uint256 timestamp;
        uint256 priceCumulative0;
        uint256 priceCumulative1;
    }

    address public immutable pool;
    uint256 public constant PRECISION = 1e18;

    /// @notice TWAP observation window in seconds
    uint256 public immutable windowSize;

    Observation[] public observations;

    uint256 public priceCumulative0;
    uint256 public priceCumulative1;
    uint256 public lastUpdateTimestamp;

    event PriceUpdated(uint256 price0, uint256 price1, uint256 timestamp);

    /// @param _pool Address of the AMM pool to observe
    /// @param _windowSize TWAP window in seconds
    constructor(address _pool, uint256 _windowSize) {
        require(_pool != address(0), "Invalid pool");
        require(_windowSize > 0, "Invalid window");
        pool = _pool;
        windowSize = _windowSize;
        lastUpdateTimestamp = block.timestamp;

        observations.push(
            Observation({timestamp: block.timestamp, priceCumulative0: 0, priceCumulative1: 0})
        );
    }

    /// @notice Record a new price observation from the AMM pool
    /// @dev Should be called periodically (at least once per window) for accurate TWAP
    function update() external {
        uint256 elapsed = block.timestamp - lastUpdateTimestamp;
        if (elapsed == 0) return;

        (uint256 r0, uint256 r1) = IMeridianPool(pool).getReserves();
        require(r0 > 0 && r1 > 0, "Empty reserves");

        // Accumulate price * time
        priceCumulative0 += (r1 * PRECISION / r0) * elapsed;
        priceCumulative1 += (r0 * PRECISION / r1) * elapsed;
        lastUpdateTimestamp = block.timestamp;

        observations.push(
            Observation({
                timestamp: block.timestamp,
                priceCumulative0: priceCumulative0,
                priceCumulative1: priceCumulative1
            })
        );

        emit PriceUpdated(r1 * PRECISION / r0, r0 * PRECISION / r1, block.timestamp);
    }

    /// @notice Returns the TWAP price of a token over the configured window
    /// @param tokenIn Address of the token to price
    /// @return price TWAP price scaled to 1e18
    function consult(address tokenIn) external view returns (uint256 price) {
        require(observations.length >= 2, "Insufficient observations");

        Observation memory latest = observations[observations.length - 1];
        uint256 targetTimestamp = latest.timestamp > windowSize
            ? latest.timestamp - windowSize
            : 0;
        Observation memory older = _findObservation(targetTimestamp);

        uint256 timeElapsed = latest.timestamp - older.timestamp;
        require(timeElapsed > 0, "Zero elapsed time");

        address token0Addr = IMeridianPool(pool).token0();

        if (tokenIn == token0Addr) {
            price = (latest.priceCumulative0 - older.priceCumulative0) / timeElapsed;
        } else {
            price = (latest.priceCumulative1 - older.priceCumulative1) / timeElapsed;
        }
    }

    /// @notice Returns the instantaneous spot price (not TWAP)
    function getSpotPrice(address tokenIn) external view returns (uint256) {
        (uint256 r0, uint256 r1) = IMeridianPool(pool).getReserves();
        address token0Addr = IMeridianPool(pool).token0();
        if (tokenIn == token0Addr) {
            return r1 * PRECISION / r0;
        } else {
            return r0 * PRECISION / r1;
        }
    }

    function observationCount() external view returns (uint256) {
        return observations.length;
    }

    /// @dev Binary search for the observation closest to the target timestamp
    function _findObservation(uint256 targetTime) internal view returns (Observation memory) {
        uint256 lo = 0;
        uint256 hi = observations.length - 1;

        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (observations[mid].timestamp <= targetTime) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return observations[lo];
    }
}
