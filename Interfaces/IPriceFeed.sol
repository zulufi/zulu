// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface IPriceFeed {
    // --- Events ---
    /// @notice The event emitted when the stored price is updated
    event PriceUpdated(address indexed token, uint256 price);

    // --- Function ---
    function getPrice(address token) external view returns (uint256);

    function fetchPrice(address token) external returns (uint256);
}
