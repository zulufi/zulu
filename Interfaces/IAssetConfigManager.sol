// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import {DataTypes} from "../Dependencies/DataTypes.sol";


interface IAssetConfigManager {

    event AssetConfigCreated(address indexed asset, DataTypes.AssetConfig config);
    event AssetConfigUpdated(address indexed asset, DataTypes.AssetConfig config);

    function create(DataTypes.AssetConfig memory config) external;
    function update(DataTypes.AssetConfig memory config) external;
    function get(address asset) external view returns (DataTypes.AssetConfig memory);
    function isSupported(address asset) external view returns (bool);
    function supportedAssets() external view returns (address[] memory);
}
