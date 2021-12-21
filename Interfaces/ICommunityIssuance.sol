// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

interface ICommunityIssuance {

    // --- Events ---

    event LQTYTokenAddressSet(address _lqtyTokenAddress);
    event StabilityPoolAddressSet(address _stabilityPoolAddress);
    event TroveManagerAddressSet(address _troveManagerAddress);
    event BorrowerOperationsAddressSet(address _borrowerOperationsAddress);
    event LiquidatorOperationsAddressSet(address _liquidatorOperationsAddress);
    event RedeemerOperationsAddressSet(address _redeemerOperationsAddress);
    event TotalStabilityLQTYIssued(address _asset, uint _totalIssued);
    event TotalLiquidityLQTYIssued(address _asset, uint _totalIssued);

    // --- Functions ---

    function setAddresses(
        address _lqtyTokenAddress,
        address _stabilityPoolAddress,
        address _troveManagerAddress,
        address _borrowerOperationsAddress,
        address _liquidatorOperationsAddress,
        address _redeemerOperationsAddress
    ) external;

    function sendLQTY(address _account, uint _LQTYamount) external;

    function updateTotalStabilityLQTYIssued(address _asset, uint _issued) external;

    function updateTotalLiquidityLQTYIssued(address _asset, uint _issued) external;

    function increaseCap(address _from, uint _LQTYamount) external;
}
