// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "./Dependencies/AddressLib.sol";
import "./Dependencies/BaseMath.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/Guardable.sol";
import "./Dependencies/IERC20.sol";
import "./Dependencies/LiquityMath.sol";
import "./Dependencies/OwnableUpgradeable.sol";
import "./Interfaces/IActivePool.sol";
import "./Interfaces/IAssetConfigManager.sol";
import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/IFarmer.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/ICommunityIssuance.sol";
import "./Interfaces/IFeeRateModel.sol";
import "./Interfaces/IGlobalConfigManager.sol";
import "./Interfaces/IPriceFeed.sol";
import "./Interfaces/ILQTYStaking.sol";
import "./Interfaces/ILUSDToken.sol";
import "./Interfaces/IReservePool.sol";
import "./Interfaces/ISortedTroves.sol";
import "./Interfaces/ITroveManagerV2.sol";
import "./TransferHelper.sol";
import "./Interfaces/IFlashLoanReceiver.sol";
import "./Interfaces/IFlashLoanOperations.sol";
import "./Dependencies/Lockable.sol";

contract BorrowerOperations is BaseMath, OwnableUpgradeable, CheckContract, Guardable, Lockable, IBorrowerOperations, IFlashLoanOperations {
    using TransferHelper for address;
    using TransferHelper for IERC20;
    using AddressLib for address;
    using SafeMath for uint;

    string constant public NAME = "BorrowerOperations";

    // --- Connected contract declarations ---

    ITroveManagerV2 public troveManager;

    address public gasPoolAddress;

    ICollSurplusPool public collSurplusPool;

    IReservePool public reservePool;

    ILQTYStaking public lqtyStaking;
    address public lqtyStakingAddress;

    ILUSDToken public lusdToken;

    IActivePool public activePool;

    IAssetConfigManager public assetConfigManager;

    IGlobalConfigManager public globalConfigManager;

    ICommunityIssuance public communityIssuance;

    /* --- Variable container structs  ---

    Used to hold, return and assign variables inside a function, in order to avoid the error:
    "CompilerError: Stack too deep". */
    struct AdjustTroveInputValues {
        address _asset;
        address _borrower;
        uint _collChange;
        bool _isCollIncrease;
        uint _debtChange;
        bool _isDebtIncrease;
        address _upperHint;
        address _lowerHint;
        uint _maxFeePercentage;
    }

    struct LocalVariables_adjustTrove {
        uint price;
        uint netDebtChange;
        uint LUSDFee;
        uint stakingRewardAmount;
        uint reserveAmount;
    }

    struct LocalVariables_openTrove {
        uint price;
        uint LUSDFee;
        uint stakingRewardAmount;
        uint reserveAmount;
        uint netDebt;
        uint compositeDebt;
    }

    struct ContractsCache {
        ITroveManagerV2 troveManager;
        IActivePool activePool;
        ILUSDToken lusdToken;
    }

    struct FlashLoanLocalValues {
        IActivePool activePool;
        address activePoolAddress;
    }

    // --- Dependency setters ---

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
        checkContract(addresses.gasPoolAddress);
        checkContract(addresses.collSurplusPoolAddress);
        checkContract(addresses.reservePoolAddress);
        checkContract(addresses.lusdTokenAddress);
        checkContract(addresses.lqtyStakingAddress);
        checkContract(addresses.assetConfigManagerAddress);
        checkContract(addresses.globalConfigManagerAddress);
        checkContract(addresses.guardianAddress);
        checkContract(addresses.communityIssuanceAddress);
        checkContract(addresses.lockerAddress);

        troveManager = ITroveManagerV2(addresses.troveManagerAddress);
        activePool = IActivePool(addresses.activePoolAddress);
        gasPoolAddress = addresses.gasPoolAddress;
        collSurplusPool = ICollSurplusPool(addresses.collSurplusPoolAddress);
        reservePool = IReservePool(addresses.reservePoolAddress);
        lusdToken = ILUSDToken(addresses.lusdTokenAddress);
        lqtyStakingAddress = addresses.lqtyStakingAddress;
        lqtyStaking = ILQTYStaking(addresses.lqtyStakingAddress);
        assetConfigManager = IAssetConfigManager(addresses.assetConfigManagerAddress);
        globalConfigManager = IGlobalConfigManager(addresses.globalConfigManagerAddress);
        guardian = IGuardian(addresses.guardianAddress);
        communityIssuance = ICommunityIssuance(addresses.communityIssuanceAddress);
        locker = ILocker(addresses.lockerAddress);

        emit TroveManagerAddressChanged(addresses.troveManagerAddress);
        emit ActivePoolAddressChanged(addresses.activePoolAddress);
        emit GasPoolAddressChanged(addresses.gasPoolAddress);
        emit CollSurplusPoolAddressChanged(addresses.collSurplusPoolAddress);
        emit ReservePoolAddressChanged(addresses.reservePoolAddress);
        emit LUSDTokenAddressChanged(addresses.lusdTokenAddress);
        emit LQTYStakingAddressChanged(addresses.lqtyStakingAddress);
        emit AssetConfigManagerAddressChanged(addresses.assetConfigManagerAddress);
        emit GlobalConfigManagerAddressChanged(addresses.globalConfigManagerAddress);
        emit GuardianAddressChanged(addresses.guardianAddress);
        emit CommunityIssuanceAddressChanged(addresses.communityIssuanceAddress);
        emit LockerAddressChanged(addresses.lockerAddress);
    }

    function withdrawTo(address _asset, address _account, uint256 _amount) external onlyOwner override {
        require(_account != address(0), 'can not withdraw to address(0)');
        require(_amount > 0, 'withdraw amount must greater than 0');

        address(_asset).safeTransferToken(_account, _amount);
        emit WithdrawTo(_asset, _account, msg.sender, _amount);
    }

    // --- Flash loan Operations ---
    function flashLoan(address _receiver, address _asset, uint256 _amount, bytes calldata _params)
        external
        notLocked
        guardianAllowed(_asset, 0x4d0b303e)
        mutex
        override
    {
        FlashLoanLocalValues memory lvs = FlashLoanLocalValues(activePool, address(activePool));

        DataTypes.AssetConfig memory config = assetConfigManager.get(_asset);

        bool isFarming = config.farmerAddress != address(0);
        uint256 _balanceBefore = isFarming ?
                                 address(_asset).balanceOf(config.farmerAddress) :
                                 address(_asset).balanceOf(lvs.activePoolAddress);
        // asset amount in masterChef
        uint256 _assetBalanceBefore = isFarming ? IFarmer(config.farmerAddress).balanceOfAsset(_asset) : 0;
        require(_balanceBefore.add(_assetBalanceBefore) >= _amount, "has no enough amount of asset for flash loan");

        uint256 _fee = _amount.div(assetConfigManager.get(_asset).flashLoanFeeDivisor);
        if (isFarming) {
            IFarmer(config.farmerAddress).issueRewards(_asset, address(0));
            IFarmer(config.farmerAddress).sendAsset(_asset, _receiver, _amount);
            IFlashLoanReceiver(_receiver).executeOperation(_asset, _amount, _fee, config.farmerAddress, _params);
            uint256 _assetBalanceAfter = IFarmer(config.farmerAddress).balanceOfAsset(_asset);
            require(_assetBalanceAfter <= _assetBalanceBefore, "asset balanceAfter is greater than before");
            // deposit the withdraw asset back
            if (_assetBalanceBefore > _assetBalanceAfter) {
                IFarmer(config.farmerAddress).deposit(_asset, _assetBalanceBefore.sub(_assetBalanceAfter));
                require(_assetBalanceBefore == IFarmer(config.farmerAddress).balanceOfAsset(_asset), "balance in farmer not equals");
            }
        } else {
            lvs.activePool.sendAsset(_asset, _receiver, _amount);
            IFlashLoanReceiver(_receiver).executeOperation(_asset, _amount, _fee, lvs.activePoolAddress, _params);
        }

        uint256 _balanceAfter = isFarming ?
                                address(_asset).balanceOf(config.farmerAddress) :
                                address(_asset).balanceOf(lvs.activePoolAddress);
        require(_balanceAfter >= _balanceBefore.add(_fee), "flash loan not repay the debt");

        uint256 _realFee = _balanceAfter.sub(_balanceBefore);

        if (isFarming) {
            IFarmer(config.farmerAddress).sendAsset(_asset, address(reservePool), _realFee);
        } else {
            lvs.activePool.sendAsset(_asset, address(reservePool), _realFee);
        }

        reservePool.depositAsset(_asset, _realFee);
        emit FlashLoan(_receiver, _asset, _amount, _fee, _realFee);
    }

    // --- Borrower Trove Operations ---
    function _openTrove(address _asset, address _borrower, uint _maxFeePercentage, uint _collAmount, uint _LUSDAmount, address _upperHint, address _lowerHint) internal {
        ContractsCache memory contractsCache = ContractsCache(troveManager, activePool, lusdToken);
        LocalVariables_openTrove memory vars;

        DataTypes.AssetConfig memory config = assetConfigManager.get(_asset);
        _requireNotExceedCollateralCap(contractsCache.troveManager, config, _collAmount);
        vars.price = IPriceFeed(config.priceOracleAddress).fetchPrice(_asset);
        bool isRecoveryMode = contractsCache.troveManager.checkRecoveryMode(_asset, vars.price);

        _requireValidMaxFeePercentage(config, _maxFeePercentage, isRecoveryMode);

        vars.netDebt = _LUSDAmount;

        if (!isRecoveryMode) {
            (vars.stakingRewardAmount, vars.reserveAmount, vars.LUSDFee) = _triggerBorrowingFee(contractsCache.lusdToken, config, _LUSDAmount, vars.price, _maxFeePercentage);
            vars.netDebt = vars.netDebt.add(vars.LUSDFee);
        }

        // ICR is based on the composite debt, i.e. the requested LUSD amount + LUSD borrowing fee + LUSD gas comp.
        uint _gasCompensation = globalConfigManager.getGasCompensation();
        vars.compositeDebt = vars.netDebt.add(_gasCompensation);

        contractsCache.troveManager.openTrove(_borrower, _asset, _collAmount, vars.compositeDebt, _gasCompensation, vars.price, _upperHint, _lowerHint);

        // Move the coll to the Active Pool, and mint the LUSDAmount to the borrower
        _addColl(contractsCache.activePool, msg.sender, config, _collAmount);
        contractsCache.lusdToken.mint(_borrower, _LUSDAmount);
        // Move the LUSD gas compensation to the Gas Pool
        contractsCache.lusdToken.mint(gasPoolAddress, _gasCompensation);

        emit LUSDBorrowingFeePaid(_asset, _borrower, vars.stakingRewardAmount, vars.reserveAmount, vars.LUSDFee);
    }

    function openTrove(address _asset, uint _maxFeePercentage, uint _collAmount, uint _LUSDAmount, address _upperHint, address _lowerHint)
        notLocked
        guardianAllowed(_asset, 0x5f7e613d)
        external
        payable
        override
    {
        _openTrove(_asset, msg.sender, _maxFeePercentage, _getCollAmount(_asset, _collAmount), _LUSDAmount, _upperHint, _lowerHint);
    }

    function openTroveOnBehalfOf(address _asset, address _borrower, uint _maxFeePercentage, uint _collAmount, uint _LUSDAmount, address _upperHint, address _lowerHint)
        notLocked
        guardianAllowed(_asset, 0x6510bc99)
        external
        payable
        override
    {
        _openTrove(_asset, _borrower, _maxFeePercentage, _getCollAmount(_asset, _collAmount), _LUSDAmount, _upperHint, _lowerHint);

        emit TroveCreatedFor(_asset, msg.sender, _borrower);
    }

    // Send ETH as collateral to a trove
    function addColl(address _asset, uint _collAmount, address _upperHint, address _lowerHint)
        notLocked
        guardianAllowed(_asset, 0x8002ba10)
        external
        payable
        override
    {
        AdjustTroveInputValues memory inputValues = AdjustTroveInputValues(_asset, msg.sender, _getCollAmount(_asset, _collAmount), true, 0, false, _upperHint, _lowerHint, 0);
        _adjustTrove(inputValues);
    }

    // Withdraw ETH collateral from a trove
    function withdrawColl(address _asset, uint _collWithdrawal, address _upperHint, address _lowerHint)
        notLocked
        guardianAllowed(_asset, 0x29acc67d)
        external
        override
    {
        AdjustTroveInputValues memory inputValues = AdjustTroveInputValues(_asset, msg.sender, _collWithdrawal, false, 0, false, _upperHint, _lowerHint, 0);
        _adjustTrove(inputValues);
    }

    // Withdraw LUSD tokens from a trove: mint new LUSD tokens to the owner, and increase the trove's debt accordingly
    function withdrawLUSD(address _asset, uint _maxFeePercentage, uint _LUSDAmount, address _upperHint, address _lowerHint)
        notLocked
        guardianAllowed(_asset, 0x6d39d674)
        external
        override
    {
        AdjustTroveInputValues memory inputValues = AdjustTroveInputValues(_asset, msg.sender, 0, false, _LUSDAmount, true, _upperHint, _lowerHint, _maxFeePercentage);
        _adjustTrove(inputValues);
    }

    // Repay LUSD tokens to a Trove: Burn the repaid LUSD tokens, and reduce the trove's debt accordingly
    function repayLUSD(address _asset, uint _LUSDAmount, address _upperHint, address _lowerHint)
        notLocked
        guardianAllowed(_asset, 0xb196fbd6)
        external
        override
    {
        AdjustTroveInputValues memory inputValues = AdjustTroveInputValues(_asset, msg.sender, 0, false, _LUSDAmount, false, _upperHint, _lowerHint, 0);
        _adjustTrove(inputValues);
    }

    /*
    * _adjustTrove(): Alongside a debt change, this function can perform either a collateral top-up or a collateral withdrawal.
    *
    * It therefore expects either a positive _collChange argument.
    */
    function _adjustTrove(AdjustTroveInputValues memory inputValues) internal {
        ContractsCache memory contractsCache = ContractsCache(troveManager, activePool, lusdToken);
        LocalVariables_adjustTrove memory vars;
        DataTypes.AssetConfig memory config = assetConfigManager.get(inputValues._asset);
        if (inputValues._isCollIncrease) {
            _requireNotExceedCollateralCap(contractsCache.troveManager, config, inputValues._collChange);
        }

        vars.price = IPriceFeed(config.priceOracleAddress).fetchPrice(inputValues._asset);
        bool isRecoveryMode = contractsCache.troveManager.checkRecoveryMode(inputValues._asset, vars.price);

        if (inputValues._isDebtIncrease) {
            _requireValidMaxFeePercentage(config, inputValues._maxFeePercentage, isRecoveryMode);
            _requireNonZeroDebtChange(inputValues._debtChange);
        }
        _requireNonZeroAdjustment(inputValues._collChange, inputValues._debtChange);

        // Confirm the operation is a borrower adjusting their own trove
        assert(msg.sender == inputValues._borrower);

        vars.netDebtChange = inputValues._debtChange;

        // If the adjustment incorporates a debt increase and system is in Normal Mode, then trigger a borrowing fee
        if (inputValues._isDebtIncrease && !isRecoveryMode) {
            (vars.stakingRewardAmount, vars.reserveAmount, vars.LUSDFee) = _triggerBorrowingFee(contractsCache.lusdToken, config, inputValues._debtChange, vars.price, inputValues._maxFeePercentage);
            vars.netDebtChange = vars.netDebtChange.add(vars.LUSDFee); // The raw debt change includes the fee
        }

        if (!inputValues._isDebtIncrease && inputValues._debtChange > 0) {
            _requireSufficientLUSDBalance(contractsCache.lusdToken, inputValues._borrower, vars.netDebtChange);
        }

        contractsCache.troveManager.adjustTrove(inputValues._borrower, inputValues._asset, inputValues._collChange, inputValues._isCollIncrease, vars.netDebtChange, inputValues._isDebtIncrease, vars.price, inputValues._upperHint, inputValues._lowerHint, ITroveManagerV2.TroveOperations.adjustByOwner);

        emit LUSDBorrowingFeePaid(inputValues._asset, msg.sender, vars.stakingRewardAmount, vars.reserveAmount, vars.LUSDFee);

        // Use the unmodified _debtChange here, as we don't send the fee to the user
        _moveTokensAndETHfromAdjustment(
            config,
            contractsCache.activePool,
            contractsCache.lusdToken,
            msg.sender,
            inputValues._collChange,
            inputValues._isCollIncrease,
            inputValues._debtChange,
            inputValues._isDebtIncrease
        );
    }

    function closeTrove(address _asset)
        notLocked
        guardianAllowed(_asset, 0x9a1fddf6)
        external
        override
    {
        ContractsCache memory contractsCache = ContractsCache(troveManager, activePool, lusdToken);

        DataTypes.AssetConfig memory config = assetConfigManager.get(_asset);

        uint price = IPriceFeed(config.priceOracleAddress).fetchPrice(_asset);
        _requireNotInRecoveryMode(contractsCache.troveManager, _asset, price);
        (uint debt, uint coll) = contractsCache.troveManager.getTroveDebtAndColl(msg.sender, _asset);
        _requireCloseTroveTCRIsValid(contractsCache.troveManager, config, coll, debt, price);

        uint _gasCompensation = contractsCache.troveManager.getTroveGasCompensation(msg.sender, _asset);
        _requireSufficientLUSDBalance(contractsCache.lusdToken, msg.sender, debt.sub(_gasCompensation));

        contractsCache.troveManager.closeTrove(msg.sender, _asset, 0, 0, ITroveManagerV2.Status.closedByOwner, ITroveManagerV2.TroveOperations.closeByOwner);

        // Burn the repaid LUSD from the user's balance and the gas compensation from the Gas Pool
        contractsCache.lusdToken.burn(msg.sender, debt.sub(_gasCompensation));
        contractsCache.lusdToken.burn(gasPoolAddress, _gasCompensation);

        // Send the collateral back to the user
        _decreaseColl(contractsCache.activePool, config, msg.sender, coll);
    }

    /**
     * Claim remaining collateral from a redemption or from a liquidation with ICR > MCR in Recovery Mode
     */
    function claimCollateral(address _asset)
        notLocked
        guardianAllowed(_asset, 0x27ce76e9)
        external
        override
    {
        // send ETH from CollSurplus Pool to owner
        collSurplusPool.claimColl(msg.sender, _asset);
    }

    function claimLQTYRewards(address _asset)
        external
        override
    {
        troveManager.claimLQTYRewards(msg.sender, _asset);
    }

    function claimFarmRewards(address _asset)
        guardianAllowed(_asset, 0x4517dd60)
        external
        override
    {
        DataTypes.AssetConfig memory config = assetConfigManager.get(_asset);
        require(config.farmerAddress != address(0), "not farming!");
        IFarmer(config.farmerAddress).issueRewards(_asset, msg.sender);
    }

    // --- Helper functions ---

    function _triggerBorrowingFee(ILUSDToken _lusdToken, DataTypes.AssetConfig memory config, uint _LUSDAmount, uint _price, uint _maxFeePercentage) internal returns (uint, uint, uint) {
        uint _feeRate = IFeeRateModel(config.feeRateModelAddress).calcBorrowRate(config.asset, _price, _LUSDAmount);

        _requireUserAcceptsFeeRate(_feeRate, _maxFeePercentage);

        uint _borrowFee = _getFeeAmount(_feeRate, _LUSDAmount);
        uint _reserveAmount = _borrowFee.mul(config.reserveFactor).div(DECIMAL_PRECISION);
        uint _stakingRewardAmount = _borrowFee.sub(_reserveAmount);

        // Send fee to LQTY staking contract
        lqtyStaking.increaseF(_stakingRewardAmount);
        _lusdToken.mint(lqtyStakingAddress, _stakingRewardAmount);

        reservePool.depositLUSD(config.asset, _reserveAmount);
        _lusdToken.mint(address(reservePool), _reserveAmount);

        return (_stakingRewardAmount, _reserveAmount, _borrowFee);
    }

    function _getUSDValue(uint _coll, uint _price) internal pure returns (uint) {
        uint usdValue = _price.mul(_coll).div(DECIMAL_PRECISION);

        return usdValue;
    }

    function _moveTokensAndETHfromAdjustment
    (
        DataTypes.AssetConfig memory _config,
        IActivePool _activePool,
        ILUSDToken _lusdToken,
        address _borrower,
        uint _collChange,
        bool _isCollIncrease,
        uint _LUSDChange,
        bool _isDebtIncrease
    )
        internal
    {
        if (_LUSDChange > 0) {
            if (_isDebtIncrease) {
                _lusdToken.mint(_borrower, _LUSDChange);
            } else {
                _lusdToken.burn(_borrower, _LUSDChange);
            }
        }

        if (_collChange > 0) {
            if (_isCollIncrease) {
		        _addColl(_activePool, _borrower, _config, _collChange);
            } else {
                _decreaseColl(_activePool, _config, _borrower, _collChange);
            }
        }
    }

    // Send asset to Active Pool or Farmer
    function _addColl(IActivePool _activePool, address _from, DataTypes.AssetConfig memory _config, uint _amount) internal {
        bool isFarming = _config.farmerAddress != address(0);
        if (_config.asset.isPlatformToken()) {
            if (isFarming) {
                _config.farmerAddress.safeTransferETH(_amount);
                IFarmer(_config.farmerAddress).deposit(_config.asset, _amount);
            } else {
                address(_activePool).safeTransferETH(_amount);
            }
        } else {
            if (isFarming) {
                IERC20(_config.asset).safeTransferFrom(_from, _config.farmerAddress, _amount);
                IFarmer(_config.farmerAddress).deposit(_config.asset, _amount);
            } else {
                IERC20(_config.asset).safeTransferFrom(_from, address(_activePool), _amount);
            }
        }
    }

    function _decreaseColl(IActivePool _activePool, DataTypes.AssetConfig memory _config, address _borrower, uint _amount) internal {
        if (_config.farmerAddress != address(0)) {
            IFarmer(_config.farmerAddress).sendAsset(_config.asset, _borrower, _amount);
        } else {
            _activePool.sendAsset(_config.asset, _borrower, _amount);
        }
    }

    // --- 'Require' wrapper functions ---
    function _requireCloseTroveTCRIsValid(ITroveManagerV2 troveManagerCache, DataTypes.AssetConfig memory _config, uint _coll, uint _debt, uint _price) internal view {
        uint entireSystemColl = troveManagerCache.getEntireSystemColl(_config.asset);
        uint entireSystemDebt = troveManagerCache.getEntireSystemDebt(_config.asset);

        entireSystemColl = entireSystemColl.sub(_coll);
        entireSystemDebt = entireSystemDebt.sub(_debt);
        uint _newTCR = LiquityMath._computeCR(entireSystemColl, _config.decimals, entireSystemDebt, _price);

        require(_newTCR >= _config.riskParams.ccr, "BorrowerOps: newTCR must be greater than ccr");
    }


    function _requireNonZeroAdjustment(uint _collChange, uint _LUSDChange) internal pure {
        require(_collChange != 0 || _LUSDChange != 0, "BorrowerOps: There must be either a collateral change or a debt change");
    }

    function _requireNonZeroDebtChange(uint _debtChange) internal pure {
        require(_debtChange > 0, "BorrowerOps: Debt increase requires non-zero debtChange");
    }

    function _requireNotInRecoveryMode(ITroveManagerV2 troveManagerCache, address _asset, uint _price) internal view {
        require(!troveManagerCache.checkRecoveryMode(_asset, _price), "BorrowerOps: Operation not permitted during Recovery Mode");
    }

    function _requireSufficientLUSDBalance(ILUSDToken _lusdToken, address _borrower, uint _debtRepayment) internal view {
        require(_lusdToken.balanceOf(_borrower) >= _debtRepayment, "BorrowerOps: Caller doesnt have enough LUSD to make repayment");
    }

    function _requireValidMaxFeePercentage(DataTypes.AssetConfig memory config, uint _maxFeePercentage, bool _isRecoveryMode) internal pure {
        if (_isRecoveryMode) {
            require(_maxFeePercentage <= DECIMAL_PRECISION,
                "Max fee percentage must less than or equal to 100%");
        } else {
            require(_maxFeePercentage >= config.feeRateParams.borrowFeeRateFloor && _maxFeePercentage <= DECIMAL_PRECISION,
                "Max fee percentage must be between rate floor and 100%");
        }
    }

    function _getFeeAmount(uint _feeRate, uint _amount) internal pure returns (uint) {
        return _feeRate.mul(_amount).div(DECIMAL_PRECISION);
    }

    function _requireUserAcceptsFeeRate(uint _feeRate, uint _maxFeeRate) internal pure {
        require(_feeRate <= _maxFeeRate, "Fee rate exceeded provided max Rate");
    }

    function _getCollAmount(address _asset, uint _collAmount) internal view returns (uint) {
        if (_asset.isPlatformToken()) {
            require(_collAmount == msg.value, "input collAmount param is not equals pay in eth");
            return msg.value;
        } else {
            require(msg.value == 0, "input asset don't need pay in eth");
            return _collAmount;
        }
    }

    function _requireNotExceedCollateralCap(ITroveManagerV2 _troveManager, DataTypes.AssetConfig memory _config, uint _collIncrease) internal view {
        uint _collateralCap = _config.riskParams.collateralCap;
        require(_collateralCap == 0 || _collateralCap >=
            _collIncrease.add(_troveManager.getEntireSystemColl(_config.asset)), "BorrowerOperations: coll in system exceed the cap");
    }
}
