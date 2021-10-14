// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;


// Common interface for the Trove Manager.
interface ITroveManagerV2 {

    enum Status {
        nonExistent,
        active,
        closedByOwner,
        closedByLiquidation,
        closedByRedemption
    }

    struct DebtR {
        uint rate; // rate of seconds, has a decimal of DECIMAL_PRECISION
        uint timestamp;
        uint R; // decPow(decimal + rate, t)
    }

    // --- Events ---

    event BorrowerOperationsAddressChanged(address _borrowerOperationsAddress);
    event LiquidatorOperationsAddressChanged(address _liquidatorOperationsAddress);
    event RedeemerOperationsAddressChanged(address _RedeemerOperationsAddress);
    event SortedTrovesAddressChanged(address _sortedTrovesAddress);
    event CakeMinerAddressChanged(address _cakeMinerAddress);
    event AssetConfigManagerAddressChanged(address _assetConfigManagerAddress);
    event GlobalConfigManagerAddressChanged(address _globalConfigManagerAddress);
    event CommunityIssuanceAddressChanged(address _globalConfigManagerAddress);

    event TroveOpened(address indexed _asset, address indexed _borrower, uint _debt, uint _nDebt, uint _coll, uint _stake, uint _gasCompensation, uint _arrayIndex);
    event TroveUpdated(address indexed _asset, address indexed _borrower, uint _debt, uint _nDebt, uint _coll, uint _stake);
    event TroveClosed(address indexed _asset, address indexed _borrower, Status _closedStatus);
    event TotalStakesUpdated(address indexed _asset, uint _newTotalStakes);
    event SystemSnapshotsUpdated(address indexed _asset, uint _totalStakesSnapshot, uint _totalCollateralSnapshot);
    event L_LUSDDebtsUpdated(address indexed _asset, address indexed _borrower, uint _L_LUSDDebt);
    event ApplyDebtRewards(address indexed _asset, address indexed _borrower, uint _pendingNormalizedDebt, uint _newNormalizedDebt);
    event DebtRewardSnapshotUpdated(address indexed _asset, address indexed _borrower, uint _L_LUSDDebt);
    event L_LQTYRewardsUpdated(address indexed _asset, uint _L_LQTYReward);
    event ApplyLQTYRewards(address indexed _asset, address indexed _borrower, uint _appliedRewards);
    event IssueLQTYRewards(address indexed _asset, address indexed _borrower, uint _issuedRewards);
    event LQTYRewardSnapshotUpdated(address indexed _asset, address indexed _borrower, uint _L_LQTYReward);
    event TroveIndexUpdated(address indexed _asset, address _borrower, uint _newIndex);
    event DebtRUpdated(address indexed _asset, uint _newRate, uint _newR);

    // --- Functions ---

    function setAddresses(
        address _borrowerOperationsAddress,
        address _liquidatorOperationsAddress,
        address _redeemerOperationsAddress,
        address _sortedTrovesAddress,
        address _cakeMinerAddress,
        address _assetConfigManagerAddress,
        address _globalConfigManagerAddress,
        address _communityIssuanceAddress
    ) external;

    function setDebtRate(address _asset, uint _rate) external;

    function openTrove(
        address _borrower,
        address _asset,
        uint _coll,
        uint _debt,
        uint _gasCompensation,
        uint _price,
        address _upperHint,
        address _lowerHint
    ) external;

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
    ) external;

    function closeTrove(
        address _borrower,
        address _asset,
        uint _price,
        uint _redistributedColl,
        uint _redistributedDebt,
        Status closedStatus
    ) external;

    function issueLQTYRewards(address _borrower, address _asset) external returns (uint);

    function getLastNTroveOwners(address _asset, uint _n) external view returns (address[] memory);

    function getLastNTrovesAboveMCR(address _asset, uint _n, address _firstHint, uint _price) external view returns (address[] memory);

    function getTroveOwnersCount(address _asset) external view returns (uint);

    function getTroveFromTroveOwnersArray(address _asset, uint _index) external view returns (address);

    function isUnderCollateralized(address _borrower, address _asset, uint _price) external view returns (bool);

    function getNominalICR(address _borrower, address _asset) external view returns (uint);

    function computeNominalICR(address _asset, uint _coll, uint _debt) external view returns (uint);

    function getCurrentICR(address _borrower, address _asset, uint _price) external view returns (uint);

    function getPendingLUSDDebtReward(address _borrower, address _asset) external view returns (uint);

    function getTroveDebtAndColl(address _borrower, address _asset) external view returns (
        uint debt,
        uint coll
    );

    function getEntireSystemColl(address _asset) external view returns (uint);

    function getEntireSystemDebt(address _asset) external view returns (uint);

    function getEntireSystemGasCompensation(address _asset) external view returns (uint);

    function getTotalDebts() external view returns (uint);

    function getTotalStakes(address _asset) external view returns (uint);

    function getTroveStatus(address _borrower, address _asset) external view returns (uint);

    function getTroveStake(address _borrower, address _asset) external view returns (uint);

    function getTroveDebt(address _borrower, address _asset) external view returns (uint);

    function getTroveColl(address _borrower, address _asset) external view returns (uint);

    function getTroveGasCompensation(address _borrower, address _asset) external view returns (uint);

    function getTCR(address _asset, uint _price) external view returns (uint);

    function checkRecoveryMode(address _asset, uint _price) external view returns (bool);
}
