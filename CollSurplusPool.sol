// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/ICollSurplusPool.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/OwnableUpgradeable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/console.sol";
import "./TransferHelper.sol";


contract CollSurplusPool is OwnableUpgradeable, CheckContract, ICollSurplusPool {
    using SafeMath for uint256;
    using TransferHelper for address;

    string constant public NAME = "CollSurplusPool";

    address public borrowerOperationsAddress;
    address public liquidatorOperationsAddress;
    address public redeemerOperationsAddress;
    address public activePoolAddress;
    address public cakeMinerAddress;

    // deposited ether tracker
    mapping (address => uint256) internal assetBalances;
    // Collateral surplus claimable by trove owners and asset
    mapping (address => mapping (address => uint)) internal balances;

    // --- Contract setters ---

    function initialize() public initializer {
        __Ownable_init();
    }

    function setAddresses(
        address _borrowerOperationsAddress,
        address _liquidatorOperationsAddress,
        address _redeemerOperationsAddress,
        address _activePoolAddress,
        address _cakeMinerAddress
    )
        external
        override
        onlyOwner
    {
        require(borrowerOperationsAddress == address(0), "address has already been set");

        checkContract(_borrowerOperationsAddress);
        checkContract(_liquidatorOperationsAddress);
        checkContract(_redeemerOperationsAddress);
        checkContract(_activePoolAddress);
        checkContract(_cakeMinerAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        liquidatorOperationsAddress = _liquidatorOperationsAddress;
        redeemerOperationsAddress = _redeemerOperationsAddress;
        activePoolAddress = _activePoolAddress;
        cakeMinerAddress = _cakeMinerAddress;

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit LiquidatorOperationsAddressChanged(_liquidatorOperationsAddress);
        emit RedeemerOperationsAddressChanged(_redeemerOperationsAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);
        emit CakeMinerAddressChanged(_cakeMinerAddress);
    }

    /* Returns the asset's balance at CollSurplusPool address.
       Not necessarily equal to the raw balance - asset can be forcibly sent to contracts. */
    function getAssetBalance(address _asset) external view override returns (uint) {
        return assetBalances[_asset];
    }

    function getCollateral(address _account, address _asset) external view override returns (uint) {
        return balances[_account][_asset];
    }

    // --- Pool functionality ---

    function accountSurplus(address _account, address _asset, uint _amount) external override {
        _requireCallerIsLOorRO();

        balances[_account][_asset] = balances[_account][_asset].add(_amount);

        emit CollBalanceUpdated(_account, _asset, balances[_account][_asset]);
    }

    function claimColl(address _account, address _asset) external override {
        _requireCallerIsBorrowerOperations();
        uint claimableColl = balances[_account][_asset];
        require(claimableColl > 0, "CollSurplusPool: No collateral available to claim");

        balances[_account][_asset] = 0;
        emit CollBalanceUpdated(_account, _asset, 0);

        assetBalances[_asset] = assetBalances[_asset].sub(claimableColl);

        emit AssetBalanceUpdated(_asset, assetBalances[_asset]);
        emit AssetSent(_account, _asset, claimableColl);

        address(_asset).safeTransferToken(_account, claimableColl);
    }

    function increaseAssetBalance(address _asset, uint _amount) external override {
        _requireCallerIsActivePoolorCakeMiner();
        assetBalances[_asset] = assetBalances[_asset].add(_amount);

        emit AssetBalanceUpdated(_asset, assetBalances[_asset]);
    }

    // --- 'require' functions ---

    function _requireCallerIsBorrowerOperations() internal view {
        require(
            msg.sender == borrowerOperationsAddress,
            "CollSurplusPool: Caller is not Borrower Operations");
    }

    function _requireCallerIsLOorRO() internal view {
        require(
            msg.sender == liquidatorOperationsAddress ||
            msg.sender == redeemerOperationsAddress,
            "CollSurplusPool: Caller is neither LiquidatorOperations nor RedeemerOperations");
    }

    function _requireCallerIsActivePoolorCakeMiner() internal view {
        require(
            msg.sender == activePoolAddress || msg.sender == cakeMinerAddress,
            "CollSurplusPool: Caller is not Active Pool nor CakeMiner");
    }

    receive() external payable {
        _requireCallerIsActivePoolorCakeMiner();
    }
}
