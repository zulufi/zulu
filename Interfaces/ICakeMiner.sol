// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface ICakeMiner {
    // --- Events ---
    event TroveManagerAddressChanged(address _troveManagerAddress);
    event BorrowerOperationsAddressChanged(address _borrowerOperationsAddress);
    event LiquidatorOperationsAddressChanged(address _liquidatorOperationsAddress);
    event RedeemerOperationsAddressChanged(address _redeemerOperationsAddress);
    event StabilityPoolAddressChanged(address _stabilityPoolAddress);
    event MasterChefAddressChanged(address _masterChefAddress);
    event CakeAddressChanged(address _cakeAddress);
    event ReserveFactorChanged(uint256 _reserveFactor);

    event AssetAdded(address indexed _asset, uint256 _pid);
    event CakeSent(address indexed _asset, address indexed _to, uint256 _amount);
    event C_Updated(address indexed _asset, uint256 _C);
    event UserSnapshotUpdated(address indexed _asset, address indexed _user, uint256 _C);
    event Withdrawn(address indexed _asset, uint256 _amount);
    event AssetCakeBalanceUpdated(address indexed _asset, uint256 _newBalance);

    // --- Functions ---
    function updateReserveFactor(uint256 _reserveFactor) external;

    function withdrawCake(address _asset, address _account, uint256 _amount) external;

    function getPendingCake(address _asset, address _user) external view returns (uint256);
}
