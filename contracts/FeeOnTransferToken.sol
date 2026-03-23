// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title FeeOnTransferToken (Wrapped Elastic Dollar)
/// @author Elastic Protocol
/// @notice Deflationary utility token used across DeFi ecosystems
/// @dev ERC20-compliant token with a transfer fee mechanism for protocol sustainability
contract FeeOnTransferToken {
    string public constant name = "Wrapped Elastic Dollar";
    string public constant symbol = "wELD";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    address public feeCollector;
    address public admin;

    /// @notice Transfer fee in basis points (100 = 1%)
    uint256 public feeBps = 100;
    uint256 public constant MAX_FEE_BPS = 500; // 5% max
    uint256 public constant BPS_DENOMINATOR = 10000;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public feeExempt;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeExemptionSet(address indexed account, bool exempt);

    constructor(uint256 initialSupply, address _feeCollector) {
        admin = msg.sender;
        feeCollector = _feeCollector;
        feeExempt[msg.sender] = true;
        feeExempt[_feeCollector] = true;
        totalSupply = initialSupply;
        balanceOf[msg.sender] = initialSupply;
        emit Transfer(address(0), msg.sender, initialSupply);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "wELD: allowance exceeded");
            allowance[from][msg.sender] = allowed - amount;
        }
        return _transfer(from, to, amount);
    }

    function setFee(uint256 newFeeBps) external {
        require(msg.sender == admin, "wELD: not admin");
        require(newFeeBps <= MAX_FEE_BPS, "wELD: fee too high");
        emit FeeUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    function setFeeExempt(address account, bool exempt) external {
        require(msg.sender == admin, "wELD: not admin");
        feeExempt[account] = exempt;
        emit FeeExemptionSet(account, exempt);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(from != address(0) && to != address(0), "wELD: zero address");
        require(balanceOf[from] >= amount, "wELD: insufficient balance");

        uint256 fee = 0;
        if (!feeExempt[from] && !feeExempt[to]) {
            fee = (amount * feeBps) / BPS_DENOMINATOR;
        }
        uint256 netAmount = amount - fee;

        balanceOf[from] -= amount;
        balanceOf[to] += netAmount;

        if (fee > 0) {
            balanceOf[feeCollector] += fee;
            emit Transfer(from, feeCollector, fee);
        }
        emit Transfer(from, to, netAmount);
        return true;
    }
}
