// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface IFarmer {
    // --- Events ---
    event Deposited(address indexed _asset, uint256 _amount);
    event AssetSent(address indexed _asset, address indexed _to, uint256 _amount);
    event EmergencyStop(address indexed _operator);

    // --- Function ---
    function balanceOfAsset(address _asset) external view returns (uint256);

    function deposit(address _asset, uint256 _amount) external;

    function sendAsset(
        address _asset,
        address _user,
        uint256 _amount
    ) external;

    function sendAssetToPool(
        address _asset,
        address _pool,
        uint256 _amount
    ) external;

    function issueRewards(address _asset, address _user) external;

    function emergencyStop() external;
}
