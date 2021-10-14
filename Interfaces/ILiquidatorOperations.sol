// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

interface ILiquidatorOperations {

    enum LiquidationMode {
        NORMAL,
        RECOVERY
    }

    event TroveManagerAddressChanged(address _troveManagerAddress);
    event PriceFeedAddressChanged(address _newPriceFeedAddress);
    event LUSDTokenAddressChanged(address _newLUSDTokenAddress);
    event ActivePoolAddressChanged(address _activePoolAddress);
    event CakeMinerAddressChanged(address _cakeMinerAddress);
    event StabilityPoolAddressChanged(address _stabilityPoolAddress);
    event GasPoolAddressChanged(address _gasPoolAddress);
    event CollSurplusPoolAddressChanged(address _collSurplusPoolAddress);
    event AssetConfigManagerAddressChanged(address _assetConfigManagerAddress);
    event GlobalConfigManagerAddressChanged(address _globalConfigManagerAddress);
    event GuardianAddressChanged(address _guardianAddress);
    event CommunityIssuanceAddressChanged(address _communityIssuanceAddress);
    event LockerAddressChanged(address _lockerAddress);

    event Liquidation(address indexed _asset, uint _liquidatedDebt, uint _liquidatedColl, uint _collGasCompensation, uint _LUSDGasCompensation);
    event TroveLiquidated(address indexed _asset, address indexed _borrower, uint _debt, uint _coll, LiquidationMode _mode);

    struct ContractAddresses {
        address troveManagerAddress;
        address priceFeedAddress;
        address activePoolAddress;
        address cakeMinerAddress;
        address stabilityPoolAddress;
        address gasPoolAddress;
        address collSurplusPoolAddress;
        address lusdTokenAddress;
        address assetConfigManagerAddress;
        address globalConfigManagerAddress;
        address guardianAddress;
        address communityIssuanceAddress;
        address lockerAddress;
    }

    function setAddresses(ContractAddresses memory addresses) external;

    function liquidate(address _borrower, address _asset) external;
    function liquidateTroves(address _asset, uint _n) external;
    function batchLiquidateTroves(address _asset, address[] calldata _troveArray) external;

}
