// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "./Interfaces/IAssetConfigManager.sol";
import "./Interfaces/IFeeRateModel.sol";
import "./Interfaces/ILUSDToken.sol";
import "./Dependencies/BaseMath.sol";
import "./Dependencies/OwnableUpgradeable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/console.sol";
import "./Dependencies/LiquityMath.sol";
import "./Dependencies/SafeMath.sol";
import {DataTypes} from "./Dependencies/DataTypes.sol";

contract FeeRateModel is OwnableUpgradeable, CheckContract, BaseMath, IFeeRateModel {

    using SafeMath for uint;

    IAssetConfigManager public configManager;
    ILUSDToken public lusdToken;
    address public borrowerOperationsAddress;
    address public redeemerOperationsAddress;

    event AssetConfigManagerAddressChanged(address configManagerAddress);
    event LUSDTokenAddressChanged(address lusdTokenAddress);
    event BorrowerOperationsAddressChanged(address borrowerOperationsAddress);
    event RedeemerOperationsAddressChanged(address _redeemerOperationsAddress);
    event BaseRateUpdated(uint baseRate);
    event LastFeeOpTimeUpdated(uint lastFeeOpTime);
    event BetaUpdated(uint beta);
    event MinutesDecayFactorUpdated(uint factor);

    uint constant public SECONDS_IN_ONE_MINUTE = 60;

    /*
     * Half-life of 12h. 12h = 720 min
     * (1/2) = d^720 => d = (1/2)^(1/720)
     */
    uint public minutesDecayFactor;

    /*
     * Parameter by which to divide the redeemed fraction, in order to calc the new base rate from a redemption.
     * Corresponds to (1 / ALPHA) in the white paper.
     */
    uint public beta;

    /*
     * Parameter by which to divide the redeemed fraction, in order to calc the new base rate from a redemption.
     * Corresponds to (1 / ALPHA) in the white paper.
     */
    uint public baseRate;

    uint public lastFeeOperationTime;

    function initialize() public initializer {
        __Ownable_init();

        minutesDecayFactor = 999037758833783000;
        beta = 2;
    }

    function setAddresses(
        address _configManagerAddress,
        address _lusdTokenAddress,
        address _borrowerOperationAddress,
        address _redeemerOperationsAddress
    )
        external
        onlyOwner
    {
        require(borrowerOperationsAddress == address(0), "address has already been set");

        checkContract(_configManagerAddress);
        checkContract(_lusdTokenAddress);
        checkContract(_borrowerOperationAddress);
        checkContract(_redeemerOperationsAddress);

        configManager = IAssetConfigManager(_configManagerAddress);
        lusdToken = ILUSDToken(_lusdTokenAddress);
        borrowerOperationsAddress = _borrowerOperationAddress;
        redeemerOperationsAddress = _redeemerOperationsAddress;

        emit AssetConfigManagerAddressChanged(_configManagerAddress);
        emit LUSDTokenAddressChanged(_lusdTokenAddress);
        emit BorrowerOperationsAddressChanged(_borrowerOperationAddress);
        emit RedeemerOperationsAddressChanged(_redeemerOperationsAddress);
    }

    function setBeta(uint _beta) external onlyOwner {
        require(_beta > 0);
        beta = _beta;
        emit BetaUpdated(_beta);
    }

    function setMinutesDecayFactor(uint _minutesDecayFactor) external onlyOwner {
        require(_minutesDecayFactor > 0);
        minutesDecayFactor = _minutesDecayFactor;
        emit MinutesDecayFactorUpdated(_minutesDecayFactor);
    }

    function minutesPassedSinceLastFeeOp() external view returns (uint) {
        return block.timestamp.sub(lastFeeOperationTime).div(60);
    }

    function calcBorrowRate(address asset, uint price, uint borrowAmount)
        external
        override
        returns (uint)
    {
        requireCallerIsBO();

        updateBaseRateFromBorrowing();

        DataTypes.AssetConfig memory config = configManager.get(asset);
        return LiquityMath._min(
            config.feeRateParams.borrowFeeRateFloor.add(baseRate),
            config.feeRateParams.borrowFeeRateCeil
        );
    }

    function getBorrowRate(address asset, uint price, uint borrowAmount)
        external
        override
        view
        returns (uint)
    {
        DataTypes.AssetConfig memory config = configManager.get(asset);
        return LiquityMath._min(
            config.feeRateParams.borrowFeeRateFloor.add(baseRate),
            config.feeRateParams.borrowFeeRateCeil
        );
    }

    function getBorrowRateWithDecay(address asset, uint price, uint borrowAmount)
        external
        view
        returns (uint)
    {
        uint decayedBaseRate = calcDecayedBaseRate();
        assert(decayedBaseRate <= DECIMAL_PRECISION);

        DataTypes.AssetConfig memory config = configManager.get(asset);
        return LiquityMath._min(
            config.feeRateParams.borrowFeeRateFloor.add(decayedBaseRate),
            config.feeRateParams.borrowFeeRateCeil
        );
    }

    function calcRedeemRate(address asset, uint price, uint redeemAmount)
        external
        override
        returns (uint)
    {
        requireCallerIsRO();

        updateBaseRateFromRedemption(price, redeemAmount);

        DataTypes.AssetConfig memory config = configManager.get(asset);
        return LiquityMath._min(
            config.feeRateParams.redeemFeeRateFloor.add(baseRate),
            config.feeRateParams.redeemFeeRateCeil
        );
    }

    function trialCalcRedeemRate(address asset, uint price, uint redeemAmount) external view returns(uint) {
        uint _baseRate = _calcBaseRateFromRedemption(price, redeemAmount);
        DataTypes.AssetConfig memory config = configManager.get(asset);
        return LiquityMath._min(
            config.feeRateParams.redeemFeeRateFloor.add(_baseRate),
            config.feeRateParams.redeemFeeRateCeil
        );
    }

    function getRedeemRate(address asset, uint price, uint redeemAmount)
        external
        view
        override
        returns (uint)
    {
        DataTypes.AssetConfig memory config = configManager.get(asset);
        return LiquityMath._min(
            config.feeRateParams.redeemFeeRateFloor.add(baseRate),
            config.feeRateParams.redeemFeeRateCeil
        );
    }

    function getRedeemRateWithDecay(address asset, uint price, uint redeemAmount)
        external
        view
        returns (uint)
    {
        uint decayedBaseRate = calcDecayedBaseRate();
        assert(decayedBaseRate <= DECIMAL_PRECISION);

        DataTypes.AssetConfig memory config = configManager.get(asset);
        return LiquityMath._min(
            config.feeRateParams.redeemFeeRateFloor.add(baseRate),
            config.feeRateParams.redeemFeeRateCeil
        );
    }

    function updateBaseRateFromBorrowing() internal {
        uint decayedBaseRate = calcDecayedBaseRate();
        assert(decayedBaseRate <= DECIMAL_PRECISION);

        baseRate = decayedBaseRate;
        emit BaseRateUpdated(decayedBaseRate);

        updateLastFeeOpTime();
    }

    function updateBaseRateFromRedemption(uint price, uint redeemAmount) internal {
        uint newBaseRate = _calcBaseRateFromRedemption(price, redeemAmount);

        baseRate = newBaseRate;
        emit BaseRateUpdated(newBaseRate);

        updateLastFeeOpTime();
    }

    function _calcBaseRateFromRedemption(uint price, uint redeemAmount) internal view returns(uint) {
        uint decayedBaseRate = calcDecayedBaseRate();
        assert(decayedBaseRate <= DECIMAL_PRECISION);

        // Convert the drawn asset back to LUSD at face value rate (1 LUSD:1 USD), in order to get
        // the fraction of total supply that was redeemed at face value.
        // TODO: totalLUSDSupply返回的是当前已经redeem的lusd supply，并非是redeem之前的lusd supply
        uint totalLUSDSupply = lusdToken.totalSupply();
        uint redeemedLUSDFraction = redeemAmount.mul(DECIMAL_PRECISION).div(totalLUSDSupply);

        uint newBaseRate = decayedBaseRate.add(redeemedLUSDFraction.div(beta));
        newBaseRate = LiquityMath._min(newBaseRate, DECIMAL_PRECISION); // cap baseRate at a maximum of 100%
        assert(newBaseRate > 0); // Base rate is always non-zero after redemption
        return newBaseRate;
    }

    function calcDecayedBaseRate() internal view returns (uint) {
        uint minutesPassed = (block.timestamp.sub(lastFeeOperationTime)).div(SECONDS_IN_ONE_MINUTE);
        uint decayFactor = LiquityMath._decPow(minutesDecayFactor, minutesPassed);
        return baseRate.mul(decayFactor).div(DECIMAL_PRECISION);
    }

    function updateLastFeeOpTime() internal {
        uint timePassed = block.timestamp.sub(lastFeeOperationTime);

        if (timePassed >= SECONDS_IN_ONE_MINUTE) {
            lastFeeOperationTime = block.timestamp;
            emit LastFeeOpTimeUpdated(block.timestamp);
        }
    }

    function requireCallerIsRO() internal view {
        require(msg.sender == redeemerOperationsAddress, "Caller must be RO");
    }

    function requireCallerIsBO() internal view {
        require(msg.sender == borrowerOperationsAddress, "Caller must be BO");
    }
}