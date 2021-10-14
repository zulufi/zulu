// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

/**
 * Original file: https://github.com/aave/price-aggregators/blob/master/contracts/lp-oracle-contracts/mock/UniswapV2FactoryMock.sol
 */
contract UniswapV2FactoryMock {
    address _feeTo;

    constructor(address __feeTo) public {
        _feeTo = __feeTo;
    }

    function feeTo() external view returns (address) {
        return _feeTo;
    }
}
