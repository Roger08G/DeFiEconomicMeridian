// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title LiquidityGauge
/// @author Meridian Finance Team
/// @notice Liquidity mining gauge for AMM LP token holders
/// @dev Distributes MERID rewards proportionally to staked LP tokens.
///      Supports a ve-token boost mechanism (up to 2.5x) for governance participants.
contract LiquidityGauge {
    IERC20 public immutable lpToken;
    IERC20 public immutable rewardToken;
    address public admin;

    uint256 public totalStaked;
    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTimestamp;
    uint256 public emissionRate; // MERID tokens per second

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_BOOST = 25e17; // 2.5x

    mapping(address => uint256) public staked;
    mapping(address => uint256) public userRewardPerToken;
    mapping(address => uint256) public pendingRewards;
    mapping(address => uint256) public boostMultiplier; // 1e18 = 1x

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event BoostUpdated(address indexed user, uint256 multiplier);
    event EmissionRateUpdated(uint256 oldRate, uint256 newRate);

    error ZeroDeposit();
    error InsufficientStake();
    error Unauthorized();
    error InvalidBoost();

    constructor(address _lpToken, address _rewardToken, uint256 _emissionRate) {
        require(_lpToken != address(0) && _rewardToken != address(0), "Zero address");
        lpToken = IERC20(_lpToken);
        rewardToken = IERC20(_rewardToken);
        emissionRate = _emissionRate;
        admin = msg.sender;
        lastUpdateTimestamp = block.timestamp;
    }

    modifier updateRewards(address account) {
        rewardPerTokenStored = currentRewardPerToken();
        lastUpdateTimestamp = block.timestamp;
        if (account != address(0)) {
            pendingRewards[account] = pendingReward(account);
            userRewardPerToken[account] = rewardPerTokenStored;
        }
        _;
    }

    function currentRewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        uint256 elapsed = block.timestamp - lastUpdateTimestamp;
        return rewardPerTokenStored + (elapsed * emissionRate * PRECISION / totalStaked);
    }

    function pendingReward(address account) public view returns (uint256) {
        uint256 boost = boostMultiplier[account];
        if (boost == 0) boost = PRECISION; // Default 1x

        uint256 baseReward = (
            staked[account] * (currentRewardPerToken() - userRewardPerToken[account]) / PRECISION
        ) + pendingRewards[account];

        return (baseReward * boost) / PRECISION;
    }

    /// @notice Stake LP tokens to earn MERID rewards
    function deposit(uint256 amount) external updateRewards(msg.sender) {
        if (amount == 0) revert ZeroDeposit();
        lpToken.transferFrom(msg.sender, address(this), amount);
        staked[msg.sender] += amount;
        totalStaked += amount;
        emit Deposited(msg.sender, amount);
    }

    /// @notice Unstake LP tokens
    function withdraw(uint256 amount) external updateRewards(msg.sender) {
        if (staked[msg.sender] < amount) revert InsufficientStake();
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        lpToken.transfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claim accumulated MERID rewards
    function claim() external updateRewards(msg.sender) {
        uint256 reward = pendingRewards[msg.sender];
        if (reward > 0) {
            pendingRewards[msg.sender] = 0;
            rewardToken.transfer(msg.sender, reward);
            emit Claimed(msg.sender, reward);
        }
    }

    /// @notice Set ve-token boost multiplier for a user (admin only)
    /// @param user Address to boost
    /// @param multiplier Boost factor (1e18 = 1x, 2.5e18 = 2.5x max)
    function setBoost(address user, uint256 multiplier) external updateRewards(user) {
        if (msg.sender != admin) revert Unauthorized();
        if (multiplier < PRECISION || multiplier > MAX_BOOST) revert InvalidBoost();
        boostMultiplier[user] = multiplier;
        emit BoostUpdated(user, multiplier);
    }

    /// @notice Update the MERID emission rate (admin only)
    function setEmissionRate(uint256 newRate) external updateRewards(address(0)) {
        if (msg.sender != admin) revert Unauthorized();
        emit EmissionRateUpdated(emissionRate, newRate);
        emissionRate = newRate;
    }
}
