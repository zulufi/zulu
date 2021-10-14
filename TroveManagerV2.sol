// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "./Interfaces/IAssetConfigManager.sol";
import "./Interfaces/ICakeMiner.sol";
import "./Interfaces/ICommunityIssuance.sol";
import "./Interfaces/IGlobalConfigManager.sol";
import "./Interfaces/ITroveManagerV2.sol";
import "./Interfaces/ISortedTroves.sol";
import "./Dependencies/OwnableUpgradeable.sol";
import "./Dependencies/BaseMath.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/LiquityMath.sol";
import "./Dependencies/console.sol";
import "./Dependencies/MultiAssetInitializable.sol";

contract TroveManagerV2 is BaseMath, CheckContract, MultiAssetInitializable, ITroveManagerV2 {
    using SafeMath for uint;

    string constant public NAME = "TroveManagerV2";

    address public borrowerOperationsAddress;

    address public liquidatorOperationsAddress;

    address public redeemerOperationsAddress;

    ISortedTroves public sortedTroves;

    IAssetConfigManager public assetConfigManager;

    IGlobalConfigManager public globalConfigManager;

    ICommunityIssuance public communityIssuance;

    ICakeMiner public cakeMiner;

    // Store the necessary data for a trove
    struct Trove {
        uint debt;
        uint stake;
        uint gasCompensation;
        Status status;
        uint128 arrayIndex;
    }

    // user address => asset address => Trove
    mapping (address => mapping(address => Trove)) public Troves;

    // asset address => DebtR
    mapping (address => DebtR) public debtRs;

    // asset address => total debts
    mapping (address => uint256) public totalDebtsPerAsset;

    // asset address => total collaterals
    mapping (address => uint256) public totalCollsPerAsset;

    // asset address => total gas compensation
    mapping (address => uint256) public totalGasCompensationPerAsset;

    // asset address => total stakes
    mapping (address => uint) public totalStakesPerAsset;

    // asset => per stake of normalized debt
    mapping (address => uint) public L_LUSDDebts;

    // Map addresses with active troves to their RewardSnapshot
    // trove address => asset address => snapshot of L_LUSDDebts(normalized debt)
    mapping (address => mapping (address => uint)) public debtRewardSnapshots;

    // Array of all active trove addresses - used to to compute an approximate hint off-chain, for the sorted list insertion
    // asset address => trove owners
    mapping (address => address[]) public TroveOwnersPerAsset;

    // Error trackers for the trove redistribution calculation
    mapping (address => uint) public lastCollErrors_Redistribution;
    // Error trackers of the normalized debt for trove redistribution
    mapping (address => uint ) public lastLUSDDebtErrors_Redistribution;

    // Current index of lqty rewards
    mapping (address => uint) public L_LQTYRewards;

    // trove address => asset address => snapshot of L_LQTYRewards
    mapping (address => mapping(address => uint)) public lqtyRewardSnapshots;

    // trove address => asset address => accrued LQTY rewards
    mapping (address => mapping(address => uint)) accruedLQTYRewards;

    // --- Dependency setter ---

    function initialize() public initializer {
        __Ownable_init();
    }

    function initializeAssetInternal(address asset, bytes calldata data) internal override {
        debtRs[asset] = DebtR(0, block.timestamp, DECIMAL_PRECISION);
    }

    function setAddresses(
        address _borrowerOperationsAddress,
        address _liquidatorOperationsAddress,
        address _redeemerOperationsAddress,
        address _sortedTrovesAddress,
        address _cakeMinerAddress,
        address _assetConfigManagerAddress,
        address _globalConfigManagerAddress,
        address _communityIssuanceAddress
    )
        external
        override
        onlyOwner
    {
        require(borrowerOperationsAddress == address(0), "address has already been set");

        checkContract(_borrowerOperationsAddress);
        checkContract(_liquidatorOperationsAddress);
        checkContract(_redeemerOperationsAddress);
        checkContract(_sortedTrovesAddress);
        checkContract(_cakeMinerAddress);
        checkContract(_assetConfigManagerAddress);
        checkContract(_globalConfigManagerAddress);
        checkContract(_liquidatorOperationsAddress);
        checkContract(_communityIssuanceAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        liquidatorOperationsAddress = _liquidatorOperationsAddress;
        redeemerOperationsAddress = _redeemerOperationsAddress;
        sortedTroves = ISortedTroves(_sortedTrovesAddress);
        cakeMiner = ICakeMiner(_cakeMinerAddress);
        assetConfigManager = IAssetConfigManager(_assetConfigManagerAddress);
        globalConfigManager = IGlobalConfigManager(_globalConfigManagerAddress);
        communityIssuance = ICommunityIssuance(_communityIssuanceAddress);

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit LiquidatorOperationsAddressChanged(_liquidatorOperationsAddress);
        emit RedeemerOperationsAddressChanged(_redeemerOperationsAddress);
        emit SortedTrovesAddressChanged(_sortedTrovesAddress);
        emit CakeMinerAddressChanged(_cakeMinerAddress);
        emit AssetConfigManagerAddressChanged(_assetConfigManagerAddress);
        emit GlobalConfigManagerAddressChanged(_globalConfigManagerAddress);
        emit CommunityIssuanceAddressChanged(_communityIssuanceAddress);
    }

    function setDebtRate(address _asset, uint _rate) external override onlyOwner {
        DebtR storage _debtR = debtRs[_asset];
        uint _currentTime = block.timestamp;
        _debtR.R = _calculateR(_debtR.R, _debtR.rate, _currentTime.sub(_debtR.timestamp));
        _debtR.rate = _rate;
        _debtR.timestamp = _currentTime;
        emit DebtRUpdated(_asset, _rate, _debtR.R);
    }

    function _calculateR(uint _R, uint _rate, uint _seconds) internal view returns (uint) {
        uint _base = DECIMAL_PRECISION.add(_rate);
        return _R.mul(LiquityMath._baseDecPow(_base, _seconds)).div(DECIMAL_PRECISION);
    }

    function _currentDebtR(address _asset) internal view returns (DebtR memory) {
        uint _currentTime = block.timestamp;
        DebtR memory _debtR = debtRs[_asset];
        if (_currentTime == _debtR.timestamp) {
            return _debtR;
        }
        _debtR.R = _calculateR(_debtR.R, _debtR.rate, _currentTime.sub(_debtR.timestamp));
        _debtR.timestamp = _currentTime;
        return _debtR;
    }

    function _updateDebtR(address _asset) internal {
        DebtR memory _debtR = _currentDebtR(_asset);
        debtRs[_asset] = _debtR;
        emit DebtRUpdated(_asset, _debtR.rate, _debtR.R);
    }

    function _currentDebt(address _asset, uint _nDebt) internal view returns (uint) {
        DebtR memory _debtR = _currentDebtR(_asset);
        return _nDebt.mul(_debtR.R).div(DECIMAL_PRECISION);
    }

    function _normalizeDebt(address _asset, uint _debt) internal view returns (uint) {
        DebtR memory _debtR = _currentDebtR(_asset);
        uint _nDebt = _debt.mul(DECIMAL_PRECISION).div(_debtR.R);
        return _nDebt.mul(_debtR.R) < _debt ? _nDebt.add(1) : _nDebt;
    }

    function _stakesToColls(address _asset, uint _stakes) internal view returns (uint) {
        if (totalStakesPerAsset[_asset] == 0) { return 0; }
        return _stakes.mul(totalCollsPerAsset[_asset]).div(totalStakesPerAsset[_asset]);
    }

    function _collsToStakes(address _asset, uint _colls) internal view returns (uint) {
        if (totalCollsPerAsset[_asset] == 0) { return _colls; }
        return _colls.mul(totalStakesPerAsset[_asset]).div(totalCollsPerAsset[_asset]);
    }

    function getNTrovesFrom(
        address _asset,
        address _from,
        uint _n
    )
        internal
        view
        returns (address[] memory)
    {
        uint count = 0;
        address[] memory owners = new address[](_n);
        while (_from != address(0) && count < _n) {
            owners[count++] = _from;
            _from = sortedTroves.getPrev(_asset, _from);
        }
        return owners;
    }

    function getLastNTroveOwners(
        address _asset,
        uint _n
    )
        external
        view
        override
        returns (address[] memory)
    {
        return getNTrovesFrom(_asset, sortedTroves.getLast(_asset), _n);
    }

    function getLastNTrovesAboveMCR(
        address _asset,
        uint _n,
        address _firstHint,
        uint _price
    )
        external
        view
        override
        returns (address[] memory)
    {
        DataTypes.AssetConfig memory _config = assetConfigManager.get(_asset);
        uint mcr = _config.mcr;
        address currentBorrower;
        if (isValidHint(_asset, _firstHint, _price)) {
            currentBorrower = _firstHint;
        } else {
            currentBorrower = sortedTroves.getLast(_asset);
            // Find the first trove with ICR >= MCR
            while (
                currentBorrower != address(0) &&
                _getCurrentICR(currentBorrower, _config, _price) < mcr
            ) {
                currentBorrower = sortedTroves.getPrev(_asset, currentBorrower);
            }
        }
        return getNTrovesFrom(_asset, currentBorrower, _n);
    }

    function getTroveOwnersCount(
        address _asset
    )
        external
        view
        override
        returns (uint)
    {
        return TroveOwnersPerAsset[_asset].length;
    }

    function getTroveFromTroveOwnersArray(
        address _asset,
        uint _index
    )
        external
        view
        override
        returns (address)
    {
        return TroveOwnersPerAsset[_asset][_index];
    }

    function isValidHint(
        address _asset,
        address _firstHint,
        uint _price
    )
        internal
        view
        returns (bool)
    {
        DataTypes.AssetConfig memory _config = assetConfigManager.get(_asset);
        uint mcr = _config.mcr;
        if (_firstHint == address(0) ||
            !sortedTroves.contains(_asset, _firstHint) ||
            _getCurrentICR(_firstHint, _config, _price) < mcr
        ) {
            return false;
        }

        address nextTrove = sortedTroves.getNext(_asset, _firstHint);
        return nextTrove == address(0) || _getCurrentICR(nextTrove, _config, _price) < mcr;
    }

    function getNominalICR(
        address _borrower,
        address _asset
    )
        public
        view
        override
        returns (uint)
    {
        uint currentColl = getTroveColl(_borrower, _asset);
        uint currentNormalizedDebt = _getTroveNormalizedDebt(_borrower, _asset);

        uint NICR = LiquityMath._computeNominalCR(currentColl, currentNormalizedDebt);
        return NICR;
    }

    function computeNominalICR(
        address _asset,
        uint _coll,
        uint _debt
    )
        external
        view
        override
        returns (uint)
    {
        uint _nDebt = _normalizeDebt(_asset, _debt);
        return LiquityMath._computeNominalCR(_coll, _nDebt);
    }

    function isUnderCollateralized(
        address _borrower,
        address _asset,
        uint _price
    )
        external
        view
        override
        returns (bool)
    {
        DataTypes.AssetConfig memory _config = assetConfigManager.get(_asset);
        uint ICR = _getCurrentICR(_borrower, _config, _price);
        uint MCR = _config.mcr;
        return ICR < MCR;
    }

    function getCurrentICR(
        address _borrower,
        address _asset,
        uint _price
    )
        external
        view
        override
        returns (uint)
    {
        return _getCurrentICR(_borrower, assetConfigManager.get(_asset), _price);
    }

    function _getCurrentICR(
        address _borrower,
        DataTypes.AssetConfig memory _config,
        uint _price
    )
        internal
        view
        returns (uint)
    {
        (uint currentColl, uint currentLUSDDebt) = _getCurrentTroveAmounts(_borrower, _config.asset);

        return LiquityMath._computeCR(currentColl, _config.decimals, currentLUSDDebt, _price);
    }

    // Get the borrower's pending accumulated LUSD reward, earned by their stake
    function getPendingLUSDDebtReward(
        address _borrower,
        address _asset
    )
        public
        view
        override
        returns (uint)
    {
        return _currentDebt(_asset, _getPendingNormalizedDebtReward(_borrower, _asset));
    }

    function _getPendingNormalizedDebtReward(
        address _borrower,
        address _asset
    )
        internal
        view
        returns (uint)
    {
        uint snapshotLUSDDebt = debtRewardSnapshots[_borrower][_asset];
        uint rewardPerUnitStaked = L_LUSDDebts[_asset].sub(snapshotLUSDDebt);

        if ( rewardPerUnitStaked == 0 || Troves[_borrower][_asset].status != Status.active) { return 0; }

        uint stake =  Troves[_borrower][_asset].stake;
        return stake.mul(rewardPerUnitStaked).div(DECIMAL_PRECISION);
    }

    // Return the Troves entire debt and coll, including pending rewards from redistributions.
    function getTroveDebtAndColl(
        address _borrower,
        address _asset
    )
        public
        view
        override
        returns (uint debt, uint coll)
    {
        debt = getTroveDebt(_borrower, _asset);
        coll = getTroveColl(_borrower, _asset);
    }

    function getTotalDebts()
        external
        view
        override
        returns (uint)
    {
        address[] memory _supportedAssets = assetConfigManager.supportedAssets();
        uint _totalDebts = 0;
        for (uint _index = 0; _index < _supportedAssets.length; _index++) {
            address _asset = _supportedAssets[_index];
            _totalDebts = _totalDebts.add(_currentDebt(_asset, totalDebtsPerAsset[_asset]));
        }
        return _totalDebts;
    }

    function getTotalStakes(address _asset)
        external
        view
        override
        returns (uint)
    {
        return totalStakesPerAsset[_asset];
    }

    function getTroveStatus(
        address _borrower,
        address _asset
    )
        external
        view
        override
        returns (uint)
    {
        return uint(Troves[_borrower][_asset].status);
    }

    function getTroveStake(
        address _borrower,
        address _asset
    )
        external
        view
        override
        returns (uint)
    {
        return Troves[_borrower][_asset].stake;
    }

    function getTroveDebt(
        address _borrower,
        address _asset
    )
        public
        view
        override
        returns (uint)
    {
        uint debt = _currentDebt(_asset, Troves[_borrower][_asset].debt);
        uint pendingLUSDDebtReward = getPendingLUSDDebtReward(_borrower, _asset);
        return debt.add(pendingLUSDDebtReward);
    }

    function _getTroveNormalizedDebt(
        address _borrower,
        address _asset
    )
        internal
        view
        returns (uint)
    {
        uint _pendingNormalizedDebtReward = _getPendingNormalizedDebtReward(_borrower, _asset);
        return Troves[_borrower][_asset].debt.add(_pendingNormalizedDebtReward);
    }

    function getTroveColl(
        address _borrower,
        address _asset
    )
        public
        view
        override
        returns (uint)
    {
        return _stakesToColls(_asset, Troves[_borrower][_asset].stake);
    }

    function getTroveGasCompensation(
        address _borrower,
        address _asset
    )
        external
        view
        override
        returns (uint)
    {
        return Troves[_borrower][_asset].gasCompensation;
    }

    function getEntireSystemColl(
        address _asset
    )
        public
        view
        override
        returns (uint)
    {
        return totalCollsPerAsset[_asset];
    }

    function getEntireSystemDebt(
        address _asset
    )
        public
        view
        override
        returns (uint)
    {
        return _currentDebt(_asset, totalDebtsPerAsset[_asset]);
    }

    function getEntireSystemGasCompensation(
        address _asset
    )
        external
        view
        override
        returns (uint)
    {
        return totalGasCompensationPerAsset[_asset];
    }

    function openTrove(
        address _borrower,
        address _asset,
        uint _coll,
        uint _debt,
        uint _gasCompensation,
        uint _price,
        address _upperHint,
        address _lowerHint
    )
        external
        override
    {
        _requireCallerIsBorrowerOperations();
        _requireTroveIsNotActive(_borrower, _asset);
        DataTypes.AssetConfig memory _config = assetConfigManager.get(_asset);
        _requireMinDebt(_config, _debt, _gasCompensation);
        _requireICRAndTCRValid(_config, _coll, _debt, _price);

        // update debtR
        _updateDebtR(_asset);

        _updateLQTYRewardIndex(_asset);

        if (cakeMiner.isSupported(_asset)) {
            _applyPendingCakeRewards(_borrower, _asset);
        }

        // initialize coll & debt
        uint _nDebt = _normalizeDebt(_asset, _debt);
        uint _stakes = _collsToStakes(_asset, _coll);
        Troves[_borrower][_asset].status = Status.active;
        Troves[_borrower][_asset].stake = _stakes;
        Troves[_borrower][_asset].debt = _nDebt;
        Troves[_borrower][_asset].gasCompensation = _gasCompensation;

        // update total balance
        totalCollsPerAsset[_asset] = totalCollsPerAsset[_asset].add(_coll);
        totalDebtsPerAsset[_asset] = totalDebtsPerAsset[_asset].add(_nDebt);
        totalGasCompensationPerAsset[_asset] = totalGasCompensationPerAsset[_asset].add(_gasCompensation);
        totalStakesPerAsset[_asset] = totalStakesPerAsset[_asset].add(_stakes);

        // initialize debt reward snapshot
        _updateDebtRewardSnapshots(_borrower, _asset);

        // initialize lqty reward snapshot
        _updateLQTYRewardSnapshots(_borrower, _asset);

        // insert into sorted troves
        uint arrayIndex = _addTroveOwnerToArray(_borrower, _asset);
        uint NICR = LiquityMath._computeNominalCR(_coll, _nDebt);
        sortedTroves.insert(_asset, _borrower, NICR, _upperHint, _lowerHint);

        emit TotalStakesUpdated(_asset, totalStakesPerAsset[_asset]);
        emit TroveOpened(
            _asset,
            _borrower,
            _coll,
            _debt,
            _nDebt,
            _gasCompensation,
            _stakes,
            arrayIndex
        );
    }

    function closeTrove(
        address _borrower,
        address _asset,
        uint _price,
        uint _redistributedColl,
        uint _redistributedDebt,
        Status _closedStatus
    )
        external
        override
    {
        _requireCallerIsBOorLOorRO();
        _requireMoreThanOneTroveInSystem(_asset);
        _requireTroveIsActive(_borrower, _asset);
        _requireClosedStatus(_closedStatus);
        DataTypes.AssetConfig memory _config = assetConfigManager.get(_asset);

        // update debtR
        _updateDebtR(_asset);

        // apply pending rewards to debt/coll
        // this must be done before trove state is cleared
        _applyPendingDebtRewards(_borrower, _asset);

        // apply pending lqty rewards
        _applyPendingLQTYRewards(_borrower, _asset);

        if (cakeMiner.isSupported(_asset)) {
            _applyPendingCakeRewards(_borrower, _asset);
        }

        uint _nDebt = Troves[_borrower][_asset].debt;
        uint _nRedistributedDebt = _normalizeDebt(_asset, _redistributedDebt);
        uint _stakes = Troves[_borrower][_asset].stake;
        uint _colls = _stakesToColls(_asset, _stakes);
        require(_redistributedColl <= _colls);

        // update bookings
        totalCollsPerAsset[_asset] = totalCollsPerAsset[_asset].sub(_colls).add(_redistributedColl);
        totalDebtsPerAsset[_asset] = totalDebtsPerAsset[_asset].sub(_nDebt).add(_nRedistributedDebt);
        totalGasCompensationPerAsset[_asset] = totalGasCompensationPerAsset[_asset].sub(Troves[_borrower][_asset].gasCompensation);
        totalStakesPerAsset[_asset] = totalStakesPerAsset[_asset].sub(_stakes);

        // update trove status & balance
        Troves[_borrower][_asset].status = _closedStatus;
        Troves[_borrower][_asset].debt = 0;
        Troves[_borrower][_asset].stake = 0;
        Troves[_borrower][_asset].gasCompensation = 0;

        // clear debt reward snapshot
        _removeDebtRewardSnapshots(_borrower, _asset);

        // clear lqty reward snapshot
        _removeLQTYRewardSnapshots(_borrower, _asset);

        // remove from sorted troves
        _removeTroveOwner(_borrower, _asset);
        sortedTroves.remove(_asset, _borrower);

        // update accounting of redistribution
        if (_nRedistributedDebt > 0) {
            _redistributeDebt(_borrower, _asset, _nRedistributedDebt);
        }

        emit TotalStakesUpdated(_asset, totalStakesPerAsset[_asset]);
        emit TroveClosed(_asset, _borrower, _closedStatus);
    }

    function adjustTrove(
        address _borrower,
        address _asset,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease,
        uint _price,
        address _upperHint,
        address _lowerHint
    )
        external
        override
    {
        _requireCallerIsBOorRO();
        _requireTroveIsActive(_borrower, _asset);

        DataTypes.AssetConfig memory _config = assetConfigManager.get(_asset);
        _requireAdjustValid(_borrower, _config, _collChange, _isCollIncrease, _debtChange, _isDebtIncrease, _price);

        // update debtR
        _updateDebtR(_asset);

        // apply pending debt rewards
        _applyPendingDebtRewards(_borrower, _asset);

        // apply pending lqty rewards
        _applyPendingLQTYRewards(_borrower, _asset);

        if (cakeMiner.isSupported(_asset)) {
            _applyPendingCakeRewards(_borrower, _asset);
        }

        // compute new debt/coll/stake
        AdjustVariables memory vars = _computeAdjustValues(
            _borrower, _asset, _collChange, _isCollIncrease, _debtChange, _isDebtIncrease);

        // update trove
        Troves[_borrower][_asset].debt = vars.newNormalizedDebt;
        Troves[_borrower][_asset].stake = vars.newStake;

        // update total bookings
        totalCollsPerAsset[_asset] = _isCollIncrease ? totalCollsPerAsset[_asset].add(_collChange) : totalCollsPerAsset[_asset].sub(_collChange);
        totalDebtsPerAsset[_asset] = _isDebtIncrease ? totalDebtsPerAsset[_asset].add(vars.normalizedDebtChange) : totalDebtsPerAsset[_asset].sub(vars.normalizedDebtChange);
        totalStakesPerAsset[_asset] = totalStakesPerAsset[_asset].sub(vars.oldStake).add(vars.newStake);

        // Re-insert trove in to the sorted list
        uint _newDebt = _currentDebt(_asset, vars.newNormalizedDebt);
        sortedTroves.reInsert(_asset, _borrower, LiquityMath._computeNominalCR(vars.newColl, vars.newNormalizedDebt), _upperHint, _lowerHint);

        emit TotalStakesUpdated(_asset, totalStakesPerAsset[_asset]);
        emit TroveUpdated(_asset, _borrower, _newDebt, vars.newNormalizedDebt, vars.newColl, vars.newStake);
    }

    function issueLQTYRewards(
        address _borrower,
        address _asset
    )
        external
        override
        returns (uint)
    {
        _applyPendingLQTYRewards(_borrower, _asset);

        uint curRewards = lqtyRewardSnapshots[_borrower][_asset];
        lqtyRewardSnapshots[_borrower][_asset] = 0;
        emit IssueLQTYRewards(_asset, _borrower, curRewards);

        return curRewards;
    }

    struct AdjustVariables {
        uint oldNormalizedDebt;
        uint oldColl;
        uint oldStake;
        uint newNormalizedDebt;
        uint newColl;
        uint newStake;
        uint normalizedDebtChange;
    }

    function _computeAdjustValues(
        address _borrower,
        address _asset,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease
    ) internal view returns (AdjustVariables memory) {
        uint _oldNormalizedDebt = Troves[_borrower][_asset].debt;
        uint _nDebtChange = _normalizeDebt(_asset, _debtChange);
        uint _oldStake = Troves[_borrower][_asset].stake;
        uint _oldColl = _stakesToColls(_asset, _oldStake);
        uint _newNormalizedDebt = _isDebtIncrease ? _oldNormalizedDebt.add(_nDebtChange) : _oldNormalizedDebt.sub(_nDebtChange);
        uint _newColl = _isCollIncrease ? _oldColl.add(_collChange) : _oldColl.sub(_collChange);
        uint _newStake = _collsToStakes(_asset, _newColl);

        return AdjustVariables(
            _oldNormalizedDebt,
            _oldColl,
            _oldStake,
            _newNormalizedDebt,
            _newColl,
            _newStake,
            _nDebtChange
        );
    }

    // redistribute the normalized debt
    function _redistributeDebt(
        address _borrower,
        address _asset,
        uint _nDebt
    )
        internal
    {
        if (_nDebt == 0) { return; }

        uint LUSDDebtNumerator = _nDebt.mul(DECIMAL_PRECISION).add(lastLUSDDebtErrors_Redistribution[_asset]);

        // Get the per-unit-staked terms
        uint totalStakes = totalStakesPerAsset[_asset];
        uint LUSDDebtRewardPerUnitStaked = LUSDDebtNumerator.div(totalStakes);
        lastLUSDDebtErrors_Redistribution[_asset] = LUSDDebtNumerator.sub(LUSDDebtRewardPerUnitStaked.mul(totalStakes));

        // Add per-unit-staked terms to the running totals
        uint new_L_LUSDDebt = L_LUSDDebts[_asset].add(LUSDDebtRewardPerUnitStaked);
        L_LUSDDebts[_asset] = new_L_LUSDDebt;
        emit L_LUSDDebtsUpdated(_asset, _borrower, new_L_LUSDDebt);
    }

    function getTCR(
        address _asset,
        uint _price
    )
        external
        view
        override
        returns (uint)
    {
        return _getTCR(_asset, _price);
    }

    function checkRecoveryMode(
        address _asset,
        uint _price
    )
        public
        view
        override
        returns (bool)
    {
        uint TCR = _getTCR(_asset, _price);
        uint CCR = assetConfigManager.get(_asset).ccr;

        return TCR < CCR;
    }

    function _getTCR(
        address _asset,
        uint _price
    )
        internal
        view
        returns (uint TCR)
    {
        uint entireSystemColl = getEntireSystemColl(_asset);
        uint entireSystemDebt = getEntireSystemDebt(_asset);

        TCR = LiquityMath._computeCR(entireSystemColl, assetConfigManager.get(_asset).decimals, entireSystemDebt, _price);

        return TCR;
    }

    function _getNewTCRFromChange(
        DataTypes.AssetConfig memory _config,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease,
        uint _price
    )
        internal
        view
        returns (uint)
    {
        uint entireSystemColl = getEntireSystemColl(_config.asset);
        uint entireSystemDebt = getEntireSystemDebt(_config.asset);

        entireSystemColl = _isCollIncrease ? entireSystemColl.add(_collChange) : entireSystemColl.sub(_collChange);
        entireSystemDebt = _isDebtIncrease ? entireSystemDebt.add(_debtChange) : entireSystemDebt.sub(_debtChange);

        uint TCR = LiquityMath._computeCR(entireSystemColl, _config.decimals, entireSystemDebt, _price);

        return TCR;
    }

    function _getCurrentTroveAmounts(
        address _borrower,
        address _asset
    )
        internal
        view
        returns (uint, uint)
    {
        uint currentColl = _stakesToColls(_asset, Troves[_borrower][_asset].stake);
        uint currentLUSDDebt = _currentDebt(_asset, _getTroveNormalizedDebt(_borrower, _asset));

        return (currentColl, currentLUSDDebt);
    }

    // Add the borrowers's coll and debt rewards earned from redistributions, to their Trove
    function _applyPendingDebtRewards(
        address _borrower,
        address _asset
    )
        internal
        returns (uint pendingNormalizedLUSDDebtReward)
    {
        // Compute pending rewards
        pendingNormalizedLUSDDebtReward = _getPendingNormalizedDebtReward(_borrower, _asset);

        if (pendingNormalizedLUSDDebtReward > 0) {
            // Apply pending rewards to trove's state
            Troves[_borrower][_asset].debt = Troves[_borrower][_asset].debt.add(pendingNormalizedLUSDDebtReward);
            _updateDebtRewardSnapshots(_borrower, _asset);

            emit ApplyDebtRewards(
                _asset,
                _borrower,
                pendingNormalizedLUSDDebtReward,
                Troves[_borrower][_asset].debt
            );
        }
    }

    function _applyPendingCakeRewards(
        address _borrower,
        address _asset
    )
        internal
    {
        cakeMiner.issueCake(_asset, _borrower);
    }

    function _updateDebtRewardSnapshots(
        address _borrower,
        address _asset
    )
        internal
    {
        // update reward snapshot of redistribution
        uint L_LUSDDebt = L_LUSDDebts[_asset];
        debtRewardSnapshots[_borrower][_asset] = L_LUSDDebt;

        emit DebtRewardSnapshotUpdated(_asset, _borrower, L_LUSDDebt);
    }

    function _removeDebtRewardSnapshots(
        address _borrower,
        address _asset
    )
        internal
    {
        debtRewardSnapshots[_borrower][_asset] = 0;
        emit DebtRewardSnapshotUpdated(_asset, _borrower, 0);
    }

    function _updateLQTYRewardIndex(
        address _asset
    )
        internal
    {
        uint totalStakes = totalStakesPerAsset[_asset];
        if (totalStakes > 0) {
            uint accruedLQTYReward = communityIssuance.issueLiquidityLQTY(_asset);
            uint rewardPerStake = accruedLQTYReward.div(totalStakes);
            uint latestLQTYReward = L_LQTYRewards[_asset].add(rewardPerStake);
            L_LQTYRewards[_asset] = latestLQTYReward;
            emit L_LQTYRewardsUpdated(_asset, latestLQTYReward);
        }
    }

    function _updateLQTYRewardSnapshots(
        address _borrower,
        address _asset
    )
        internal
    {
        uint new_L = L_LQTYRewards[_asset];
        lqtyRewardSnapshots[_borrower][_asset] = new_L;
        emit LQTYRewardSnapshotUpdated(_asset, _borrower, new_L);
    }

    function _applyPendingLQTYRewards(
        address _borrower,
        address _asset
    )
        internal
    {
        _updateLQTYRewardIndex(_asset);

        uint rewardPerStake = L_LQTYRewards[_asset].sub(lqtyRewardSnapshots[_borrower][_asset]);
        uint rewards = rewardPerStake.mul(Troves[_borrower][_asset].stake);
        uint latestLQTYReward = accruedLQTYRewards[_borrower][_asset].add(rewards);
        accruedLQTYRewards[_borrower][_asset] = latestLQTYReward;
        emit ApplyLQTYRewards(_asset, _borrower, rewards);

        _updateLQTYRewardSnapshots(_borrower, _asset);
    }

    function _removeLQTYRewardSnapshots(
        address _borrower,
        address _asset
    )
        internal
    {
        lqtyRewardSnapshots[_borrower][_asset] = 0;
        emit LQTYRewardSnapshotUpdated(_asset, _borrower, 0);
    }

    function _addTroveOwnerToArray(
        address _borrower,
        address _asset
    )
        internal
        returns (uint128 index)
    {
        /* Max array size is 2**128 - 1, i.e. ~3e30 troves. No risk of overflow, since troves have minimum LUSD
        debt of liquidation reserve plus MIN_NET_DEBT. 3e30 LUSD dwarfs the value of all wealth in the world ( which is < 1e15 USD). */

        // Push the Troveowner to the array
        TroveOwnersPerAsset[_asset].push(_borrower);

        // Record the index of the new Troveowner on their Trove struct
        index = uint128(TroveOwnersPerAsset[_asset].length.sub(1));
        Troves[_borrower][_asset].arrayIndex = index;

        return index;
    }

    /*
    * Remove a Trove owner from the TroveOwners array, not preserving array order. Removing owner 'B' does the following:
    * [A B C D E] => [A E C D], and updates E's Trove struct to point to its new array index.
    */
    function _removeTroveOwner(
        address _borrower,
        address _asset
    )
        internal
    {
        Status troveStatus = Troves[_borrower][_asset].status;
        // It’s set in caller function `_closeTrove`
        assert(troveStatus != Status.nonExistent && troveStatus != Status.active);

        uint128 index = Troves[_borrower][_asset].arrayIndex;
        uint length = TroveOwnersPerAsset[_asset].length;
        uint idxLast = length.sub(1);

        assert(index <= idxLast);

        address addressToMove = TroveOwnersPerAsset[_asset][idxLast];

        TroveOwnersPerAsset[_asset][index] = addressToMove;
        Troves[addressToMove][_asset].arrayIndex = index;
        emit TroveIndexUpdated(_asset, addressToMove, index);

        TroveOwnersPerAsset[_asset].pop();
    }

    // --- 'require' wrapper functions ---
    /*
    *In Recovery Mode, only allow:
    *
    * - Pure collateral top-up
    * - Pure debt repayment
    * - Collateral top-up with debt repayment
    * - A debt increase combined with a collateral top-up which makes the ICR >= 150% and improves the ICR (and by extension improves the TCR).
    *
    * In Normal Mode, ensure:
    *
    * - The new ICR is above MCR
    * - The adjustment won't pull the TCR below CCR
    */
    function _requireAdjustValid(address _borrower, DataTypes.AssetConfig memory _config, uint _collChange, bool _isCollIncrease, uint _debtChange, bool _isDebtIncrease, uint _price) internal view {
        (uint _coll, uint _debt) = _getCurrentTroveAmounts(_borrower, _config.asset);

        uint _oldICR = LiquityMath._computeCR(_coll, _config.decimals, _debt, _price);

        if (_isCollIncrease) {
            _coll = _coll.add(_collChange);
        } else {
            require(_coll >= _collChange, "must have enough coll to withdraw");
            _coll = _coll.sub(_collChange);
        }

        if (_isDebtIncrease) {
            _debt = _debt.add(_debtChange);
        } else {
            require(_debt >= _debtChange, "must have enough debt to repay");
            _debt = _debt.sub(_debtChange);
            _requireMinDebt(_config, _debt, Troves[_borrower][_config.asset].gasCompensation);
        }

        uint _newICR = LiquityMath._computeCR(_coll, _config.decimals, _debt, _price);

        if (checkRecoveryMode(_config.asset, _price)) {
            _requireCollNotDecrease(_collChange, _isCollIncrease);
            if (_isDebtIncrease) {
                _requireICRIsAboveCCR(_config, _newICR);
                _requireNewICRIsAboveOldICR(_newICR, _oldICR);
            }
        } else { // if Normal Mode
            _requireICRIsAboveMCR(_config, _newICR);
            uint _newTCR = _getNewTCRFromChange(_config, _collChange, _isCollIncrease, _debtChange, _isDebtIncrease, _price);
            _requireNewTCRIsAboveCCR(_config, _newTCR);
        }
    }

    function _requireNewICRIsAboveOldICR(uint _newICR, uint _oldICR) internal pure {
        require(_newICR >= _oldICR, "TroveManager: newICR must be greater than oldICR");
    }

    function _requireCollNotDecrease(uint _collChange, bool _isCollIncrease) internal pure {
        require(_isCollIncrease || _collChange == 0, "TroveManager: coll can't decrease in recovery mode");
    }

    function _requireICRAndTCRValid(DataTypes.AssetConfig memory _config, uint _coll, uint _debt, uint _price) internal view {
        bool _isRecoveryMode = checkRecoveryMode(_config.asset, _price);

        uint ICR = LiquityMath._computeCR(_coll, _config.decimals, _debt, _price);
        if (_isRecoveryMode) {
            _requireICRIsAboveCCR(_config, ICR);
        } else {
            _requireICRIsAboveMCR(_config, ICR);
            uint _newTCR = _getNewTCRFromChange(_config, _coll, true, _debt, true, _price);
            _requireNewTCRIsAboveCCR(_config, _newTCR);
        }
    }

    function _requireMinDebt(DataTypes.AssetConfig memory _config, uint _debt, uint _gasCompensation) internal pure {
        require(_debt.sub(_gasCompensation) >= _config.minDebt, "TroveManager: debt must be greater than the minDebt");
    }

    function _requireICRIsAboveCCR(DataTypes.AssetConfig memory _config, uint _icr) internal pure {
        require(_icr >= _config.ccr, "TroveManager: icr must be greater than ccr");
    }

    function _requireICRIsAboveMCR(DataTypes.AssetConfig memory _config, uint _icr) internal pure {
        require(_icr >= _config.mcr, "TroveManager: icr must be greater than mcr");
    }

    function _requireNewTCRIsAboveCCR(DataTypes.AssetConfig memory _config, uint _newTCR) internal pure {
        require(_newTCR >= _config.ccr, "TroveManager: tcr must be greater than ccr");
    }

    function _requireCallerIsBorrowerOperations() internal view {
        require(msg.sender == borrowerOperationsAddress, "TroveManager: Caller is not the BorrowerOperations");
    }

    function _requireCallerIsBOorRO() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == redeemerOperationsAddress,
            "TroveManager: Caller is neither BorrowerOperations or RedeemerOperations");
    }

    function _requireCallerIsBOorLOorRO() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == liquidatorOperationsAddress ||
            msg.sender == redeemerOperationsAddress,
            "TroveManager: Caller is neither BorrowerOperations or LiquidatorOperations or RedeemerOperations");
    }

    function _requireTroveIsNotActive(address _borrower, address _asset) internal view {
        require(Troves[_borrower][_asset].status != Status.active, "TroveManager: trove is already active");
    }

    function _requireTroveIsActive(address _borrower, address _asset) internal view {
        require(Troves[_borrower][_asset].status == Status.active, "TroveManager: Trove does not exist or is closed");
    }

    function _requireMoreThanOneTroveInSystem(address _asset) internal view {
        require(sortedTroves.getSize(_asset) > 1, "TroveManager: Only one trove in the system");
    }

    function _requireAmountGreaterThanZero(uint _amount) internal pure {
        require(_amount > 0, "TroveManager: Amount must be greater than zero");
    }

    function _requireClosedStatus(Status _status) internal pure {
        require(_status != Status.nonExistent && _status != Status.active, "TroveManager: no closed status");
    }

}
