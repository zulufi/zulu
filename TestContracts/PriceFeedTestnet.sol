// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Interfaces/IPriceFeed.sol";
import "../Dependencies/Initializable.sol";

/*
* PriceFeed placeholder for testnet and development. The price is simply set manually and saved in a state
* variable. The contract does not connect to a live Chainlink price feed.
*/
contract PriceFeedTestnet is IPriceFeed, Initializable {

    uint256 private _price;

    // asset address => price
    mapping(address => uint256) private _prices;

    function initialize() public initializer {
        _price = 200 * 1e18;
    }

    // --- Functions ---

    // View price getter for simplicity in tests
    function getPrice(address asset) external override view returns (uint256) {
        if (_prices[asset] != 0) {
            return _prices[asset];
        }
        return _price;
    }

    function fetchPrice(address asset) external override returns (uint256) {
        if (_prices[asset] != 0) {
            return _prices[asset];
        }
        return _price;
    }

    // Manual external price setter.
    function setPrice(uint256 price) external returns (bool) {
        _price = price;
        return true;
    }

    function setAssetPrice(address asset, uint256 price) external returns (bool) {
        _prices[asset] = price;
        return true;
    }
}
