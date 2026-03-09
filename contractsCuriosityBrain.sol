// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./CuriosityOracle.sol";

/**
 * @title CuriosityBrain
 * @dev Upgradeable strategy logic with dynamic parameter adjustment
 * Uses Transparent Proxy pattern for upgradability
 */
contract CuriosityBrain is Initializable, OwnableUpgradeable {
    CuriosityVault public vault;
    CuriosityOracle public oracle;
    IERC20 public usdc;
    
    address public oneInchAggregator;
    
    // Trading parameters
    uint256 public minProfitThreshold; // 0.8% = 80 (basis points)
    uint256 public maxTradeSize;
    uint256 public dailyTradeLimit;
    uint256 public tradesToday;
    uint256 public lastTradeDay;
    
    // Performance tracking
    struct TradeRecord {
        uint256 timestamp;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        int256 profit;
        uint256 gasUsed;
    }
    
    TradeRecord[] public tradeHistory;
    uint256 constant PERFORMANCE_WINDOW = 50;
    
    // Dynamic gas bidding
    uint256 public gasPremium;
    uint256 public baseFeeMA; // 15-block moving average
    
    event TradeExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        int256 profit,
        uint256 gasPrice
    );
    event ParametersUpdated(uint256 minProfitThreshold, uint256 maxTradeSize);
    
    function initialize(
        address _vault,
        address _oracle,
        address _usdc,
        address _oneInch
    ) public initializer {
        __Ownable_init();
        vault = CuriosityVault(_vault);
        oracle = CuriosityOracle(_oracle);
        usdc = IERC20(_usdc);
        oneInchAggregator = _oneInch;
        
        // Initial parameters
        minProfitThreshold = 80; // 0.8%
        maxTradeSize = 25 * 10**6; // $0.25 in USDC (6 decimals)
        dailyTradeLimit = 100;
        gasPremium = 10; // 10% premium
    }
    
    function executeTrade(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata oneInchData,
        uint256 minAmountOut
    ) external onlyOwner returns (uint256) {
        require(amountIn <= maxTradeSize, "Exceeds max trade size");
        require(checkDailyLimit(), "Daily limit reached");
        
        // Verify LAI signal
        require(oracle.isValidLAI(tokenIn, tokenOut), "Invalid LAI signal");
        
        // Get real-time quote validation
        uint256 validatedAmount = oracle.verifyTrade(
            tokenIn,
            tokenOut,
            amountIn,
            minAmountOut
        );
        require(validatedAmount >= minAmountOut, "Slippage too high");
        
        // Execute via Vault
        uint256 actualAmountIn = vault.executeTrade(
            tokenIn,
            tokenOut,
            amountIn,
            oneInchData
        );
        
        // Calculate profit (simplified - actual profit calculated off-chain)
        uint256 amountOut = 0; // Would come from 1inch execution
        int256 profit = 0; // Calculated off-chain and reported back
        
        // Record trade
        tradeHistory.push(TradeRecord({
            timestamp: block.timestamp,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: actualAmountIn,
            amountOut: amountOut,
            profit: profit,
            gasUsed: tx.gasprice
        }));
        
        // Trim history if too long
        if (tradeHistory.length > PERFORMANCE_WINDOW * 2) {
            for (uint i = 0; i < PERFORMANCE_WINDOW; i++) {
                tradeHistory[i] = tradeHistory[i + PERFORMANCE_WINDOW];
            }
            tradeHistory.length = PERFORMANCE_WINDOW;
        }
        
        // Update daily counter
        updateDailyCounter();
        
        emit TradeExecuted(tokenIn, tokenOut, amountIn, amountOut, profit, tx.gasprice);
        return actualAmountIn;
    }
    
    function reportProfit(uint256 tradeId, int256 profit) external onlyOwner {
        require(tradeId < tradeHistory.length, "Invalid trade ID");
        tradeHistory[tradeId].profit = profit;
        
        if (profit > 0) {
            vault.receiveProfits(uint256(profit));
        }
        
        // Adjust parameters based on performance
        adjustParameters();
    }
    
    function adjustParameters() internal {
        if (tradeHistory.length < 10) return;
        
        // Calculate win rate over last 50 trades
        uint256 wins = 0;
        uint256 startIndex = tradeHistory.length > PERFORMANCE_WINDOW 
            ? tradeHistory.length - PERFORMANCE_WINDOW 
            : 0;
        
        for (uint i = startIndex; i < tradeHistory.length; i++) {
            if (tradeHistory[i].profit > 0) {
                wins++;
            }
        }
        
        uint256 winRate = (wins * 100) / (tradeHistory.length - startIndex);
        
        // Dynamic adjustment
        if (winRate < 50) {
            // Reduce risk
            maxTradeSize = (maxTradeSize * 80) / 100;
            minProfitThreshold = minProfitThreshold + 20; // Increase threshold
        } else if (winRate > 60) {
            // Increase risk slightly
            maxTradeSize = (maxTradeSize * 110) / 100;
            minProfitThreshold = max(minProfitThreshold - 10, 50); // Lower threshold
        }
        
        emit ParametersUpdated(minProfitThreshold, maxTradeSize);
    }
    
    function updateDailyCounter() internal {
        uint256 today = block.timestamp / 1 days;
        if (today != lastTradeDay) {
            tradesToday = 0;
            lastTradeDay = today;
        }
        tradesToday++;
    }
    
    function checkDailyLimit() internal view returns (bool) {
        uint256 today = block.timestamp / 1 days;
        if (today != lastTradeDay) return true;
        return tradesToday < dailyTradeLimit;
    }
    
    function updateGasPremium(uint256 newPremium) external onlyOwner {
        require(newPremium <= 50, "Premium too high"); // Max 50%
        gasPremium = newPremium;
    }
    
    function setOneInchAggregator(address aggregator) external onlyOwner {
        oneInchAggregator = aggregator;
    }
}