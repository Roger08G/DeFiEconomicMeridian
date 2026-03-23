// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title InterestRateModel
/// @author Meridian Finance Team
/// @notice Jump-rate interest model for Meridian lending markets
/// @dev Rates increase linearly until the kink utilization, then jump sharply.
///      Based on the Compound JumpRateModel design.
contract InterestRateModel {
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BLOCKS_PER_YEAR = 2_628_000; // ~12 sec block time

    /// @notice Base borrow rate per block
    uint256 public immutable baseRatePerBlock;

    /// @notice Borrow rate slope below kink (per block)
    uint256 public immutable multiplierPerBlock;

    /// @notice Borrow rate slope above kink (per block)
    uint256 public immutable jumpMultiplierPerBlock;

    /// @notice Utilization rate at which the jump multiplier activates
    uint256 public immutable kink;

    /// @param _baseRateAPR Base annual rate (e.g., 2e16 = 2%)
    /// @param _multiplierAPR Normal multiplier APR (e.g., 20e16 = 20%)
    /// @param _jumpMultiplierAPR Jump multiplier APR (e.g., 200e16 = 200%)
    /// @param _kink Kink utilization point (e.g., 80e16 = 80%)
    constructor(
        uint256 _baseRateAPR,
        uint256 _multiplierAPR,
        uint256 _jumpMultiplierAPR,
        uint256 _kink
    ) {
        baseRatePerBlock = _baseRateAPR / BLOCKS_PER_YEAR;
        multiplierPerBlock = _multiplierAPR / BLOCKS_PER_YEAR;
        jumpMultiplierPerBlock = _jumpMultiplierAPR / BLOCKS_PER_YEAR;
        kink = _kink;
    }

    /// @notice Calculate utilization rate: borrows / (cash + borrows)
    function utilizationRate(uint256 cash, uint256 borrows) public pure returns (uint256) {
        if (borrows == 0) return 0;
        return (borrows * PRECISION) / (cash + borrows);
    }

    /// @notice Get borrow rate per block for the given market state
    /// @param cash Available liquidity in the pool
    /// @param borrows Outstanding borrows
    /// @return rate Borrow rate per block (scaled to 1e18)
    function getBorrowRate(uint256 cash, uint256 borrows) external view returns (uint256 rate) {
        uint256 util = utilizationRate(cash, borrows);

        if (util <= kink) {
            rate = baseRatePerBlock + (util * multiplierPerBlock) / PRECISION;
        } else {
            uint256 normalRate = baseRatePerBlock + (kink * multiplierPerBlock) / PRECISION;
            uint256 excessUtil = util - kink;
            rate = normalRate + (excessUtil * jumpMultiplierPerBlock) / PRECISION;
        }
    }

    /// @notice Get supply rate per block
    /// @dev supplyRate = borrowRate * utilization * (1 - reserveFactor)
    function getSupplyRate(uint256 cash, uint256 borrows) external view returns (uint256) {
        uint256 util = utilizationRate(cash, borrows);
        uint256 borrowRate = this.getBorrowRate(cash, borrows);
        return (util * borrowRate) / PRECISION;
    }
}
