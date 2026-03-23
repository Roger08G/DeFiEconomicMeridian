// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IInterestRateModel {
    function getBorrowRate(uint256 cash, uint256 borrows) external view returns (uint256);
    function getSupplyRate(uint256 cash, uint256 borrows) external view returns (uint256);
}

interface IMeridianOracle {
    function consult(address token) external view returns (uint256);
}

/// @title MeridianLendingPool
/// @author Meridian Finance Team
/// @notice Permissionless multi-collateral lending and borrowing protocol
/// @dev Supports any ERC20 token as collateral. Interest accrues per-block
///      using a configurable jump-rate model. Liquidation is incentivized
///      via a bonus mechanism for underwater positions.
contract MeridianLendingPool {
    // ═══════════════════════════════════════════════════════════════════════
    // DATA STRUCTURES
    // ═══════════════════════════════════════════════════════════════════════

    struct Market {
        uint256 totalDeposits;
        uint256 totalBorrows;
        uint256 borrowIndex;
        uint256 lastAccrualBlock;
        uint256 collateralFactor; // Scaled to 1e18 (0.75e18 = 75%)
        bool isListed;
    }

    struct AccountSnapshot {
        uint256 depositBalance;
        uint256 borrowBalance;
        uint256 borrowIndex;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════

    address public admin;
    IInterestRateModel public interestRateModel;
    IMeridianOracle public oracle;

    /// @notice Liquidation incentive: 1100 = 10% bonus to liquidator
    uint256 public constant LIQUIDATION_BONUS = 1100;
    /// @notice Maximum fraction of debt repayable per liquidation (50%)
    uint256 public constant CLOSE_FACTOR = 500;
    uint256 public constant FACTOR_SCALE = 1000;
    uint256 public constant PRECISION = 1e18;

    mapping(address => Market) public markets;
    mapping(address => mapping(address => AccountSnapshot)) public accountSnapshots;
    address[] public marketList;

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event MarketListed(address indexed token, uint256 collateralFactor);
    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event Borrow(address indexed user, address indexed token, uint256 amount);
    event Repay(address indexed user, address indexed token, uint256 amount);
    event Liquidation(
        address indexed liquidator,
        address indexed borrower,
        address debtToken,
        address collateralToken,
        uint256 repayAmount,
        uint256 seizeAmount
    );

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error MarketNotListed();
    error InsufficientCollateral();
    error ExceedsCloseFactor();
    error AccountHealthy();
    error Unauthorized();
    error InsufficientDeposit();
    error CollateralFactorTooHigh();

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    constructor(address _interestRateModel, address _oracle) {
        admin = msg.sender;
        interestRateModel = IInterestRateModel(_interestRateModel);
        oracle = IMeridianOracle(_oracle);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice List a new token market for deposits and borrowing
    function listMarket(address token, uint256 collateralFactor) external onlyAdmin {
        require(!markets[token].isListed, "Already listed");
        if (collateralFactor > PRECISION) revert CollateralFactorTooHigh();

        markets[token] = Market({
            totalDeposits: 0,
            totalBorrows: 0,
            borrowIndex: PRECISION,
            lastAccrualBlock: block.number,
            collateralFactor: collateralFactor,
            isListed: true
        });
        marketList.push(token);

        emit MarketListed(token, collateralFactor);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CORE — DEPOSIT / WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deposit tokens as collateral
    /// @param token Address of the ERC20 token to deposit
    /// @param amount Amount of tokens to deposit
    function deposit(address token, uint256 amount) external {
        Market storage market = markets[token];
        if (!market.isListed) revert MarketNotListed();

        accrueInterest(token);

        IERC20(token).transferFrom(msg.sender, address(this), amount);

        accountSnapshots[msg.sender][token].depositBalance += amount;
        market.totalDeposits += amount;

        emit Deposit(msg.sender, token, amount);
    }

    /// @notice Withdraw deposited collateral
    function withdraw(address token, uint256 amount) external {
        Market storage market = markets[token];
        if (!market.isListed) revert MarketNotListed();

        accrueInterest(token);

        AccountSnapshot storage snap = accountSnapshots[msg.sender][token];
        if (snap.depositBalance < amount) revert InsufficientDeposit();

        snap.depositBalance -= amount;
        market.totalDeposits -= amount;

        // Ensure account remains healthy after withdrawal
        require(_isHealthy(msg.sender), "Unhealthy after withdrawal");

        IERC20(token).transfer(msg.sender, amount);
        emit Withdraw(msg.sender, token, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CORE — BORROW / REPAY
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Borrow tokens against deposited collateral
    function borrow(address token, uint256 amount) external {
        Market storage market = markets[token];
        if (!market.isListed) revert MarketNotListed();

        accrueInterest(token);

        AccountSnapshot storage snap = accountSnapshots[msg.sender][token];
        snap.borrowBalance += amount;
        snap.borrowIndex = market.borrowIndex;
        market.totalBorrows += amount;

        if (!_isHealthy(msg.sender)) revert InsufficientCollateral();

        IERC20(token).transfer(msg.sender, amount);
        emit Borrow(msg.sender, token, amount);
    }

    /// @notice Repay outstanding borrow
    function repay(address token, uint256 amount) external {
        Market storage market = markets[token];
        if (!market.isListed) revert MarketNotListed();

        accrueInterest(token);

        AccountSnapshot storage snap = accountSnapshots[msg.sender][token];
        uint256 actualRepay = amount > snap.borrowBalance ? snap.borrowBalance : amount;

        IERC20(token).transferFrom(msg.sender, address(this), actualRepay);

        snap.borrowBalance -= actualRepay;
        market.totalBorrows -= actualRepay;

        emit Repay(msg.sender, token, actualRepay);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LIQUIDATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Liquidate an unhealthy (underwater) borrower position
    /// @param borrower Address of the account to liquidate
    /// @param debtToken Token in which the borrower has outstanding debt
    /// @param collateralToken Collateral token to seize as compensation
    /// @param repayAmount Amount of debt to repay on behalf of the borrower
    function liquidate(
        address borrower,
        address debtToken,
        address collateralToken,
        uint256 repayAmount
    ) external {
        accrueInterest(debtToken);
        accrueInterest(collateralToken);

        // Verify the borrower's position is actually underwater
        if (_isHealthy(borrower)) revert AccountHealthy();

        // Enforce close factor — can only liquidate up to 50% of debt per tx
        AccountSnapshot storage debtSnap = accountSnapshots[borrower][debtToken];
        uint256 maxRepay = (debtSnap.borrowBalance * CLOSE_FACTOR) / FACTOR_SCALE;
        if (repayAmount > maxRepay) revert ExceedsCloseFactor();

        // Repay the debt on behalf of the borrower
        IERC20(debtToken).transferFrom(msg.sender, address(this), repayAmount);
        debtSnap.borrowBalance -= repayAmount;
        markets[debtToken].totalBorrows -= repayAmount;

        // Calculate collateral to seize: repay value * bonus / collateral price
        uint256 debtValueUSD = (repayAmount * oracle.consult(debtToken)) / PRECISION;
        uint256 collateralPrice = oracle.consult(collateralToken);
        uint256 seizeAmount = (debtValueUSD * LIQUIDATION_BONUS * PRECISION)
            / (collateralPrice * FACTOR_SCALE);

        // Seize collateral from borrower
        AccountSnapshot storage collSnap = accountSnapshots[borrower][collateralToken];
        require(collSnap.depositBalance >= seizeAmount, "Insufficient collateral to seize");
        collSnap.depositBalance -= seizeAmount;
        markets[collateralToken].totalDeposits -= seizeAmount;

        // Transfer seized collateral to the liquidator
        IERC20(collateralToken).transfer(msg.sender, seizeAmount);

        emit Liquidation(
            msg.sender, borrower, debtToken, collateralToken, repayAmount, seizeAmount
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INTEREST ACCRUAL
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Accrue interest for a market based on blocks elapsed
    /// @dev Uses current cash balance to compute utilization rate
    function accrueInterest(address token) public {
        Market storage market = markets[token];
        if (block.number == market.lastAccrualBlock) return;

        uint256 blockDelta = block.number - market.lastAccrualBlock;
        uint256 cash = IERC20(token).balanceOf(address(this));

        if (market.totalBorrows > 0) {
            uint256 borrowRate = interestRateModel.getBorrowRate(cash, market.totalBorrows);
            uint256 interestAccumulated = (market.totalBorrows * borrowRate * blockDelta) / PRECISION;
            market.totalBorrows += interestAccumulated;
            market.borrowIndex += (interestAccumulated * PRECISION) / market.totalBorrows;
        }

        market.lastAccrualBlock = block.number;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Check if an account's collateral covers its borrows
    function _isHealthy(address user) internal view returns (bool) {
        uint256 totalCollateralUSD = 0;
        uint256 totalBorrowUSD = 0;

        for (uint256 i = 0; i < marketList.length; i++) {
            address token = marketList[i];
            Market storage market = markets[token];
            AccountSnapshot storage snap = accountSnapshots[user][token];

            uint256 price = oracle.consult(token);

            if (snap.depositBalance > 0) {
                totalCollateralUSD +=
                    (snap.depositBalance * price * market.collateralFactor) / (PRECISION * PRECISION);
            }
            if (snap.borrowBalance > 0) {
                totalBorrowUSD += (snap.borrowBalance * price) / PRECISION;
            }
        }

        return totalCollateralUSD >= totalBorrowUSD;
    }

    /// @notice Get the health factor for a user's aggregate position
    /// @return healthFactor 1e18 = exactly at liquidation threshold
    function getHealthFactor(address user) external view returns (uint256 healthFactor) {
        uint256 totalCollateralUSD = 0;
        uint256 totalBorrowUSD = 0;

        for (uint256 i = 0; i < marketList.length; i++) {
            address token = marketList[i];
            Market storage market = markets[token];
            AccountSnapshot storage snap = accountSnapshots[user][token];

            uint256 price = oracle.consult(token);

            if (snap.depositBalance > 0) {
                totalCollateralUSD +=
                    (snap.depositBalance * price * market.collateralFactor) / (PRECISION * PRECISION);
            }
            if (snap.borrowBalance > 0) {
                totalBorrowUSD += (snap.borrowBalance * price) / PRECISION;
            }
        }

        if (totalBorrowUSD == 0) return type(uint256).max;
        healthFactor = (totalCollateralUSD * PRECISION) / totalBorrowUSD;
    }

    function getMarketCount() external view returns (uint256) {
        return marketList.length;
    }

    function getAccountDeposit(address user, address token) external view returns (uint256) {
        return accountSnapshots[user][token].depositBalance;
    }

    function getAccountBorrow(address user, address token) external view returns (uint256) {
        return accountSnapshots[user][token].borrowBalance;
    }
}
