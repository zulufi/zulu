// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./OwnableUpgradeable.sol";

// Common interface for contract that supports multiple asset.
abstract contract MultiAssetInitializable is OwnableUpgradeable {

    mapping(address => bool) public initializedAssets;
    mapping (address => uint) public assetInitTimes;

    modifier onlySupportedAsset(address asset) {
        require(initializedAssets[asset], "Asset not supported");
        _;
    }

    event AssetInitialized(address indexed asset);

    function initializeAsset(address asset, bytes calldata data) external onlyOwner {
        require(!initializedAssets[asset], "Asset is already supported");
        initializedAssets[asset] = true;
        initializeAssetInternal(asset, data);
        assetInitTimes[asset] = block.timestamp;
        emit AssetInitialized(asset);
    }

    function initializeAssetInternal(address asset, bytes calldata data) virtual internal;

}