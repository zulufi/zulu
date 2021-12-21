// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "../Dependencies/AddressLib.sol";
import "../Dependencies/AggregatorV3Interface.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/MultiAssetInitializable.sol";
import "../Dependencies/SafeMath.sol";
import "../Interfaces/IAssetConfigManager.sol";
import "../Interfaces/IPriceFeed.sol";
import "./Uniswap/UniswapLib.sol";

struct Observation {
    uint256 timestamp;
    uint256 acc;
}

struct TokenConfig {
    address token;
    uint8 decimals;
    address chainlinkProxy;
    address uniswapPair;
    uint8 pairTokenDecimals;
    bool isUniswapReversed;
}

contract PriceFeed is CheckContract, MultiAssetInitializable, IPriceFeed {
    using FixedPoint for *;
    using SafeMath for uint256;
    using AddressLib for address;

    IAssetConfigManager public assetConfigManager;

    // Use to convert a price answer to an 18-digit precision uint
    uint256 public constant TARGET_DIGITS = 18;

    /// @notice The number of wei in 1 ETH
    uint256 public constant ethBaseUnit = 1e18;

    /// @notice A common scaling factor to maintain precision
    uint256 public constant expScale = 1e18;

    /// @notice The highest ratio of the new price to the anchor price that will still trigger the price to be updated
    uint256 public upperBoundAnchorRatio;

    /// @notice The lowest ratio of the new price to the anchor price that will still trigger the price to be updated
    uint256 public lowerBoundAnchorRatio;

    /// @notice The minimum amount of time in seconds required for the old uniswap price accumulator to be replaced
    uint256 public anchorPeriod;

    /// @notice Official prices by token address
    mapping(address => uint256) public prices;

    /// @notice The old observation for each token address
    mapping(address => Observation) public oldObservations;

    /// @notice The new observation for each token address
    mapping(address => Observation) public newObservations;

    mapping(address => TokenConfig) public tokenConfigMap;

    enum Status {
        both,
        chainlink,
        uniswap,
        none
    }

    // The current status of the PriceFeed, which determines the conditions for the next price fetch attempt
    Status public status;

    struct ChainlinkResponse {
        uint80 roundId;
        int256 answer;
        uint256 timestamp;
        uint8 decimals;
    }

    // --- Events ---
    event AssetConfigManagerAddressChanged(address newAssetConfigManagerAddress);

    event AnchorRatioChanged(uint256 upperBoundAnchorRatio, uint256 lowerBoundAnchorRatio);

    event TokenConfigCreated(address indexed token, TokenConfig tokenConfig);

    event StatusChanged(Status status);

    /// @notice The event emitted when the stored price is not updated due to the anchor
    event PriceGuarded(address indexed token, uint256 chainlinkPrice, uint256 anchor);

    /// @notice The event emitted when anchor price is updated
    event UniswapPriceUpdated(
        address indexed token,
        uint256 price,
        uint256 oldTimestamp,
        uint256 newTimestamp
    );

    /// @notice The event emitted when the uniswap window changes
    event UniswapWindowUpdated(
        address indexed token,
        uint256 oldTimestamp,
        uint256 oldPrice,
        uint256 newTimestamp,
        uint256 newPrice
    );

    function initialize() public initializer {
        __Ownable_init();
    }

    /**
     * @notice Construct a uniswap anchored view for a set of token configurations
     * @dev Note that to avoid immature TWAPs, the system must run for at least a single anchorPeriod before using.
     * @param _anchorToleranceMantissa The percentage tolerance that the reporter may deviate from the uniswap anchor
     * @param _anchorPeriod The minimum amount of time required for the old uniswap price accumulator to be replaced
     */
    function setParams(
        address _assetConfigManagerAddress,
        uint256 _anchorToleranceMantissa,
        uint256 _anchorPeriod
    ) external onlyOwner {

        require(address(assetConfigManager) == address(0), "address has already been set");

        checkContract(_assetConfigManagerAddress);

        assetConfigManager = IAssetConfigManager(_assetConfigManagerAddress);

        anchorPeriod = _anchorPeriod;

        setAnchorBound(_anchorToleranceMantissa);

        emit AssetConfigManagerAddressChanged(_assetConfigManagerAddress);
    }

    function setAnchorTolerance(uint256 _anchorToleranceMantissa) external onlyOwner {
        setAnchorBound(_anchorToleranceMantissa);
    }

    function setStatus(Status _status) external onlyOwner {
        status = _status;
        emit StatusChanged(_status);
    }

    function setAnchorBound(uint256 _anchorToleranceMantissa) internal {
        // Allow the tolerance to be whatever the deployer chooses, but prevent under/overflow (and prices from being 0)
        upperBoundAnchorRatio = _anchorToleranceMantissa > uint256(-1) - 100e16
            ? uint256(-1)
            : 100e16 + _anchorToleranceMantissa;
        lowerBoundAnchorRatio = _anchorToleranceMantissa < 100e16
            ? 100e16 - _anchorToleranceMantissa
            : 1;
        emit AnchorRatioChanged(upperBoundAnchorRatio, lowerBoundAnchorRatio);
    }

    function initializeAssetInternal(address asset, bytes calldata data) internal override {
        TokenConfig memory config = abi.decode(data, (TokenConfig));
        require(asset == config.token, "incorret asset");
        // make sure asset is supported
        DataTypes.AssetConfig memory assetConfig = assetConfigManager.get(config.token);

        require(config.decimals == assetConfig.decimals, "incorrect decimals");

        checkContract(config.chainlinkProxy);
        checkContract(config.uniswapPair);

        tokenConfigMap[config.token] = config;
        pokeWindowValues(config);

        emit TokenConfigCreated(config.token, config);
    }

    /**
     * @notice Get the official price for a token
     * @param token The token address to fetch the price of
     * @return Price denominated in USD, with 18 decimals
     */
    function getPrice(address token)
        external
        view
        override
        onlySupportedAsset(token)
        returns (uint256)
    {
        return prices[token];
    }

    /**
     * @notice fetch price, and recalculate stored price by comparing to anchor
     */
    function fetchPrice(address token)
        external
        override
        onlySupportedAsset(token)
        returns (uint256)
    {
        // neither works
        if (status == Status.none) {
            return prices[token];
        }
        TokenConfig memory config = tokenConfigMap[token];
        uint256 chainlinkPrice;
        if (status != Status.uniswap) {
            chainlinkPrice = getCurrentChainlinkResponse(config);
        }
        // chainlink only
        if (status == Status.chainlink) {
            prices[token] = chainlinkPrice;
            emit PriceUpdated(token, chainlinkPrice);
            return chainlinkPrice;
        }
        uint256 anchorPrice = fetchUniswapPrice(config);
        // uniswap only
        if (status == Status.uniswap) {
            prices[token] = anchorPrice;
            emit PriceUpdated(token, anchorPrice);
            return anchorPrice;
        }
        // both work, caculate price by comparing to anchor
        if (isWithinAnchor(chainlinkPrice, anchorPrice)) {
            prices[token] = chainlinkPrice;
            emit PriceUpdated(token, chainlinkPrice);
            return chainlinkPrice;
        } else {
            emit PriceGuarded(token, chainlinkPrice, anchorPrice);
            return prices[token];
        }
    }

    function fetchUniswapPrice(TokenConfig memory config) internal returns (uint256) {
        uint256 ethPrice = fetchEthPrice();
        if (config.token.isPlatformToken()) {
            return ethPrice;
        }
        return fetchAnchorPrice(config, ethPrice);
    }

    function isWithinAnchor(uint256 chainlinkPrice, uint256 anchorPrice)
        internal
        view
        returns (bool)
    {
        if (chainlinkPrice > 0) {
            uint256 anchorRatio = anchorPrice.mul(100e16).div(chainlinkPrice);
            return anchorRatio <= upperBoundAnchorRatio && anchorRatio >= lowerBoundAnchorRatio;
        }
        return false;
    }

    /**
     * @dev Fetches the current token/eth price accumulator from uniswap.
     */
    function currentCumulativePrice(TokenConfig memory config) internal view returns (uint256) {
        (uint256 cumulativePrice0, uint256 cumulativePrice1, ) = UniswapV2OracleLibrary
            .currentCumulativePrices(config.uniswapPair);
        if (config.isUniswapReversed) {
            return cumulativePrice1;
        } else {
            return cumulativePrice0;
        }
    }

    /**
     * @dev Fetches the current eth/usd price from uniswap, with 18 decimals of precision.
     *  Conversion factor is 1e18 for eth/usdc market, since we decode uniswap price statically with 18 decimals.
     */
    function fetchEthPrice() internal returns (uint256) {
        return fetchAnchorPrice(tokenConfigMap[AddressLib.PLATFORM_TOKEN_ADDRESS], ethBaseUnit);
    }

    /**
     * @dev Fetches the current token/usd price from uniswap, with 18 decimals of precision.
     * @param conversionFactor 1e18 if seeking the ETH price, and a 18 decimal ETH-USDC price in the case of other assets
     */
    function fetchAnchorPrice(TokenConfig memory config, uint256 conversionFactor)
        internal
        virtual
        returns (uint256)
    {
        (
            uint256 nowCumulativePrice,
            uint256 oldCumulativePrice,
            uint256 oldTimestamp
        ) = pokeWindowValues(config);

        // This should be impossible, but better safe than sorry
        require(block.timestamp > oldTimestamp, "now must come after before");
        uint256 timeElapsed = block.timestamp - oldTimestamp;

        // Calculate uniswap time-weighted average price
        // Underflow is a property of the accumulators: https://uniswap.org/audit.html#orgc9b3190
        FixedPoint.uq112x112 memory priceAverage = FixedPoint.uq112x112(
            uint224((nowCumulativePrice - oldCumulativePrice) / timeElapsed)
        );
        uint256 rawUniswapPriceMantissa = priceAverage.decode112with18();
        uint256 unscaledPriceMantissa = rawUniswapPriceMantissa.mul(conversionFactor);
        uint256 anchorPrice;

        // Adjust rawUniswapPrice according to the units of the non-ETH asset
        // In the case of ETH, we would have to scale by 1e18 / USDC_UNITS

        // In the case of non-ETH tokens
        // a. pokeWindowValues already handled uniswap reversed cases, so priceAverage will always be Token/ETH TWAP price.
        // b. conversionFactor = ETH price * 1e18
        // unscaledPriceMantissa = priceAverage(token/ETH TWAP price) * expScale * conversionFactor
        // so ->
        // anchorPrice = priceAverage * tokenBaseUnit / ethBaseUnit * ETH_price * 1e18
        //             = priceAverage * conversionFactor * tokenBaseUnit / ethBaseUnit
        //             = unscaledPriceMantissa / expScale * tokenBaseUnit / ethBaseUnit
        anchorPrice = unscaledPriceMantissa
            .mul(10**uint256(config.decimals))
            .div(10**uint256(config.pairTokenDecimals))
            .div(expScale);

        emit UniswapPriceUpdated(config.token, anchorPrice, oldTimestamp, block.timestamp);

        return anchorPrice;
    }

    /**
     * @dev Get time-weighted average prices for a token at the current timestamp.
     *  Update new and old observations of lagging window if period elapsed.
     */
    function pokeWindowValues(TokenConfig memory config)
        internal
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        uint256 cumulativePrice = currentCumulativePrice(config);

        Observation memory newObservation = newObservations[config.token];

        if (newObservation.timestamp == 0) {
            // init window
            updateWindow(
                config.token,
                block.timestamp,
                cumulativePrice,
                block.timestamp,
                cumulativePrice
            );
            return (cumulativePrice, cumulativePrice, block.timestamp);
        } else {
            // Update new and old observations if elapsed time is greater than or equal to anchor period
            uint256 timeElapsed = block.timestamp - newObservation.timestamp;
            if (timeElapsed >= anchorPeriod) {
                updateWindow(
                    config.token,
                    newObservation.timestamp,
                    newObservation.acc,
                    block.timestamp,
                    cumulativePrice
                );
            }
            return (
                cumulativePrice,
                oldObservations[config.token].acc,
                oldObservations[config.token].timestamp
            );
        }
    }

    function updateWindow(
        address token,
        uint256 oldTimestamp,
        uint256 oldAcc,
        uint256 newTimestamp,
        uint256 newAcc
    ) internal {
        oldObservations[token].timestamp = oldTimestamp;
        oldObservations[token].acc = oldAcc;

        newObservations[token].timestamp = newTimestamp;
        newObservations[token].acc = newAcc;

        emit UniswapWindowUpdated(token, oldTimestamp, oldAcc, newTimestamp, newAcc);
    }

    function getCurrentChainlinkResponse(TokenConfig memory config) internal view returns (uint256) {
        AggregatorV3Interface priceAggregator = AggregatorV3Interface(config.chainlinkProxy);
        uint8 decimals = priceAggregator.decimals();

        (, int256 answer, , , ) = priceAggregator.latestRoundData();
        return scalePriceByDigits(uint256(answer), decimals);
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
}
