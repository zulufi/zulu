// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface IActivePool {
    // --- Events ---
    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event LiquidatorOperationsAddressChanged(address _liquidatorOperationsAddress);
    event RedeemerOperationsAddressChanged(address _redeemerOperationsAddress);
    event GlobalConfigManagerAddressChanged(address _globalConfigManagerAddress);
    event StabilityPoolAddressChanged(address _newStabilityPoolAddress);

    event AssetSent(address indexed _address, address indexed _to, uint _amount);

    // --- Functions ---
    function sendAsset(address _asset, address _account, uint _amount) external;

    function sendAssetToPool(address _asset, address _pool, uint _amount) external;
}
