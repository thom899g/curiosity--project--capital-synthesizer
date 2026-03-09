// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CuriosityOracle
 * @dev Data integrity layer for LAI values with multi-source validation
 */
contract CuriosityOracle is Ownable {
    struct LAIUpdate {
        uint256 laiValue;
        uint256 timestamp;
        address tokenPair;
        bytes signature;
    }
    
    mapping(address => mapping(address => LAIUpdate)) public laiData;
    mapping(address => bool) public authorizedRelayers;
    
    uint256 constant MAX_DATA_AGE = 12 seconds; // ~2 blocks
    uint256 constant SLIPPAGE_TOLERANCE = 5; // 0.5% = 5 basis points
    
    event LAIUpdated(address indexed tokenA, address indexed tokenB, uint256 laiValue);
    event RelayerAuthorized(address indexed relayer);
    event RelayerRevoked(address indexed relayer);
    
    modifier onlyRelayer() {
        require(authorizedRelayers[msg.sender], "Unauthorized relayer");
        _;
    }
    
    function authorizeRelayer(address relayer) external onlyOwner {
        authorizedRelayers[relayer] = true;
        emit RelayerAuthorized(relayer);
    }
    
    function revokeRelayer(address relayer) external onlyOwner {
        authorizedRelayers[relayer] = false;
        emit RelayerRevoked(relayer);
    }
    
    function updateLAI(
        address tokenA,
        address tokenB,
        uint256 laiValue,
        bytes calldata signature
    ) external onlyRelayer {
        require(tokenA != tokenB, "Same token");
        require(laiValue > 0, "Invalid LAI value");
        
        LAIUpdate memory update = LAIUpdate({
            laiValue: laiValue,
            timestamp: block.timestamp,
            tokenPair: tokenA,
            signature: signature
        });
        
        laiData[tokenA][tokenB] = update;
        laiData[tokenB][tokenA] = update;
        
        emit LAIUpdated(tokenA, tokenB, laiValue);
    }
    
    function isValidLAI(address tokenA, address tokenB) public view returns (bool) {
        LAIUpdate memory update = laiData[tokenA][tokenB];
        
        if (update.timestamp == 0) return false;
        if (block.timestamp - update.timestamp > MAX_DATA_AGE) return false;
        
        // Basic LAI validation: 0.5 to 2.0 range
        if (update.laiValue < 50 || update.laiValue > 200) return false;
        
        // Check for significant asymmetry (>15%)
        if (update.laiValue > 115 || update.laiValue < 85) {
            return true;
        }
        
        return false;
    }
    
    function verifyTrade(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external view returns (uint256) {
        require(isValidLAI(tokenIn, tokenOut), "Invalid LAI");
        
        // Get current prices from Uniswap V3 (simplified - would use actual oracle)
        uint256 spotPrice = getSpotPrice(tokenIn,