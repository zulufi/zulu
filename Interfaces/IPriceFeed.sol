// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface IPriceFeed {
    // --- Function ---
    function getPrice(address token) external view returns (uint256);

    function fetchPrice(address token) external returns (uint256);
}
