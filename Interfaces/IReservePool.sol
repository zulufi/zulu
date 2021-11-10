// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface IReservePool {
    // --- Events ---
    event BorrowerOperationsAddressChanged(address _borrowerOperationsAddress);
    event RedeemerOperationsAddressChanged(address _redeemerOperationsAddress);
    event TroveManagerAddressChanged(address _troveManagerAddress);
    event LUSDTokenAddressChanged(address _lusdTokenAddress);
    event LUSDBalanceUpdated(address indexed _asset, uint _newBalance);
    event AssetBalanceUpdated(address indexed _asset, uint _newBalance);
    event LUSDInterestUpdated(address indexed _asset, uint _newBalance);

    // --- Functions ---

    function getLUSDBalance(address _asset) external view returns (uint);
    function getAssetBalance(address _asset) external view returns (uint);
    function getLUSDInterest(address _asset) external view returns (uint);
    function withdraw(address _asset, address _account, uint _amount) external;
    function withdrawAsset(address _asset, address _account, uint) external;
    function withdrawLUSDInterest(address _asset, address _account, uint) external;
    function depositLUSD(address _asset, uint _amount) external;
    function depositAsset(address _asset, uint _amount) external;
    function depositLUSDInterest(address _asset, uint _amount) external;
}
