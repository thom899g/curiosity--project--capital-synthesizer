// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CuriosityVault
 * @dev Non-upgradeable capital custodian with tiered circuit breakers
 * CRITICAL: Non-upgradeable for maximum security - only accepts calls from CuriosityBrain
 */
contract CuriosityVault is Ownable {
    IERC20 public immutable usdc;
    address public authorizedBrain;
    
    uint256 public totalPrincipal;
    uint256 public totalProfits;
    uint256 public lastCompoundTime;
    
    // Circuit breaker state
    enum CircuitState { NORMAL, ALERT_1, ALERT_2, HALTED }
    CircuitState public circuitState;
    uint256 public maxDrawdown;
    uint256 public currentDrawdown;
    uint256 public positionSizeMultiplier = 100; // 100% = 1.00
    
    // Gas bank system
    uint256 public gasBankBalance;
    uint256 constant GAS_BANK_ALLOCATION = 5; // 5% of profits
    
    event FundsDeposited(address indexed depositor, uint256 amount);
    event FundsWithdrawn(address indexed to, uint256 amount);
    event CircuitBreakerTriggered(CircuitState newState);
    event GasBankFunded(uint256 amount);
    event ProfitsCompounded(uint256 amount);
    
    modifier onlyBrain() {
        require(msg.sender == authorizedBrain, "Only authorized brain");
        _;
    }
    
    constructor(address _usdc) {
        usdc = IERC20(_usdc);
        circuitState = CircuitState.NORMAL;
        maxDrawdown = 0;
    }
    
    function setAuthorizedBrain(address _brain) external onlyOwner {
        authorizedBrain = _brain;
    }
    
    function deposit(uint256 amount) external onlyOwner {
        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        totalPrincipal += amount;
        emit FundsDeposited(msg.sender, amount);
    }
    
    function executeTrade(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata swapData
    ) external onlyBrain returns (uint256) {
        require(circuitState != CircuitState.HALTED, "System halted");
        require(amountIn <= getMaxTradeSize(), "Exceeds max trade size");
        
        // Check USDC balance
        uint256 balanceBefore = usdc.balanceOf(address(this));
        require(balanceBefore >= amountIn, "Insufficient funds");
        
        // Execute swap via 1inch aggregator (will be called from Brain)
        // This function just provides the funds - Brain handles actual swap
        usdc.transfer(authorizedBrain, amountIn);
        
        return amountIn;
    }
    
    function receiveProfits(uint256 profitAmount) external onlyBrain {
        totalProfits += profitAmount;
        
        // Allocate to gas bank
        uint256 gasAllocation = (profitAmount * GAS_BANK_ALLOCATION) / 100;
        gasBankBalance += gasAllocation;
        emit GasBankFunded(gasAllocation);
        
        // Update drawdown metrics
        updateDrawdownMetrics(profitAmount);
        
        // Auto-compound 95% of profits (5% went to gas bank)
        uint256 compoundAmount = profitAmount - gasAllocation;
        totalPrincipal += compoundAmount;
        lastCompoundTime = block.timestamp;
        emit ProfitsCompounded(compoundAmount);
    }
    
    function updateDrawdownMetrics(uint256 profitAmount) internal {
        if (profitAmount > 0) {
            // Positive trade - reduce drawdown
            if (currentDrawdown > profitAmount) {
                currentDrawdown -= profitAmount;
            } else {
                currentDrawdown = 0;
                maxDrawdown = 0;
                circuitState = CircuitState.NORMAL;
                positionSizeMultiplier = 100;
            }
        } else {
            // Negative trade - update drawdown
            currentDrawdown += (-profitAmount);
            if (currentDrawdown > maxDrawdown) {
                maxDrawdown = currentDrawdown;
            }
            checkCircuitBreaker();
        }
    }
    
    function checkCircuitBreaker() internal {
        uint256 drawdownPercent = (currentDrawdown * 100) / totalPrincipal;
        
        if (drawdownPercent >= 20) {
            circuitState = CircuitState.HALTED;
            positionSizeMultiplier = 0;
            emit CircuitBreakerTriggered(CircuitState.HALTED);
        } else if (drawdownPercent >= 15) {
            circuitState = CircuitState.ALERT_2;
            positionSizeMultiplier = 10; // 10% of normal size
            emit CircuitBreakerTriggered(CircuitState.ALERT_2);
        } else if (drawdownPercent >= 10) {
            circuitState = CircuitState.ALERT_1;
            positionSizeMultiplier = 50; // 50% of normal size
            emit CircuitBreakerTriggered(CircuitState.ALERT_1);
        }
    }
    
    function getMaxTradeSize() public view returns (uint256) {
        uint256 baseSize = (totalPrincipal * 5) / 100; // 5% of capital
        return (baseSize * positionSizeMultiplier) / 100;
    }
    
    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        require(circuitState == CircuitState.HALTED, "Only in halted state");
        usdc.transfer(to, amount);
        emit FundsWithdrawn(to, amount);
    }
    
    function resetCircuitBreaker() external onlyOwner {
        circuitState = CircuitState.NORMAL;
        currentDrawdown = 0;
        positionSizeMultiplier = 100;
    }
}