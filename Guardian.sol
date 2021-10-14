// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Dependencies/OwnableUpgradeable.sol";
import "./Interfaces/IGuardian.sol";

contract Guardian is IGuardian, OwnableUpgradeable {

    // opKey => boolean
    mapping (uint => bool) private globalGuards;

    // asset address => opKey => boolean
    mapping (address => mapping (uint => bool)) private assetGuards;

    function initialize() public initializer {
        __Ownable_init();
    }

    function globalGuard(uint opKey) override onlyOwner external {
        globalGuards[opKey] = true;
        emit GlobalOperationGuarded(opKey);
    }

    function guard(address asset, uint opKey) override onlyOwner external {
        assetGuards[asset][opKey] = true;
        emit OperationGuarded(asset, opKey);
    }

    function globalUnguard(uint opKey) override onlyOwner external {
        globalGuards[opKey] = false;
        emit GlobalOperationUnguarded(opKey);
    }

    function unguard(address asset, uint opKey) override onlyOwner external {
        assetGuards[asset][opKey] = false;
        emit OperationUnguarded(asset, opKey);
    }

    function globalGuarded(uint opKey) override external view returns (bool) {
        return globalGuards[opKey];
    }

    function guarded(address asset, uint opKey) override external view returns (bool) {
        return assetGuards[asset][opKey];
    }
}
