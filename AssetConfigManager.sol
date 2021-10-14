// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "./Dependencies/IERC20.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/OwnableUpgradeable.sol";
import {DataTypes} from "./Dependencies/DataTypes.sol";
import "./Interfaces/IAssetConfigManager.sol";
import "./Dependencies/console.sol";
import "./Dependencies/AddressLib.sol";

contract AssetConfigManager is IAssetConfigManager, OwnableUpgradeable, CheckContract {
    using AddressLib for address;

    string constant public NAME = "AssetConfigManager";

    uint constant public ONE_HUNDRED_PCT = 1000000000000000000; // 100%

    // asset address -> AssetConfig
    mapping(address => DataTypes.AssetConfig) public assetConfigs;

    // supported assets
    address[] public assets;

    modifier onlySupportedAsset(address asset) {
        require(assetConfigs[asset].asset != address(0), "Asset not supported");
        _;
    }

    modifier onlyUnsupportedAsset(address asset) {
        require(assetConfigs[asset].asset == address(0), "Asset already supported");
        _;
    }

    function initialize() public initializer {
        __Ownable_init();
    }

    function create(DataTypes.AssetConfig memory config)
        external
        override
        onlyOwner
        onlyUnsupportedAsset(config.asset)
    {
        requireValidConfig(config);

        assetConfigs[config.asset] = config;
        assets.push(config.asset);

        emit AssetConfigCreated(config.asset, config);
    }

    function update(DataTypes.AssetConfig memory config)
        external
        override
        onlyOwner
        onlySupportedAsset(config.asset)
    {
        requireValidConfig(config);

        assetConfigs[config.asset] = config;

        emit AssetConfigUpdated(config.asset, config);
    }

    function get(address asset)
        external
        view
        override
        onlySupportedAsset(asset)
        returns (DataTypes.AssetConfig memory)
    {
        return assetConfigs[asset];
    }

    function isSupported(address asset)
        external
        view
        override
        returns (bool)
    {
        return assetConfigs[asset].asset != address(0);
    }

    function supportedAssets()
        external
        view
        override
        returns (address[] memory)
    {
        return assets;
    }

    function requireValidConfig(DataTypes.AssetConfig memory config) internal view {
        // check contract addresses
        checkContract(config.priceOracleAddress);
        checkContract(config.feeRateModelAddress);

        // check decimals
        if (config.asset.isPlatformToken()) {
            require(config.decimals == 18, "decimal incorrect");
        } else {
            checkContract(config.asset);
            uint decimals = IERC20(config.asset).decimals();
            require(config.decimals == decimals, "decimal incorrect");
        }

        // check mcr
        require(config.mcr > ONE_HUNDRED_PCT, "invalid mcr");

        // check ccr
        require(config.ccr > ONE_HUNDRED_PCT, "invalid ccr");

        // check liquidation bonus
        require(config.liquidationBonusDivisor >= 10, "invalid liquidation bonus divisor");

        // check reserve factor
        require(config.reserveFactor >= 0 && config.reserveFactor < ONE_HUNDRED_PCT, "invalid reserve factor");

        // check min debt
        require(config.minDebt > 0, "invalid min debt");

        // check flash loan fee
        require(config.flashLoanFeeDivisor >= 2, "invalid flash loan fee divisor");

        // check bootstrap timestamp
        require(config.bootstrapTimestamp > block.timestamp, "invalid bootstrap timestamp");

        // check borrowing fee rates
        require(config.feeRateParams.borrowFeeRateFloor > 0 && config.feeRateParams.borrowFeeRateFloor < ONE_HUNDRED_PCT, "invalid borrow fee rate floor");
        require(config.feeRateParams.borrowFeeRateCeil > 0 && config.feeRateParams.borrowFeeRateCeil < ONE_HUNDRED_PCT, "invalid borrow fee rate ceil");
        require(config.feeRateParams.borrowFeeRateFloor < config.feeRateParams.borrowFeeRateCeil, "borrowFeeRateFloor >= borrowFeeRateCeil");

        // check redeem fee rates
        require(config.feeRateParams.redeemFeeRateFloor > 0 && config.feeRateParams.redeemFeeRateFloor < ONE_HUNDRED_PCT, "invalid redeem fee rate floor");
        require(config.feeRateParams.redeemFeeRateCeil > 0 && config.feeRateParams.redeemFeeRateCeil < ONE_HUNDRED_PCT, "invalid redeem fee rate ceil");
        require(config.feeRateParams.redeemFeeRateFloor < config.feeRateParams.redeemFeeRateCeil, "redeemFeeRateFloor >= redeemFeeRateCeil");
    }

}