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

    event StabilityRewardSpeedUpdated(address _asset, uint _speed);
    event LiquidityRewardSpeedUpdated(address _asset, uint _speed);
    event StabilityLQTYAccrued(address _asset, uint _totalLQTYAccrued);
    event LiquidityLQTYAccrued(address _asset, uint _totalLQTYAccrued);
    event L_SnapshotUpdated(address _asset, uint _lastTimestamp);
    event S_SnapshotUpdated(address _asset, uint _lastTimestamp);
    event StabilityLQTYIssued(address _asset, uint _issuedLQTY);
    event LiquidityLQTYIssued(address _asset, uint _issuedLQTY);

    // --- Functions ---

    function setAddresses(
        address _lqtyTokenAddress,
        address _stabilityPoolAddress,
        address _troveManagerAddress,
        address _borrowerOperationsAddress,
        address _liquidatorOperationsAddress,
        address _redeemerOperationsAddress
    ) external;

    function updateStabilitySpeed(address _asset, uint _speed) external;

    function issueStabilityLQTY(address _asset) external returns (uint);

    function updateLiquiditySpeed(address _asset, uint _speed) external;

    function issueLiquidityLQTY(address _asset) external returns (uint);

    function sendLQTY(address _account, uint _LQTYamount) external;
}
