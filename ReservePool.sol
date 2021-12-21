// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/IReservePool.sol";
import "./Dependencies/OwnableUpgradeable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/SafeMath.sol";
import "./Interfaces/ILUSDToken.sol";
import "./TransferHelper.sol";

contract ReservePool is OwnableUpgradeable, CheckContract, IReservePool {
    using SafeMath for uint256;
    using TransferHelper for address;

    string constant public NAME = "ReservePool";

    address public borrowerOperationsAddress;
    address public redeemerOperationsAddress;
    address public troveManagerAddress;
    mapping (address => uint256) internal assetLUSDBalances;
    mapping (address => uint256) internal assetBalances;
    mapping (address => uint256) internal assetLUSDInterests;
    ILUSDToken public lusdToken;

    function initialize() public initializer {
        __Ownable_init();
    }

    function setAddresses(
        address _borrowerOperationsAddress,
        address _redeemerOperationsAddress,
        address _troveManagerAddress,
        address _lusdTokenAddress
    )
    external
    onlyOwner
    {
        require(borrowerOperationsAddress == address(0), "address has already been set");

        checkContract(_borrowerOperationsAddress);
        checkContract(_redeemerOperationsAddress);
        checkContract(_troveManagerAddress);
        checkContract(_lusdTokenAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        redeemerOperationsAddress = _redeemerOperationsAddress;
        troveManagerAddress = _troveManagerAddress;
        lusdToken = ILUSDToken(_lusdTokenAddress);

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit RedeemerOperationsAddressChanged(_redeemerOperationsAddress);
        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit LUSDTokenAddressChanged(_lusdTokenAddress);
    }

    // TODO: require _account to some contract address
    function withdraw(address _asset, address _account, uint _amount) onlyOwner external override {
        require(_account != address(0), "ReservePool: can't withdraw to address(0)");
        assetLUSDBalances[_asset] = assetLUSDBalances[_asset].sub(_amount, "ReservePool: has no enough balance");
        emit LUSDBalanceUpdated(_asset, assetLUSDBalances[_asset]);
        lusdToken.transfer(_account, _amount);
    }

    function withdrawAsset(address _asset, address _account, uint _amount) onlyOwner external override {
        require(_account != address(0), "ReservePool: can't withdraw to address(0)");
        assetBalances[_asset] = assetBalances[_asset].sub(_amount, "ReservePool: has no enough balance");
        emit AssetBalanceUpdated(_asset, assetBalances[_asset]);
        address(_asset).safeTransferToken(_account, _amount);
    }

    function withdrawLUSDInterest(address _asset, address _account, uint _amount) onlyOwner external override {
        require(_account != address(0), "ReservePool: can't withdraw to address(0)");
        assetLUSDInterests[_asset] = assetLUSDInterests[_asset].sub(_amount, "ReservePool: has no enough balance");
        emit LUSDInterestUpdated(_asset, assetLUSDInterests[_asset]);
        lusdToken.transfer(_account, _amount);
    }

    // called after real transfer LUSD to the reservePool
    function depositLUSD(address _asset, uint _amount) external override {
        _requireCallerIsBOorRO();
        assetLUSDBalances[_asset] = assetLUSDBalances[_asset].add(_amount);
        emit LUSDBalanceUpdated(_asset, assetLUSDBalances[_asset]);
    }

    // called after real transfer asset to the reservePool
    function depositAsset(address _asset, uint _amount) external override {
        _requireCallerIsBOorRO();
        uint _newBalance = assetBalances[_asset].add(_amount);
        assetBalances[_asset] = _newBalance;
        emit AssetBalanceUpdated(_asset, _newBalance);
    }

    function depositLUSDInterest(address _asset, uint _amount) external override {
        _requireCallerIsTM();
        uint _newBalance = assetLUSDInterests[_asset].add(_amount);
        assetLUSDInterests[_asset] = _newBalance;
        emit LUSDInterestUpdated(_asset, _newBalance);
    }

    function getLUSDBalance(address _asset) external view override returns (uint) {
        return assetLUSDBalances[_asset];
    }

    function getAssetBalance(address _asset) external view override returns (uint) {
        return assetBalances[_asset];
    }

    function getLUSDInterest(address _asset) external view override returns (uint) {
        return assetLUSDInterests[_asset];
    }

    function _requireCallerIsTM() internal view {
        require(
            msg.sender == troveManagerAddress,
            "ReservePool: Caller must be TM");
    }

    function _requireCallerIsBOorRO() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == redeemerOperationsAddress,
            "ReservePool: Caller must be BO or RO");
    }

    receive() external payable {
    }
}
