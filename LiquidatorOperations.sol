// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "./Interfaces/IActivePool.sol";
import "./Interfaces/IAssetConfigManager.sol";
import "./Interfaces/IFarmer.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/ICommunityIssuance.sol";
import "./Interfaces/IGlobalConfigManager.sol";
import "./Interfaces/IGuardian.sol";
import "./Interfaces/ILiquidatorOperations.sol";
import "./Interfaces/ILUSDToken.sol";
import "./Interfaces/IPriceFeed.sol";
import "./Interfaces/IStabilityPool.sol";
import "./Interfaces/ITroveManagerV2.sol";
import "./Dependencies/MultiAssetInitializable.sol";
import "./Dependencies/BaseMath.sol";
import "./Dependencies/Guardable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/OwnableUpgradeable.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/LiquityMath.sol";
import "./Dependencies/Lockable.sol";

contract LiquidatorOperations is BaseMath, CheckContract, OwnableUpgradeable, Guardable, Lockable, ILiquidatorOperations {

    using SafeMath for uint;

    struct ContractsCache {
        ITroveManagerV2 troveManager;
        IActivePool activePool;
        IStabilityPool stabilityPool;
        ICollSurplusPool collSurplusPool;
        ILUSDToken lusdToken;
        IAssetConfigManager assetConfigManager;
        IGlobalConfigManager globalConfigManager;
    }

    struct LocalVariables_OuterLiquidationFunction {
        uint price;
        uint LUSDInStabPool;
        bool recoveryModeAtStart;
        uint liquidatedDebt;
        uint liquidatedColl;
    }

    struct LiquidationValues {
        uint entireTroveDebt;
        uint entireTroveColl;
        uint collGasCompensation;
        uint LUSDGasCompensation;
        uint debtToOffset;
        uint collToSendToSP;
        uint debtToRedistribute;
        uint collToRedistribute;
        uint collSurplus;
    }

    struct LiquidationTotals {
        uint totalCollInSequence;
        uint totalDebtInSequence;
        uint totalCollGasCompensation;
        uint totalLUSDGasCompensation;
        uint totalDebtToOffset;
        uint totalCollToSendToSP;
        uint totalDebtToRedistribute;
        uint totalCollToRedistribute;
        uint totalCollSurplus;
    }

    struct LocalVariables_LiquidationSequence {
        uint remainingLUSDInStabPool;
        uint i;
        uint ICR;
        address user;
        bool backToNormalMode;
        uint entireSystemDebt;
        uint entireSystemColl;
    }

    struct LocalVariables_InnerSingleLiquidateFunction {
        uint collToLiquidate;
        uint pendingDebtReward;
        uint pendingCollReward;
    }

    ITroveManagerV2 public troveManager;

    IActivePool public activePool;

    IStabilityPool public stabilityPool;

    address public gasPoolAddress;

    ICollSurplusPool public collSurplusPool;

    ILUSDToken public lusdToken;

    IAssetConfigManager public assetConfigManager;

    IGlobalConfigManager public globalConfigManager;

    ICommunityIssuance public communityIssuance;

    function initialize() public initializer {
        __Ownable_init();
    }

    function setAddresses(
        ContractAddresses memory addresses
    )
        external
        override
        onlyOwner
    {
        require(address(troveManager) == address(0), "address has already been set");

        checkContract(addresses.troveManagerAddress);
        checkContract(addresses.activePoolAddress);
        checkContract(addresses.stabilityPoolAddress);
        checkContract(addresses.gasPoolAddress);
        checkContract(addresses.collSurplusPoolAddress);
        checkContract(addresses.lusdTokenAddress);
        checkContract(addresses.assetConfigManagerAddress);
        checkContract(addresses.globalConfigManagerAddress);
        checkContract(addresses.guardianAddress);
        checkContract(addresses.communityIssuanceAddress);
        checkContract(addresses.lockerAddress);

        troveManager = ITroveManagerV2(addresses.troveManagerAddress);
        activePool = IActivePool(addresses.activePoolAddress);
        stabilityPool = IStabilityPool(addresses.stabilityPoolAddress);
        gasPoolAddress = addresses.gasPoolAddress;
        collSurplusPool = ICollSurplusPool(addresses.collSurplusPoolAddress);
        lusdToken = ILUSDToken(addresses.lusdTokenAddress);
        assetConfigManager = IAssetConfigManager(addresses.assetConfigManagerAddress);
        globalConfigManager = IGlobalConfigManager(addresses.globalConfigManagerAddress);
        guardian = IGuardian(addresses.guardianAddress);
        communityIssuance = ICommunityIssuance(addresses.communityIssuanceAddress);
        locker = ILocker(addresses.lockerAddress);

        emit TroveManagerAddressChanged(addresses.troveManagerAddress);
        emit ActivePoolAddressChanged(addresses.activePoolAddress);
        emit StabilityPoolAddressChanged(addresses.stabilityPoolAddress);
        emit GasPoolAddressChanged(addresses.gasPoolAddress);
        emit CollSurplusPoolAddressChanged(addresses.collSurplusPoolAddress);
        emit LUSDTokenAddressChanged(addresses.lusdTokenAddress);
        emit AssetConfigManagerAddressChanged(addresses.assetConfigManagerAddress);
        emit GlobalConfigManagerAddressChanged(addresses.globalConfigManagerAddress);
        emit GuardianAddressChanged(addresses.guardianAddress);
        emit CommunityIssuanceAddressChanged(addresses.communityIssuanceAddress);
        emit LockerAddressChanged(addresses.lockerAddress);
    }

    function liquidate(
        address _borrower,
        address _asset
    )
        external
        notLocked
        guardianAllowed(_asset, 0x3ed3015b)
        override
    {
        _requireTroveIsActive(_borrower, _asset);

        address[] memory borrowers = new address[](1);
        borrowers[0] = _borrower;
        batchLiquidateTroves(_asset, borrowers);
    }

    function liquidateTroves(
        address _asset,
        uint _n
    )
        external
        notLocked
        guardianAllowed(_asset, 0xc4fe9ac4)
        override
    {
        require(_n > 0, "nothing to liquidate");
        address[] memory owners = troveManager.getLastNTroveOwners(_asset, _n);
        batchLiquidateTroves(_asset, owners);
    }

    function batchLiquidateTroves(
        address _asset,
        address[] memory _troveArray
    )
        public
        notLocked
        guardianAllowed(_asset, 0x8d7a57a1)
        override
    {
        require(_troveArray.length != 0, "LiquidatorOperations: Calldata address array must not be empty");

        ContractsCache memory cache = ContractsCache(
            troveManager,
            activePool,
            stabilityPool,
            collSurplusPool,
            lusdToken,
            assetConfigManager,
            globalConfigManager
        );

        LocalVariables_OuterLiquidationFunction memory vars;
        LiquidationTotals memory totals;

        DataTypes.AssetConfig memory config = cache.assetConfigManager.get(_asset);

        vars.price = IPriceFeed(config.priceOracleAddress).fetchPrice(_asset);
        vars.recoveryModeAtStart = cache.troveManager.checkRecoveryMode(_asset, vars.price);

        // Perform the appropriate liquidation sequence - tally values and obtain their totals.
        if (vars.recoveryModeAtStart) {
            totals = _getLiquidationTotalsInRecoveryMode(
                cache,
                config,
                vars.price,
                _troveArray
            );
        } else {  //  if !vars.recoveryModeAtStart
            totals = _getLiquidationTotalsInNormalMode(
                cache,
                config,
                vars.price,
                _troveArray
            );
        }

        require(totals.totalDebtInSequence > 0, "LiquidatorOperations: nothing to liquidate");

        vars.liquidatedDebt = totals.totalDebtInSequence;
        vars.liquidatedColl = totals.totalCollInSequence.sub(totals.totalCollGasCompensation).sub(totals.totalCollSurplus);
        emit Liquidation(
            _asset,
            vars.liquidatedDebt,
            vars.liquidatedColl,
            totals.totalCollGasCompensation,
            totals.totalLUSDGasCompensation
        );

        _moveAssetAndDebtOnLiquidation(cache, totals, config);
    }

    function _getLiquidationTotalsInRecoveryMode
    (
        ContractsCache memory _cache,
        DataTypes.AssetConfig memory _config,
        uint _price,
        address[] memory _troveArray
    )
        internal
        returns(LiquidationTotals memory totals)
    {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;

        address _asset = _config.asset;
        uint MCR = _config.riskParams.mcr;

        vars.remainingLUSDInStabPool = _cache.stabilityPool.getTotalLUSDDeposits(_asset);
        vars.backToNormalMode = false;
        vars.entireSystemDebt = _cache.troveManager.getEntireSystemDebt(_asset);
        vars.entireSystemColl = _cache.troveManager.getEntireSystemColl(_asset);

        for (vars.i = 0; vars.i < _troveArray.length; vars.i++) {
            vars.user = _troveArray[vars.i];
            // Skip non-active troves
            if (_cache.troveManager.getTroveStatus(vars.user, _asset) != 1) { continue; }
            vars.ICR = _cache.troveManager.getCurrentICR(vars.user, _asset, _price);

            if (!vars.backToNormalMode) {

                // Skip this trove if ICR is greater than MCR and Stability Pool is empty
                if (vars.ICR >= MCR && vars.remainingLUSDInStabPool == 0) { continue; }

                uint TCR = LiquityMath._computeCR(vars.entireSystemColl, _config.decimals, vars.entireSystemDebt, _price);

                singleLiquidation = _liquidateRecoveryMode(
                    _cache,
                    vars.user,
                    _asset,
                    vars.ICR,
                    vars.remainingLUSDInStabPool,
                    TCR,
                    _price
                );

                // Update aggregate trackers
                vars.remainingLUSDInStabPool = vars.remainingLUSDInStabPool.sub(singleLiquidation.debtToOffset);
                vars.entireSystemDebt = _cache.troveManager.getEntireSystemDebt(_asset);
                vars.entireSystemColl = _cache.troveManager.getEntireSystemColl(_asset);

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

                vars.backToNormalMode = !_checkPotentialRecoveryMode(
                    vars.entireSystemColl,
                    _config.decimals,
                    vars.entireSystemDebt,
                    _price,
                    _config.riskParams.ccr
                );
            }

            else if (vars.backToNormalMode && vars.ICR < MCR) {
                singleLiquidation = _liquidateNormalMode(
                    _cache,
                    vars.user,
                    _asset,
                    vars.remainingLUSDInStabPool
                );

                // Update aggregate trackers
                vars.remainingLUSDInStabPool = vars.remainingLUSDInStabPool.sub(singleLiquidation.debtToOffset);

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

            } else continue; // In Normal Mode skip troves with ICR >= MCR
        }
    }

    function _getLiquidationTotalsInNormalMode
    (
        ContractsCache memory _cache,
        DataTypes.AssetConfig memory _config,
        uint _price,
        address[] memory _troveArray
    )
        internal
        returns(LiquidationTotals memory totals)
    {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;

        address _asset = _config.asset;

        vars.remainingLUSDInStabPool = _cache.stabilityPool.getTotalLUSDDeposits(_asset);
        uint MCR = _config.riskParams.mcr;

        for (vars.i = 0; vars.i < _troveArray.length; vars.i++) {
            vars.user = _troveArray[vars.i];
            vars.ICR = _cache.troveManager.getCurrentICR(vars.user, _asset, _price);

            if (vars.ICR < MCR) {
                singleLiquidation = _liquidateNormalMode(_cache, vars.user, _asset, vars.remainingLUSDInStabPool);

                // Update aggregate trackers
                vars.remainingLUSDInStabPool = vars.remainingLUSDInStabPool.sub(singleLiquidation.debtToOffset);

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
            }
        }
    }

    function _moveAssetAndDebtOnLiquidation(
        ContractsCache memory _cache,
        LiquidationTotals memory _totals,
        DataTypes.AssetConfig memory _config
    )
        internal
    {
        address _asset = _config.asset;
        // burn LUSD from SP and transfer corresponding collateral to SP
        _cache.stabilityPool.offset(_asset, _totals.totalDebtToOffset, _totals.totalCollToSendToSP);

        // transfer remaining collateral to collSurplusPool
        if (_totals.totalCollSurplus > 0) {
            if (_config.farmerAddress != address(0)) {
                IFarmer(_config.farmerAddress).sendAssetToPool(_asset, address(_cache.collSurplusPool), _totals.totalCollSurplus);
            } else {
                _cache.activePool.sendAssetToPool(_asset, address(_cache.collSurplusPool), _totals.totalCollSurplus);
            }
        }

        // transfer LUSD & collateral to liquidator
        if (_totals.totalLUSDGasCompensation > 0) {
            _cache.lusdToken.returnFromPool(gasPoolAddress, msg.sender, _totals.totalLUSDGasCompensation);
        }

        if (_totals.totalCollGasCompensation > 0) {
            if (_config.farmerAddress != address(0)) {
                IFarmer(_config.farmerAddress).sendAsset(_asset, msg.sender, _totals.totalCollGasCompensation);
            } else {
                _cache.activePool.sendAsset(_asset, msg.sender, _totals.totalCollGasCompensation);
            }
        }
    }

    function _liquidateNormalMode(
        ContractsCache memory _cache,
        address _borrower,
        address _asset,
        uint _LUSDInStabPool
    )
        internal
        returns (LiquidationValues memory singleLiquidation)
    {
        singleLiquidation = _getOffsetAndRedistributionVals(_cache, _borrower, _asset, _LUSDInStabPool);

        _cache.troveManager.closeTrove(
            _borrower,
            _asset,
            singleLiquidation.collToRedistribute,
            singleLiquidation.debtToRedistribute,
            ITroveManagerV2.Status.closedByLiquidation,
            ITroveManagerV2.TroveOperations.liquidateInNormalMode
        );

        emit TroveLiquidated(
            _asset,
            _borrower,
            singleLiquidation.entireTroveDebt,
            singleLiquidation.collToSendToSP,
            LiquidationMode.NORMAL
        );
    }

    function _liquidateRecoveryMode(
        ContractsCache memory _cache,
        address _borrower,
        address _asset,
        uint _ICR,
        uint _LUSDInStabPool,
        uint _TCR,
        uint _price
    )
        internal
        returns (LiquidationValues memory singleLiquidation)
    {

        // don't liquidate if last trove
        if (_cache.troveManager.getTroveOwnersCount(_asset) <= 1) { return singleLiquidation; }

        uint MCR = _cache.assetConfigManager.get(_asset).riskParams.mcr;

        if (_ICR <= _100pct) {
            // If ICR <= 100%, purely redistribute the Trove across all active Troves
            singleLiquidation = _getFullRedistributionVals(_cache, _borrower, _asset);
        } else if ((_ICR > _100pct) && (_ICR < MCR)) {
            // If 100% < ICR < MCR, offset as much as possible, and redistribute the remainder
            singleLiquidation = _getOffsetAndRedistributionVals(_cache, _borrower, _asset, _LUSDInStabPool);
        } else if ((_ICR >= MCR) && (_ICR < _TCR)) {
            uint entireTroveDebt = _cache.troveManager.getTroveDebt(_borrower, _asset);
            if (entireTroveDebt <= _LUSDInStabPool) {
                /*
                 * If 110% <= ICR < current TCR (accounting for the preceding liquidations in the current sequence)
                 * and there is LUSD in the Stability Pool, only offset, with no redistribution,
                 * but at a capped rate of 1.1 and only if the whole debt can be liquidated.
                 * The remainder due to the capped rate will be claimable as collateral surplus.
                 */
                singleLiquidation = _getCappedOffsetVals(_cache, _borrower, _asset, _price);
                if (singleLiquidation.collSurplus > 0) {
                    _cache.collSurplusPool.accountSurplus(_borrower, _asset, singleLiquidation.collSurplus);
                }
            }
        }

        if (singleLiquidation.debtToOffset > 0 || singleLiquidation.debtToRedistribute > 0) { // liquidation occurred
            _cache.troveManager.closeTrove(
                _borrower,
                _asset,
                singleLiquidation.collToRedistribute,
                singleLiquidation.debtToRedistribute,
                ITroveManagerV2.Status.closedByLiquidation,
                ITroveManagerV2.TroveOperations.liquidateInRecoveryMode
            );

            emit TroveLiquidated(
                _asset,
                _borrower,
                singleLiquidation.entireTroveDebt,
                singleLiquidation.collToSendToSP,
                LiquidationMode.RECOVERY
            );
        }

        return singleLiquidation;
    }

    // fully redistribute debt & collateral
    function _getFullRedistributionVals(
        ContractsCache memory _cache,
        address _borrower,
        address _asset
    )
        internal
        view
        returns (LiquidationValues memory lv)
    {
        lv.entireTroveColl = _cache.troveManager.getTroveColl(_borrower, _asset);
        lv.entireTroveDebt = _cache.troveManager.getTroveDebt(_borrower, _asset);
        DataTypes.AssetConfig memory _config = _cache.assetConfigManager.get(_asset);
        lv.collGasCompensation = lv.entireTroveColl.div(_config.liquidationBonusDivisor);
        lv.LUSDGasCompensation = _cache.troveManager.getTroveGasCompensation(_borrower, _asset);
        lv.debtToOffset = 0;
        lv.collToSendToSP = 0;
        lv.debtToRedistribute = lv.entireTroveDebt;
        lv.collToRedistribute = lv.entireTroveColl.sub(lv.collGasCompensation);
    }

    // Offset as much debt & collateral as possible against the Stability Pool, and redistribute the remainder
    function _getOffsetAndRedistributionVals(
        ContractsCache memory _cache,
        address _borrower,
        address _asset,
        uint _LUSDInStabPool
    )
        internal
        view
        returns (LiquidationValues memory lv)
    {
        lv.entireTroveColl = _cache.troveManager.getTroveColl(_borrower, _asset);
        lv.entireTroveDebt = _cache.troveManager.getTroveDebt(_borrower, _asset);
        DataTypes.AssetConfig memory _config = _cache.assetConfigManager.get(_asset);
        lv.collGasCompensation = lv.entireTroveColl.div(_config.liquidationBonusDivisor);
        lv.LUSDGasCompensation = _cache.troveManager.getTroveGasCompensation(_borrower, _asset);
        uint collsToLiquidate = lv.entireTroveColl.sub(lv.collGasCompensation);

        if (_LUSDInStabPool > 0) {
            lv.debtToOffset = LiquityMath._min(lv.entireTroveDebt, _LUSDInStabPool);
            lv.collToSendToSP = collsToLiquidate.mul(lv.debtToOffset).div(lv.entireTroveDebt);
            lv.debtToRedistribute = lv.entireTroveDebt.sub(lv.debtToOffset);
            lv.collToRedistribute = collsToLiquidate.sub(lv.collToSendToSP);
        } else {
            lv.debtToOffset = 0;
            lv.collToSendToSP = 0;
            lv.debtToRedistribute = lv.entireTroveDebt;
            lv.collToRedistribute = collsToLiquidate;
        }
    }

    // Offset at a capped rate of 1.1 and the remainder will be claimable.
    function _getCappedOffsetVals
    (
        ContractsCache memory _cache,
        address _borrower,
        address _asset,
        uint _price
    )
        internal
        view
        returns (LiquidationValues memory lv)
    {
        lv.entireTroveColl = _cache.troveManager.getTroveColl(_borrower, _asset);
        lv.entireTroveDebt = _cache.troveManager.getTroveDebt(_borrower, _asset);

        DataTypes.AssetConfig memory _config = _cache.assetConfigManager.get(_asset);
        uint collToOffset = LiquityMath._scaleToCollDecimals(lv.entireTroveDebt.mul(_config.riskParams.mcr).div(_price), _config.decimals);

        lv.collGasCompensation = collToOffset.div(_config.liquidationBonusDivisor);
        lv.LUSDGasCompensation = _cache.troveManager.getTroveGasCompensation(_borrower, _asset);
        lv.debtToOffset = lv.entireTroveDebt;
        lv.collToSendToSP = collToOffset.sub(lv.collGasCompensation);
        lv.collSurplus = lv.entireTroveColl.sub(collToOffset);
        lv.debtToRedistribute = 0;
        lv.collToRedistribute = 0;
    }

    function _addLiquidationValuesToTotals(
        LiquidationTotals memory oldTotals,
        LiquidationValues memory singleLiquidation
    )
        internal
        pure
        returns(LiquidationTotals memory newTotals)
    {
        // Tally all the values with their respective running totals
        newTotals.totalCollGasCompensation = oldTotals.totalCollGasCompensation.add(singleLiquidation.collGasCompensation);
        newTotals.totalLUSDGasCompensation = oldTotals.totalLUSDGasCompensation.add(singleLiquidation.LUSDGasCompensation);
        newTotals.totalDebtInSequence = oldTotals.totalDebtInSequence.add(singleLiquidation.entireTroveDebt);
        newTotals.totalCollInSequence = oldTotals.totalCollInSequence.add(singleLiquidation.entireTroveColl);
        newTotals.totalDebtToOffset = oldTotals.totalDebtToOffset.add(singleLiquidation.debtToOffset);
        newTotals.totalCollToSendToSP = oldTotals.totalCollToSendToSP.add(singleLiquidation.collToSendToSP);
        newTotals.totalDebtToRedistribute = oldTotals.totalDebtToRedistribute.add(singleLiquidation.debtToRedistribute);
        newTotals.totalCollToRedistribute = oldTotals.totalCollToRedistribute.add(singleLiquidation.collToRedistribute);
        newTotals.totalCollSurplus = oldTotals.totalCollSurplus.add(singleLiquidation.collSurplus);

        return newTotals;
    }

    function _checkPotentialRecoveryMode(
        uint _entireSystemColl,
        uint _decimals,
        uint _entireSystemDebt,
        uint _price,
        uint _CCR
    )
        internal
        pure
        returns (bool)
    {
        uint TCR = LiquityMath._computeCR(_entireSystemColl, _decimals, _entireSystemDebt, _price);

        return TCR < _CCR;
    }

    function _requireTroveIsActive(address _borrower, address _asset) internal view {
        require(troveManager.getTroveStatus(_borrower, _asset) == 1, "LiquidatorOperations: Trove not active");
    }
}
