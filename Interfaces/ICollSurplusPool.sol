// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./IPayablePool.sol";

interface ICollSurplusPool is IPayablePool {

    // --- Events ---

    event AssetConfigManagerAddressChanged(address _assetConfigManagerAddress);
    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event LiquidatorOperationsAddressChanged(address _liquidatorOperationsAddress);
    event RedeemerOperationsAddressChanged(address _redeemerOperationsAddress);
    event ActivePoolAddressChanged(address _newActivePoolAddress);

    event AssetBalanceUpdated(address indexed _asset, uint _balance);
    event CollBalanceUpdated(address indexed _account, address indexed _asset, uint _newBalance);
    event AssetSent(address indexed _to, address indexed _asset, uint _amount);

    // --- Contract setters ---

    function setAddresses(
        address _assetConfigManagerAddress,
        address _borrowerOperationsAddress,
        address _liquidatorOperationsAddress,
        address _redeemerOperationsAddress,
        address _activePoolAddress
    ) external;

    function getAssetBalance(address _asset) external view returns (uint);

    function getCollateral(address _account, address _asset) external view returns (uint);

    function accountSurplus(address _account, address _asset, uint _amount) external;

    function claimColl(address _account, address _asset) external;
}
