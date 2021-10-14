// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

// Common interface for the Pools.
interface IPayablePool {
    // --- Functions ---
    function increaseAssetBalance(address _asset, uint _amount) external;
}