// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

library DataTypes {

    struct AssetConfig {
        address asset; // underlying asset address
        uint8 decimals; // decimals of underlying asset
        uint mcr; // minimum collateral ratio
        uint ccr; // critical collateral ratio
        uint collateralCap; // 0 corresponds to unlimited cap
        uint liquidationBonusDivisor; // e.g. dividing by 200 yields 0.5%
        uint reserveFactor;
        uint minDebt; // net debt (debt - gas compensation)
        uint bootstrapTimestamp;
        uint flashLoanFeeDivisor; // e.g. dividing by 200 yields 0.5%
        address priceOracleAddress;
        address feeRateModelAddress;
        FeeRateParams feeRateParams;
    }

    struct FeeRateParams {
        uint borrowFeeRateFloor;
        uint borrowFeeRateCeil;
        uint redeemFeeRateFloor;
        uint redeemFeeRateCeil;
    }
}