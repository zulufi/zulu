// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface IAlpacaFarmer {
    // --- Events ---
    event TroveManagerAddressChanged(address _troveManagerAddress);
    event BorrowerOperationsAddressChanged(address _borrowerOperationsAddress);
    event LiquidatorOperationsAddressChanged(address _liquidatorOperationsAddress);
    event RedeemerOperationsAddressChanged(address _redeemerOperationsAddress);
    event StabilityPoolAddressChanged(address _stabilityPoolAddress);
    event FairLaunchAddressChanged(address _fairLaunchAddress);
    event ReserveFactorChanged(uint256 _reserveFactor);

    event VaultDeposited(address indexed _asset, uint256 _amount, uint256 _share);
    event VaultWithdrawn(address indexed _asset, uint256 _share, uint256 _amount);
    event Staked(address indexed _asset, uint256 _share);
    event Unstaked(address indexed _asset, uint256 _share);
    event AlpacaBalanceUpdated(address indexed _asset, uint256 _newBalance);
    event A_Updated(address indexed _asset, uint256 _A);
    event UserSnapshotUpdated(address indexed _asset, address indexed _user, uint256 _A);
    event AlpacaSent(address indexed _asset, address indexed _to, uint256 _amount);
    event AlpacaWithdrawn(address indexed _asset, address indexed _to, uint256 _amount);
    event IBTokenWithdrawn(address indexed _asset, address indexed _to, uint256 _amount);

    // --- Functions ---
    function updateReserveFactor(uint256 _reserveFactor) external;

    function withdrawAlpaca(
        address _asset,
        address _account,
        uint256 _amount
    ) external;

    function withdrawIBToken(
        address _asset,
        address _account,
        uint256 _amount
    ) external;

    function getPendingAlpaca(address _asset, address _user) external view returns (uint256);
}
