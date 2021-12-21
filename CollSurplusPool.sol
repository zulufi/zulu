// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/IAssetConfigManager.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/OwnableUpgradeable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/console.sol";
import "./TransferHelper.sol";


contract CollSurplusPool is OwnableUpgradeable, CheckContract, ICollSurplusPool {
    using SafeMath for uint256;
    using TransferHelper for address;

    string constant public NAME = "CollSurplusPool";

    IAssetConfigManager public assetConfigManager;

    address public borrowerOperationsAddress;
    address public liquidatorOperationsAddress;
    address public redeemerOperationsAddress;
    address public activePoolAddress;

    // deposited ether tracker
    mapping (address => uint256) internal assetBalances;
    // Collateral surplus claimable by trove owners and asset
    mapping (address => mapping (address => uint)) internal balances;

    // --- Contract setters ---

    function initialize() public initializer {
        __Ownable_init();
    }

    function setAddresses(
        address _assetConfigManagerAddress,
        address _borrowerOperationsAddress,
        address _liquidatorOperationsAddress,
        address _redeemerOperationsAddress,
        address _activePoolAddress
    )
        external
        override
        onlyOwner
    {
        require(borrowerOperationsAddress == address(0), "address has already been set");

        checkContract(_assetConfigManagerAddress);
        checkContract(_borrowerOperationsAddress);
        checkContract(_liquidatorOperationsAddress);
        checkContract(_redeemerOperationsAddress);
        checkContract(_activePoolAddress);

        assetConfigManager = IAssetConfigManager(_assetConfigManagerAddress);
        borrowerOperationsAddress = _borrowerOperationsAddress;
        liquidatorOperationsAddress = _liquidatorOperationsAddress;
        redeemerOperationsAddress = _redeemerOperationsAddress;
        activePoolAddress = _activePoolAddress;

        emit AssetConfigManagerAddressChanged(_assetConfigManagerAddress);
        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit LiquidatorOperationsAddressChanged(_liquidatorOperationsAddress);
        emit RedeemerOperationsAddressChanged(_redeemerOperationsAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);
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
        DataTypes.AssetConfig memory config = assetConfigManager.get(_asset);
        _requireCallerIsActivePoolorFarmer(config.farmerAddress);
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

    function _requireCallerIsActivePoolorFarmer(address _farmerAddress) internal view {
        require(
            (_farmerAddress == address(0) && msg.sender == activePoolAddress) ||
            (_farmerAddress != address(0) && msg.sender == _farmerAddress),
            "CollSurplusPool: Caller is not Active Pool nor Farmer");
    }

    receive() external payable {
    }
}
