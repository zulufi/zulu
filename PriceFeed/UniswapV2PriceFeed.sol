// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "../Dependencies/AggregatorV3Interface.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/IERC20.sol";
import "../Dependencies/MultiAssetInitializable.sol";
import "../Dependencies/SafeMath.sol";
import "../Interfaces/IPriceFeed.sol";
import "./Dependencies/Math.sol";
import "./Uniswap/UniswapLib.sol";

/** @title UniswapV2PriceFeed
 * @notice PriceFeed for a Uniswap V2 pair token
 * It calculates the price using Chainlink as an external price source and the pair's tokens reserves using the weighted arithmetic mean formula.
 * If there is a price deviation, instead of the reserves, it uses a weighted geometric mean with the constant invariant K.
 */

contract UniswapV2PriceFeed is MultiAssetInitializable, CheckContract, IPriceFeed {
    using SafeMath for uint256;

    struct PairConfig {
        address token0;
        address token1;
        uint8 decimals0;
        uint8 decimals1;
    }

    struct ChainlinkConfig {
        address proxyAddress;
        uint8 decimals;
    }

    // Use to convert a price answer to an 18-digit precision uint
    uint256 public constant TARGET_DIGITS = 18;

    uint256 public maxPriceDeviation;

    mapping(address => PairConfig) public pairConfigMap;

    mapping(address => ChainlinkConfig) public chainlinkConfigMap;

    function initialize() public initializer {
        __Ownable_init();
    }

    /**
     * @param _maxPriceDeviation Threshold of spot prices deviation: 10ˆ16 represents a 1% deviation.
     */
    function setParams(uint256 _maxPriceDeviation) public {
        require(_maxPriceDeviation < Math.BONE, "ERR_INVALID_PRICE_DEVIATION");

        maxPriceDeviation = _maxPriceDeviation;
    }

    function initializeAssetInternal(address asset, bytes calldata data) internal override {
        PairConfig memory pairConfig;
        //Get tokens
        pairConfig.token0 = IUniswapV2Pair(asset).token0();
        pairConfig.token1 = IUniswapV2Pair(asset).token1();
        pairConfig.decimals0 = IERC20(pairConfig.token0).decimals();
        pairConfig.decimals1 = IERC20(pairConfig.token1).decimals();

        require(chainlinkConfigMap[pairConfig.token0].proxyAddress != address(0), "chainlink not set yet");
        require(chainlinkConfigMap[pairConfig.token1].proxyAddress != address(0), "chainlink not set yet");

        pairConfigMap[asset] = pairConfig;
    }

    function setChainlinkConfig(address token, address proxyAddress) external onlyOwner {
        checkContract(token);
        checkContract(proxyAddress);

        AggregatorV3Interface priceAggregator = AggregatorV3Interface(proxyAddress);
        uint8 decimals = priceAggregator.decimals();

        chainlinkConfigMap[token].proxyAddress = proxyAddress;
        chainlinkConfigMap[token].decimals = decimals;
    }

    function getChainlinkPrice(address token) internal view returns (uint256) {
        ChainlinkConfig memory config = chainlinkConfigMap[token];
        require(config.proxyAddress != address(0), "no chainlink config found");

        AggregatorV3Interface priceAggregator = AggregatorV3Interface(config.proxyAddress);

        (, int256 answer, , , ) = priceAggregator.latestRoundData();
        return scalePriceByDigits(uint256(answer), config.decimals);
    }

    function scalePriceByDigits(uint256 _price, uint256 _digits) internal pure returns (uint256) {
        /*
         * Convert the price to an TARGET_DIGITS decimal
         */
        if (_digits >= TARGET_DIGITS) {
            // Scale the returned price value down to target precision
            return _price.div(10**(_digits - TARGET_DIGITS));
        } else if (_digits < TARGET_DIGITS) {
            // Scale the returned price value up to target precision
            return _price.mul(10**(TARGET_DIGITS - _digits));
        }
    }

    /**
     * Returns the token balance in ethers by multiplying its reserves with its price in ethers.
     * @param token token address.
     * @param decimals token decimals.
     * @param reserve Token reserves.
     */
    function getBalanceByToken(
        address token,
        uint8 decimals,
        uint112 reserve
    ) internal view returns (uint256) {
        uint256 pi = getChainlinkPrice(token);
        require(pi > 0, "ERR_NO_ORACLE_PRICE");
        uint256 bi = uint256(reserve);
        if (decimals < 18) {
            uint256 missingDecimals = uint256(18).sub(decimals);
            bi = bi.mul(10**(missingDecimals));
        } else if (decimals > 18) {
            uint256 extraDecimals = uint256(decimals).sub(uint256(18));
            bi = bi.div(10**(extraDecimals));
        }
        return Math.bmul(bi, pi);
    }

    /**
     * Returns true if there is a price deviation.
     * @param balance_0 Total balance for token 0.
     * @param balance_1 Total balance for token 1.
     */
    function hasDeviation(uint256 balance_0, uint256 balance_1) internal view returns (bool) {
        //Check for a price deviation
        uint256 price_deviation = Math.bdiv(balance_0, balance_1);
        if (
            price_deviation > (Math.BONE.add(maxPriceDeviation)) ||
            price_deviation < (Math.BONE.sub(maxPriceDeviation))
        ) {
            return true;
        }
        price_deviation = Math.bdiv(balance_1, balance_0);
        if (
            price_deviation > (Math.BONE.add(maxPriceDeviation)) ||
            price_deviation < (Math.BONE.sub(maxPriceDeviation))
        ) {
            return true;
        }
        return false;
    }

    /**
     * Calculates the price of the pair token using the formula of arithmetic mean.
     * @param balance_0 Total balance for token 0.
     * @param balance_1 Total balance for token 1.
     */
    function getArithmeticMean(
        IUniswapV2Pair pair,
        uint256 balance_0,
        uint256 balance_1
    ) internal view returns (uint256) {
        uint256 totalBalance = balance_0 + balance_1;
        return Math.bdiv(totalBalance, getTotalSupplyAtWithdrawal(pair));
    }

    /**
     * Calculates the price of the pair token using the formula of weighted geometric mean.
     * @param balance_0 Total balance for token 0.
     * @param balance_1 Total balance for token 1.
     */
    function getWeightedGeometricMean(
        IUniswapV2Pair pair,
        uint256 balance_0,
        uint256 balance_1
    ) internal view returns (uint256) {
        uint256 square = Math.bsqrt(Math.bmul(balance_0, balance_1), true);
        return Math.bdiv(Math.bmul(Math.TWO_BONES, square), getTotalSupplyAtWithdrawal(pair));
    }

    /**
     * Returns Uniswap V2 pair total supply at the time of withdrawal.
     */
    function getTotalSupplyAtWithdrawal(IUniswapV2Pair pair)
        private
        view
        returns (uint256 totalSupply)
    {
        totalSupply = pair.totalSupply();
        address feeTo = IUniswapV2Factory(pair.factory()).feeTo();
        bool feeOn = feeTo != address(0);
        if (feeOn) {
            uint256 kLast = pair.kLast();
            if (kLast != 0) {
                (uint112 reserve_0, uint112 reserve_1, ) = pair.getReserves();
                uint256 rootK = Math.bsqrt(uint256(reserve_0).mul(reserve_1), false);
                uint256 rootKLast = Math.bsqrt(kLast, false);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint256 denominator = rootK.mul(5).add(rootKLast);
                    uint256 liquidity = numerator / denominator;
                    totalSupply = totalSupply.add(liquidity);
                }
            }
        }
    }

    /**
     * @dev Returns the pair's token price.
     *   It calculates the price using Chainlink as an external price source and the pair's tokens reserves using the arithmetic mean formula.
     *   If there is a price deviation, instead of the reserves, it uses a weighted geometric mean with constant invariant K.
     * @return uint256 price
     */
    function internalGetPrice(address token) internal view returns (uint256) {
        PairConfig memory pairConfig = pairConfigMap[token];
        //Get token reserves in ethers
        (uint112 reserve_0, uint112 reserve_1, ) = IUniswapV2Pair(token).getReserves();
        uint256 balance_0 = getBalanceByToken(pairConfig.token0, pairConfig.decimals0, reserve_0);
        uint256 balance_1 = getBalanceByToken(pairConfig.token1, pairConfig.decimals1, reserve_1);

        if (hasDeviation(balance_0, balance_1)) {
            //Calculate the weighted geometric mean
            return getWeightedGeometricMean(IUniswapV2Pair(token), balance_0, balance_1);
        } else {
            //Calculate the arithmetic mean
            return getArithmeticMean(IUniswapV2Pair(token), balance_0, balance_1);
        }
    }

    function getPrice(address token)
        external
        view
        override
        onlySupportedAsset(token)
        returns (uint256)
    {
        return internalGetPrice(token);
    }

    function fetchPrice(address token)
        external
        override
        onlySupportedAsset(token)
        returns (uint256)
    {
        return internalGetPrice(token);
    }
}
