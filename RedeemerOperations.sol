// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "./Interfaces/IActivePool.sol";
import "./Interfaces/IAssetConfigManager.sol";
import "./Interfaces/IFarmer.sol";
import "./Interfaces/ICommunityIssuance.sol";
import "./Interfaces/IFeeRateModel.sol";
import "./Interfaces/IGuardian.sol";
import "./Interfaces/ITroveManagerV2.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/IGlobalConfigManager.sol";
import "./Interfaces/ILUSDToken.sol";
import "./Interfaces/IPriceFeed.sol";
import "./Interfaces/ILQTYStaking.sol";
import "./Interfaces/IRedeemerOperations.sol";
import "./Dependencies/BaseMath.sol";
import "./Dependencies/OwnableUpgradeable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/Guardable.sol";
import "./Dependencies/LiquityMath.sol";
import "./Dependencies/SafeMath.sol";
import "./Interfaces/IReservePool.sol";
import "./Dependencies/Lockable.sol";

contract RedeemerOperations is
    BaseMath,
    OwnableUpgradeable,
    CheckContract,
    Guardable,
    Lockable,
    IRedeemerOperations
{
    using SafeMath for uint256;
    // --- Connected contract declarations ---

    IAssetConfigManager public assetConfigManager;

    IGlobalConfigManager public globalConfigManager;

    ITroveManagerV2 public troveManager;

    IActivePool public activePool;

    address public gasPoolAddress;

    ICollSurplusPool public collSurplusPool;

    IReservePool public reservePool;

    ILUSDToken public lusdToken;

    ILQTYStaking public lqtyStaking;

    ICommunityIssuance public communityIssuance;

    uint public hintPartialNICRFactorFloor;

    /* --- Variable container structs  ---

    Used to hold, return and assign variables inside a function, in order to avoid the error:
    "CompilerError: Stack too deep". */

    struct ContractsCache {
        IAssetConfigManager assetConfigManager;
        IGlobalConfigManager globalConfigManager;
        ITroveManagerV2 troveManager;
        IActivePool activePool;
        ILUSDToken lusdToken;
        ILQTYStaking lqtyStaking;
        ICollSurplusPool collSurplusPool;
        IReservePool reservePool;
        address gasPoolAddress;
    }

    struct RedemptionTotals {
        uint256 remainingLUSD;
        uint256 totalLUSDToRedeem;
        uint256 totalCollDrawn;
        uint256 LUSDFee;
        uint256 stakingRewardAmount;
        uint256 reserveAmount;
        uint256 price;
        uint256 totalGasCompensation;
        uint256 totalCollSurplus;
    }

    struct RedeemTroveValues {
        uint256 maxLUSDamount;
        uint256 price;
        address upperPartialRedemptionHint;
        address lowerPartialRedemptionHint;
        uint256 partialRedemptionHintNICR;
    }

    struct SingleRedemptionValues {
        uint256 debt;
        uint256 coll;
        uint256 newDebt;
        uint256 newColl;
        uint256 gasCompensation;
        uint256 LUSDLot;
        uint256 CollLot;
        uint256 gasCompensationLot;
        uint256 collSurplus;
        bool cancelledPartial;
    }

    function initialize() public initializer {
        __Ownable_init();
        setHintPartialNICRFactorFloor(DECIMAL_PRECISION.sub(1e16));
    }

    function setHintPartialNICRFactorFloor(uint _factor) public override onlyOwner {
        hintPartialNICRFactorFloor = _factor;
        emit HintNICRFactorFloorChanged(_factor);
    }

    function setAddresses(
        ContractAddresses memory addresses
    ) external override onlyOwner {
        require(address(troveManager) == address(0), "address has already been set");

        checkContract(addresses.assetConfigManagerAddress);
        checkContract(addresses.globalConfigManagerAddress);
        checkContract(addresses.troveManagerAddress);
        checkContract(addresses.activePoolAddress);
        checkContract(addresses.gasPoolAddress);
        checkContract(addresses.collSurplusPoolAddress);
        checkContract(addresses.reservePoolAddress);
        checkContract(addresses.lusdTokenAddress);
        checkContract(addresses.lqtyStakingAddress);
        checkContract(addresses.guardianAddress);
        checkContract(addresses.communityIssuanceAddress);
        checkContract(addresses.lockerAddress);

        assetConfigManager = IAssetConfigManager(addresses.assetConfigManagerAddress);
        globalConfigManager = IGlobalConfigManager(addresses.globalConfigManagerAddress);
        troveManager = ITroveManagerV2(addresses.troveManagerAddress);
        activePool = IActivePool(addresses.activePoolAddress);
        gasPoolAddress = addresses.gasPoolAddress;
        collSurplusPool = ICollSurplusPool(addresses.collSurplusPoolAddress);
        reservePool = IReservePool(addresses.reservePoolAddress);
        lusdToken = ILUSDToken(addresses.lusdTokenAddress);
        lqtyStaking = ILQTYStaking(addresses.lqtyStakingAddress);
        guardian = IGuardian(addresses.guardianAddress);
        communityIssuance = ICommunityIssuance(addresses.communityIssuanceAddress);
        locker = ILocker(addresses.lockerAddress);

        emit AssetConfigManagerAddressChanged(addresses.assetConfigManagerAddress);
        emit GlobalConfigManagerAddressChanged(addresses.globalConfigManagerAddress);
        emit TroveManagerAddressChanged(addresses.troveManagerAddress);
        emit ActivePoolAddressChanged(addresses.activePoolAddress);
        emit GasPoolAddressChanged(addresses.gasPoolAddress);
        emit CollSurplusPoolAddressChanged(addresses.collSurplusPoolAddress);
        emit ReservePoolAddressChanged(addresses.reservePoolAddress);
        emit LUSDTokenAddressChanged(addresses.lusdTokenAddress);
        emit LQTYStakingAddressChanged(addresses.lqtyStakingAddress);
        emit GuardianAddressChanged(addresses.guardianAddress);
        emit CommunityIssuanceAddressChanged(addresses.communityIssuanceAddress);
        emit LockerAddressChanged(addresses.lockerAddress);
    }

    // --- Redemption functions ---

    // Redeem as much collateral as possible from _borrower's Trove in exchange for LUSD up to _maxLUSDamount
    function _redeemCollateralFromTrove(
        ContractsCache memory _contractsCache,
        address _borrower,
        DataTypes.AssetConfig memory _assetConfig,
        RedeemTroveValues memory val
    ) internal returns (SingleRedemptionValues memory singleRedemption) {
        (singleRedemption.debt, singleRedemption.coll) = _contractsCache.troveManager.getTroveDebtAndColl(
            _borrower,
            _assetConfig.asset
        );
        singleRedemption.gasCompensation = _contractsCache.troveManager.getTroveGasCompensation(
            _borrower,
            _assetConfig.asset
        );
        // Determine the remaining amount (lot) to be redeemed, capped by the entire debt of the Trove minus the liquidation reserve
        singleRedemption.LUSDLot = LiquityMath._min(
            val.maxLUSDamount,
            singleRedemption.debt.sub(singleRedemption.gasCompensation)
        );

        // Get the CollLot of equivalent value in USD
        singleRedemption.CollLot = LiquityMath._scaleToCollDecimals(
            singleRedemption.LUSDLot.mul(DECIMAL_PRECISION).div(val.price),
            _assetConfig.decimals
        );

        // Decrease the debt and collateral of the current Trove according to the LUSD lot and corresponding coll to send
        singleRedemption.newDebt = (singleRedemption.debt).sub(singleRedemption.LUSDLot);
        singleRedemption.newColl = (singleRedemption.coll).sub(singleRedemption.CollLot);

        if (singleRedemption.newDebt == singleRedemption.gasCompensation) {
            // No debt left in the Trove (except for the liquidation reserve), therefore the trove gets closed
            singleRedemption.gasCompensationLot = singleRedemption.gasCompensation;
            singleRedemption.collSurplus = singleRedemption.newColl;
            _contractsCache.troveManager.closeTrove(
                _borrower,
                _assetConfig.asset,
                0,
                0,
                ITroveManagerV2.Status.closedByRedemption,
                ITroveManagerV2.TroveOperations.closeByRedemption
            );

            /*
             * In order to close the trove, the LUSD liquidation reserve is burned, and the corresponding debt is removed from the active pool.
             * The debt recorded on the trove's struct is zero'd elswhere, in closeTrove.
             * Any surplus coll left in the trove, is sent to the Coll surplus pool, and can be later claimed by the borrower.
             * real token transfer will be done together after all redemptions finish to save gas
             */
            _contractsCache.collSurplusPool.accountSurplus(_borrower, _assetConfig.asset, singleRedemption.newColl);

            emit TroveRedeemed(
                _assetConfig.asset,
                _borrower,
                singleRedemption.LUSDLot,
                singleRedemption.CollLot,
                0,
                0
            );
        } else {
            singleRedemption.gasCompensationLot = 0;

            /*
             * If the provided hint is out of date, we bail since trying to reinsert without a good hint will almost
             * certainly result in running out of gas.
             *
             * If the resultant net debt of the partial is less than the minimum, net debt we bail.
             */
            uint NICR = _contractsCache.troveManager.computeNominalICR(_assetConfig.asset, singleRedemption.newColl, singleRedemption.newDebt);
            if (
                NICR.mul(DECIMAL_PRECISION) < val.partialRedemptionHintNICR.mul(hintPartialNICRFactorFloor) ||
                singleRedemption.newDebt.sub(singleRedemption.gasCompensation) < _assetConfig.riskParams.minDebt
            ) {
                singleRedemption.cancelledPartial = true;
                return singleRedemption;
            }

            _contractsCache.troveManager.adjustTrove(
                _borrower,
                _assetConfig.asset,
                singleRedemption.CollLot,
                false,
                singleRedemption.LUSDLot,
                false,
                val.price,
                val.upperPartialRedemptionHint,
                val.lowerPartialRedemptionHint,
                ITroveManagerV2.TroveOperations.adjustByRedemption
            );

            // partial redepmtion since newDebt and newColl are not 0
            emit TroveRedeemed(
                _assetConfig.asset,
                _borrower,
                singleRedemption.LUSDLot,
                singleRedemption.CollLot,
                singleRedemption.newDebt,
                singleRedemption.newColl
            );
        }

        return singleRedemption;
    }

    function _getRedemptionFee(
        DataTypes.AssetConfig memory _assetConfig,
        uint256 _price,
        uint256 LUSDToRedeem
    ) internal returns (uint256, uint256, uint256) {
        uint256 redemptionRate = IFeeRateModel(_assetConfig.feeRateModelAddress).calcRedeemRate(
            _assetConfig.asset,
            _price,
            LUSDToRedeem
        );
        uint256 redemptionFee = redemptionRate.mul(LUSDToRedeem).div(DECIMAL_PRECISION);
        require(redemptionFee < LUSDToRedeem, "RedeemerOperations: Fee would eat up all LUSD");

        uint256 reserveAmount = _assetConfig.reserveFactor.mul(redemptionFee).div(DECIMAL_PRECISION);
        return (redemptionFee.sub(reserveAmount), reserveAmount, redemptionFee);
    }

    /* Send _LUSDamount LUSD to the system and redeem the corresponding amount of collateral from as many Troves as are needed to fill the redemption
     * request.  Applies pending rewards to a Trove before reducing its debt and coll.
     *
     * Note that if _amount is very large, this function can run out of gas, specially if traversed troves are small. This can be easily avoided by
     * splitting the total _amount in appropriate chunks and calling the function multiple times.
     *
     * Param `_maxIterations` can also be provided, so the loop through Troves is capped (if it’s zero, it will be ignored).This makes it easier to
     * avoid OOG for the frontend, as only knowing approximately the average cost of an iteration is enough, without needing to know the “topology”
     * of the trove list. It also avoids the need to set the cap in stone in the contract, nor doing gas calculations, as both gas price and opcode
     * costs can vary.
     *
     * All Troves that are redeemed from -- with the likely exception of the last one -- will end up with no debt left, therefore they will be closed.
     * If the last Trove does have some remaining debt, it has a finite ICR, and the reinsertion could be anywhere in the list, therefore it requires a hint.
     * A frontend should use getRedemptionHints() to calculate what the ICR of this Trove will be after redemption, and pass a hint for its position
     * in the sortedTroves list along with the ICR value that the hint was found for.
     *
     * If another transaction modifies the list between calling getRedemptionHints() and passing the hints to redeemCollateral(), it
     * is very likely that the last (partially) redeemed Trove would end up with a different ICR than what the hint is for. In this case the
     * redemption will stop after the last completely redeemed Trove and the sender will keep the remaining LUSD amount, which they can attempt
     * to redeem later.
     */
    function redeemCollateral(
        address _asset,
        uint256 _LUSDamount,
        address _firstRedemptionHint,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint256 _partialRedemptionHintNICR,
        uint256 _maxIterations,
        uint256 _maxFeePercentage
    ) external override notLocked guardianAllowed(_asset, 0x8dff0459) {
        ContractsCache memory contractsCache = ContractsCache(
            assetConfigManager,
            globalConfigManager,
            troveManager,
            activePool,
            lusdToken,
            lqtyStaking,
            collSurplusPool,
            reservePool,
            gasPoolAddress
        );
        RedemptionTotals memory totals;
        DataTypes.AssetConfig memory assetConfig = contractsCache.assetConfigManager.get(_asset);

        _requireValidMaxFeePercentage(assetConfig.feeRateParams, _maxFeePercentage);
        _requireAfterBootstrapPeriod(assetConfig);
        totals.price = IPriceFeed(assetConfig.priceOracleAddress).fetchPrice(_asset);
        _requireTCRoverMCR(contractsCache.troveManager, assetConfig, totals.price);
        _requireAmountGreaterThanZero(_LUSDamount);
        _requireLUSDBalanceCoversRedemption(contractsCache.lusdToken, msg.sender, _LUSDamount);

        totals.remainingLUSD = _LUSDamount;

        // Loop through the Troves starting from the one with lowest collateral ratio until _amount of LUSD is exchanged for collateral
        if (_maxIterations == 0) {
            _maxIterations = totals.remainingLUSD.div(assetConfig.riskParams.minDebt).add(1);
        }
        address[] memory troveArray = contractsCache.troveManager.getLastNTrovesAboveMCR(
            _asset,
            _maxIterations,
            _firstRedemptionHint,
            totals.price
        );

        for (uint256 i = 0; i < troveArray.length && totals.remainingLUSD > 0; i++) {
            RedeemTroveValues memory val = RedeemTroveValues(
                totals.remainingLUSD,
                totals.price,
                _upperPartialRedemptionHint,
                _lowerPartialRedemptionHint,
                _partialRedemptionHintNICR
            );

            SingleRedemptionValues memory singleRedemption = _redeemCollateralFromTrove(
                contractsCache,
                troveArray[i],
                assetConfig,
                val
            );

            if (singleRedemption.cancelledPartial) break; // Partial redemption was cancelled (out-of-date hint, or new net debt < minimum), therefore we could not redeem from the last Trove

            totals.totalGasCompensation = totals.totalGasCompensation.add(
                singleRedemption.gasCompensationLot
            );
            totals.totalCollSurplus = totals.totalCollSurplus.add(singleRedemption.collSurplus);
            totals.totalLUSDToRedeem = totals.totalLUSDToRedeem.add(singleRedemption.LUSDLot);
            totals.totalCollDrawn = totals.totalCollDrawn.add(singleRedemption.CollLot);

            totals.remainingLUSD = totals.remainingLUSD.sub(singleRedemption.LUSDLot);
        }

        require(totals.totalCollDrawn > 0, "RedeemerOperations: Unable to redeem any amount");

        // Calculate the redemption fee
        (totals.stakingRewardAmount, totals.reserveAmount, totals.LUSDFee) = _getRedemptionFee(assetConfig, totals.price, totals.totalLUSDToRedeem);

        _requireUserAcceptsFee(totals.LUSDFee, totals.totalLUSDToRedeem, _maxFeePercentage);
        _requireLUSDBalanceCoversRedemption(
            contractsCache.lusdToken,
            msg.sender,
            totals.totalLUSDToRedeem.add(totals.LUSDFee)
        );

        // Send the lusd redemption fee to the LQTY staking contract
        contractsCache.lusdToken.sendToPool(
            msg.sender,
            address(contractsCache.lqtyStaking),
            totals.stakingRewardAmount
        );
        contractsCache.lqtyStaking.increaseF(totals.stakingRewardAmount);

        // send the reserve amount to reservePool
        contractsCache.lusdToken.sendToPool(
            msg.sender,
            address(contractsCache.reservePool),
            totals.reserveAmount
        );
        contractsCache.reservePool.depositLUSD(_asset, totals.reserveAmount);

        emit Redemption(
            _asset,
            _LUSDamount,
            totals.totalLUSDToRedeem,
            totals.totalCollDrawn,
            totals.stakingRewardAmount,
            totals.reserveAmount,
            totals.LUSDFee
        );

        // Burn gas compensation of troves closed by redemption
        contractsCache.lusdToken.burn(gasPoolAddress, totals.totalGasCompensation);
        // send coll from Active Pool to CollSurplus Pool
        if (assetConfig.farmerAddress != address(0)) {
            IFarmer(assetConfig.farmerAddress).sendAssetToPool(_asset, address(contractsCache.collSurplusPool), totals.totalCollSurplus);
        } else {
            contractsCache.activePool.sendAssetToPool(
                _asset,
                address(contractsCache.collSurplusPool),
                totals.totalCollSurplus
            );
        }

        // Burn the total LUSD that is cancelled with debt, and send the redeemed coll to msg.sender
        contractsCache.lusdToken.burn(msg.sender, totals.totalLUSDToRedeem);
        if (assetConfig.farmerAddress != address(0)) {
            IFarmer(assetConfig.farmerAddress).sendAsset(_asset, msg.sender, totals.totalCollDrawn);
        } else {
            contractsCache.activePool.sendAsset(_asset, msg.sender, totals.totalCollDrawn);
        }
    }

    // --- 'require' wrapper functions ---
    function _requireLUSDBalanceCoversRedemption(
        ILUSDToken _lusdToken,
        address _redeemer,
        uint256 _amount
    ) internal view {
        require(
            _lusdToken.balanceOf(_redeemer) >= _amount,
            "RedeemerOperations: Requested redemption amount must be <= user's token balance"
        );
    }

    function _requireAmountGreaterThanZero(uint256 _amount) internal pure {
        require(_amount > 0, "RedeemerOperations: Amount must be greater than zero");
    }

    function _requireTCRoverMCR(
        ITroveManagerV2 _troveManager,
        DataTypes.AssetConfig memory _assetConfig,
        uint256 _price
    ) internal view {
        uint256 entireSystemDebt = _troveManager.getEntireSystemDebt(_assetConfig.asset);
        uint256 entireSystemColl = _troveManager.getEntireSystemColl(_assetConfig.asset);
        require(
            LiquityMath._computeCR(entireSystemColl, _assetConfig.decimals, entireSystemDebt, _price) >= _assetConfig.riskParams.mcr,
            "RedeemerOperations: Cannot redeem when TCR < MCR"
        );
    }

    function _requireAfterBootstrapPeriod(DataTypes.AssetConfig memory _assetConfig) internal view {
        require(
            block.timestamp >= _assetConfig.bootstrapTimestamp,
            "RedeemerOperations: Redemptions are not allowed during bootstrap phase"
        );
    }

    function _requireValidMaxFeePercentage(
        DataTypes.FeeRateParams memory _feeRateParams,
        uint256 _maxFeePercentage
    ) internal pure {
        require(
            _maxFeePercentage >= _feeRateParams.redeemFeeRateFloor &&
                _maxFeePercentage <= DECIMAL_PRECISION,
            "Max fee percentage must be between 0.5% and 100%"
        );
    }

    function _requireUserAcceptsFee(
        uint256 _fee,
        uint256 _amount,
        uint256 _maxFeePercentage
    ) internal pure {
        uint256 feePercentage = _fee.mul(DECIMAL_PRECISION).div(_amount);
        require(feePercentage <= _maxFeePercentage, "Fee exceeded provided maximum");
    }
}
