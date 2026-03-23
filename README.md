# Meridian Finance — Security Audit Contest

> **Prize Pool**: $150,000 USDC  
> **Dates**: March 10 – March 24, 2026  
> **nSLOC**: ~1,100  
> **Complexity**: Medium-High  
> **Chain**: Ethereum Mainnet (planned)

---

## 1. Protocol Overview

**Meridian Finance** is a composable DeFi protocol that integrates an AMM, a lending pool, a yield vault, staking, and on-chain oracle infrastructure into a single cohesive ecosystem.

The protocol is designed so that:
- Users **swap** tokens through a constant-product AMM (`MeridianPool`)
- AMM prices are **observed** by a TWAP oracle (`MeridianOracle`) used across the system
- Users **lend** and **borrow** against multi-collateral positions (`MeridianLendingPool`)
- Idle capital earns yield in an **ERC4626 vault** (`MeridianVault`)
- Governance participants **stake** MERID tokens for protocol revenue share (`MeridianStaking`)
- LP providers earn **liquidity mining** rewards through gauges (`LiquidityGauge`)
- A convenience **router** aggregates common multi-step workflows (`MeridianRouter`)

The protocol accepts any ERC20 as collateral, including third-party tokens like `wELD` (Wrapped Elastic Dollar), a deflationary token with a transfer fee mechanism.

---

## 2. Architecture

```
                    ┌─────────────────────┐
                    │   MeridianRouter    │
                    │   (aggregation)     │
                    └───┬───────┬─────┬───┘
                        │       │     │
           ┌────────────▼──┐ ┌──▼─────▼──────────────┐
           │ MeridianPool  │ │ MeridianLendingPool    │
           │   (AMM)       │ │   (lend/borrow)        │
           └──────┬────────┘ └─────┬───────┬──────────┘
                  │                │       │
           ┌──────▼────────┐ ┌────▼───┐ ┌─▼──────────────┐
           │ MeridianOracle│ │Interest│ │  MeridianVault  │
           │   (TWAP)      │ │RateModel│ │  (ERC4626)     │
           └───────────────┘ └────────┘ └─────────────────┘
                                    
    ┌──────────────┐  ┌─────────────────┐  ┌─────────────────┐
    │MeridianToken │  │FeeOnTransferToken│  │ LiquidityGauge  │
    │   (MERID)    │  │   (wELD)        │  │  (LP mining)    │
    └──────────────┘  └─────────────────┘  └─────────────────┘
                                    
                      ┌─────────────────┐
                      │ MeridianStaking │
                      │  (MERID staking)│
                      └─────────────────┘
```

---

## 3. Contracts

| Contract | File | LOC | Description |
|----------|------|-----|-------------|
| `MeridianToken` | `MeridianToken.sol` | 90 | ERC20 governance token with owner-only minting |
| `FeeOnTransferToken` | `FeeOnTransferToken.sol` | 95 | Deflationary ERC20 (1% transfer fee, configurable) |
| `MeridianOracle` | `MeridianOracle.sol` | 120 | TWAP oracle observing AMM pool price cumulatives |
| `MeridianPool` | `MeridianPool.sol` | 160 | Constant-product AMM (x·y=k) with 0.3% swap fee |
| `MeridianVault` | `MeridianVault.sol` | 160 | ERC4626 yield vault with proportional share accounting |
| `MeridianLendingPool` | `MeridianLendingPool.sol` | 260 | Multi-collateral lending pool with liquidation engine |
| `InterestRateModel` | `InterestRateModel.sol` | 75 | Jump-rate interest model (Compound-style) |
| `MeridianStaking` | `MeridianStaking.sol` | 125 | Synthetix-style staking with continuous reward distribution |
| `MeridianRouter` | `MeridianRouter.sol` | 130 | Multi-step operation aggregator with slippage protection |
| `LiquidityGauge` | `LiquidityGauge.sol` | 130 | LP incentive gauge with ve-token boost mechanism |

**Total nSLOC**: ~1,145

---

## 4. Scope

All 10 contracts are in scope. The focus of this audit is **economic and financial vulnerabilities** — bugs that lead to:
- Direct fund loss
- Value extraction (MEV, arbitrage)
- Price manipulation
- Accounting divergence leading to insolvency

Out of scope: Gas optimization, code style, informational findings.

---

## 5. Deployment Configuration

For context, the planned mainnet deployment uses these parameters:

| Parameter | Value |
|-----------|-------|
| TWAP Oracle Window | `300` seconds (5 minutes) |
| Lending Collateral Factor | `0.75e18` (75%) |
| Liquidation Bonus | `1100` (10%) |
| Close Factor | `500` (50%) |
| Interest Rate: Base APR | `2%` |
| Interest Rate: Multiplier APR | `20%` |
| Interest Rate: Jump Multiplier APR | `200%` |
| Interest Rate: Kink | `80%` utilization |
| Listed Collateral Tokens | MERID, wELD, WETH |

---

## 6. Known Vulnerabilities (Post-Audit Disclosure)

The following 6 vulnerabilities were confirmed during the audit. They are disclosed here for educational purposes.

---

### V-01: TWAP Oracle Short Window Enables Price Manipulation

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Impact** | Price Manipulation → Undercollateralized Borrows |
| **Likelihood** | High (any well-capitalized attacker) |
| **File** | `MeridianOracle.sol` |
| **Location** | Constructor parameter `_windowSize` (deployed with `300` = 5 minutes) |
| **Difficulty** | Medium |

**Description**: The oracle is deployed with a TWAP window of only 5 minutes (300 seconds). This is insufficient for production use — an attacker with moderate capital can sustain price manipulation across a few blocks to skew the TWAP significantly.

**Exploit Path**:  
1. Attacker acquires large token position (or uses flash loan across blocks)
2. Executes large swaps in `MeridianPool` across ~25 blocks (5 minutes)
3. Calls `oracle.update()` each block to record skewed price observations
4. The manipulated TWAP feeds into `MeridianLendingPool.oracle.consult()`
5. Attacker borrows against inflated collateral, then lets the TWAP normalize
6. Result: undercollateralized borrow position → protocol loss

**Recommendation**: Use a minimum TWAP window of 30 minutes (1800 seconds), and add a deviation check comparing TWAP vs. spot price.

---

### V-02: Missing Slippage Protection in AMM Swap

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Impact** | Value Extraction (Sandwich Attack) |
| **Likelihood** | Very High (automated MEV bots) |
| **File** | `MeridianPool.sol` |
| **Location** | `swap()` function — no `minAmountOut` parameter |
| **Difficulty** | Easy |

**Description**: The `MeridianPool.swap()` function accepts `tokenIn` and `amountIn` but provides no mechanism for the caller to specify a minimum acceptable output. This is a textbook missing slippage protection that exposes every direct swap to unlimited sandwich attacks.

**Exploit Path**:  
1. Victim submits `swap(tokenA, 100e18)` to the mempool
2. MEV bot front-runs: swaps a large amount to move the price against the victim
3. Victim's transaction executes at a much worse rate (no minimum output check)
4. MEV bot back-runs: swaps back to take profit from the price impact
5. Victim receives significantly fewer tokens than expected

**Note**: The `MeridianRouter.swapExact()` does include `minAmountOut`, but users interacting directly with the pool have no protection. This is problematic because the pool is a public contract.

**Recommendation**: Add a `minAmountOut` parameter to `swap()` and revert if `amountOut < minAmountOut`.

---

### V-03: First Depositor Share Price Inflation (ERC4626)

| Field | Value |
|-------|-------|
| **Severity** | Critical |
| **Impact** | Direct Fund Loss (theft of subsequent deposits) |
| **Likelihood** | High (well-known attack vector) |
| **File** | `MeridianVault.sol` |
| **Location** | `convertToShares()` and `deposit()` — no virtual share/asset offset |
| **Difficulty** | Medium |

**Description**: The vault calculates shares as `(assets * supply) / totalAssets()`. When `supply == 0`, the first depositor gets a 1:1 ratio. An attacker can exploit the integer division rounding in `convertToShares` to steal funds from subsequent depositors:

**Exploit Path**:  
1. Attacker deposits **1 wei** of the underlying asset → receives 1 share
2. Attacker **donates** (direct transfers) a large amount (e.g., 10,000 tokens) to the vault
3. `totalAssets()` is now 10,000e18 + 1, but `totalSupply` is still 1
4. Victim deposits 10,000 tokens: `convertToShares(10000e18) = (10000e18 * 1) / (10000e18 + 1) = 0`
5. Victim gets **0 shares** — their entire deposit is lost to the attacker
6. Attacker redeems their 1 share for the vault's entire balance (~20,000 tokens)

**Recommendation**: Implement virtual shares and virtual assets (EIP-4626 mitigation):
```solidity
function convertToShares(uint256 assets) public view returns (uint256) {
    return (assets * (totalSupply + 1)) / (totalAssets() + 1);
}
```

---

### V-04: Self-Liquidation Bonus Extraction

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Impact** | Direct Fund Loss (protocol capital extraction) |
| **Likelihood** | Medium (requires oracle interaction) |
| **File** | `MeridianLendingPool.sol` |
| **Location** | `liquidate()` function — no `msg.sender != borrower` check |
| **Difficulty** | Medium |

**Description**: The `liquidate()` function does not prevent a borrower from liquidating their own position. Combined with the 10% liquidation bonus (`LIQUIDATION_BONUS = 1100`), an attacker can extract value by deliberately making their position underwater and then self-liquidating to receive the bonus.

**Exploit Path**:  
1. Attacker deposits $100,000 of collateral, borrows $74,000 (near the 75% CF limit)
2. Attacker manipulates the oracle price (via V-01 TWAP manipulation) to push their health factor below 1.0
3. Attacker calls `liquidate(self, debtToken, collateralToken, repayAmount)` from the same address
4. Attacker repays $37,000 of debt (50% close factor) and receives $40,700 of collateral (10% bonus)
5. Net profit: $3,700 extracted from the protocol's collateral pool
6. Repeats until position is fully liquidated

**Recommendation**: Add `require(msg.sender != borrower, "Cannot self-liquidate")` and consider reducing the liquidation bonus or making it dynamic.

---

### V-05: Interest Rate Manipulation via Utilization Spike

| Field | Value |
|-------|-------|
| **Severity** | Medium |
| **Impact** | Indirect Fund Loss (inflated interest on existing borrowers) |
| **Likelihood** | Medium (requires understanding of accrual mechanics) |
| **Files** | `InterestRateModel.sol` + `MeridianLendingPool.sol` |
| **Location** | `accrueInterest()` uses current `cash` balance at accrual time for ALL past blocks |
| **Difficulty** | Hard |

**Description**: The `accrueInterest()` function in `MeridianLendingPool` calculates interest based on the *current* cash balance at the moment of accrual, but applies the resulting rate to all blocks since the last accrual (`blockDelta`). An attacker can temporarily remove cash from the pool right before triggering accrual, causing a utilization spike that results in an artificially high interest rate being applied retroactively.

**Exploit Path**:  
1. A market has not had `accrueInterest()` called for 100 blocks
2. Normal utilization would be ~60% (below kink → moderate rate)
3. Attacker borrows a large amount from the pool, reducing `cash` to near-zero
4. Utilization jumps to ~99% (above kink → jump multiplier applies: 200% APR slope)
5. Attacker (or anyone) calls `accrueInterest()` — the high rate is applied to ALL 100 blocks
6. All existing borrowers' debt increases as if the rate was spiked for the entire period
7. Attacker repays their borrow immediately (only 1 block of interest on their own debt)

The `InterestRateModel` has no rate cap and the lending pool has no smoothing mechanism.

**Recommendation**: 
- Cap the maximum utilization rate used for accrual (e.g., use a moving average)
- Call `accrueInterest()` before any borrow/withdraw that changes cash
- The pool *does* call accrueInterest before borrow, but the issue persists if someone withdraws deposits first

---

### V-06: Fee-on-Transfer Token Accounting Divergence

| Field | Value |
|-------|-------|
| **Severity** | Critical |
| **Impact** | Protocol Insolvency (accounting > actual balance) |
| **Likelihood** | High (wELD is a listed collateral with 1% fee) |
| **Files** | `MeridianLendingPool.sol` + `FeeOnTransferToken.sol` |
| **Location** | `deposit()` at line `accountSnapshots[msg.sender][token].depositBalance += amount` |
| **Difficulty** | **Very Hard** (requires cross-contract analysis) |

**Description**: This is the most critical and hardest-to-detect vulnerability. `MeridianLendingPool.deposit()` calls `IERC20(token).transferFrom(msg.sender, address(this), amount)` and then credits `amount` to the user's internal balance. However, `FeeOnTransferToken` (wELD) deducts a 1% fee on every transfer. The pool receives only 99% of `amount` but records 100%.

This creates a permanent accounting divergence that grows with every deposit:

**Exploit Path**:  
1. Alice deposits 10,000 wELD → pool receives 9,900, records 10,000
2. Bob deposits 10,000 wELD → pool receives 9,900, records 10,000
3. Charlie deposits 10,000 wELD → pool receives 9,900, records 10,000
4. Pool actual balance: 29,700. Pool recorded total: 30,000
5. Alice withdraws 10,000 wELD → OK (pool has 29,700, sends 10,000, fee takes 100, Alice gets 9,900)
6. Bob withdraws 10,000 wELD → OK (pool has 19,700, sends 10,000)
7. **Charlie tries to withdraw 10,000 wELD → REVERTS** (pool only has 9,700)
8. Charlie has lost access to $300 worth of tokens

**Advanced exploit**: An attacker can deposit wELD, get credited the full amount as collateral, then borrow real tokens (MERID, WETH) against inflated collateral. The attacker's collateral is worth less than what the protocol thinks, enabling under-collateralized borrows.

**Why this is hard to detect**:
- The `deposit()` function looks perfectly correct for standard ERC20 tokens
- The vulnerability only manifests when interacting with FOT tokens
- It requires understanding the transfer fee behavior of `wELD` AND tracing it through `MeridianLendingPool.deposit()`
- From the lending pool's perspective, it correctly calls `transferFrom` — the issue is the *assumption* that the received amount equals the requested amount

**Recommendation**: Measure actual balance change instead of trusting the transfer amount:
```solidity
uint256 balanceBefore = IERC20(token).balanceOf(address(this));
IERC20(token).transferFrom(msg.sender, address(this), amount);
uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
accountSnapshots[msg.sender][token].depositBalance += received;
```

---

## 7. Vulnerability Summary

| ID | Name | Severity | Impact | File(s) | Difficulty |
|----|------|----------|--------|---------|------------|
| V-01 | TWAP Oracle Short Window | High | Price Manipulation | `MeridianOracle.sol` | Medium |
| V-02 | Missing Slippage Protection | High | Sandwich / MEV | `MeridianPool.sol` | Easy |
| V-03 | First Depositor Inflation | Critical | Direct Fund Loss | `MeridianVault.sol` | Medium |
| V-04 | Self-Liquidation Bonus | High | Capital Extraction | `MeridianLendingPool.sol` | Medium |
| V-05 | Interest Rate Manipulation | Medium | Indirect Fund Loss | `InterestRateModel.sol` + `MeridianLendingPool.sol` | Hard |
| V-06 | FOT Accounting Divergence | Critical | Insolvency | `MeridianLendingPool.sol` + `FeeOnTransferToken.sol` | Very Hard |

**Severity Distribution**: 2 Critical, 3 High, 1 Medium

---

## 8. Build & Test

```bash
forge build
forge test
```

---

## 9. Points of Contact

- **Protocol Lead**: security@meridian.finance
- **Contest Platform**: SolGuard Automated Audit
- **Emergency Contact**: Meridian Multisig (0x...)
