// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "../ReservePool.sol";

contract ReservePoolTester is ReservePool {
    // use for test
    function setParams(address _borrowerOperationsAddress, address _redeemerOperationsAddress, address _troveMangerAddress) external onlyOwner {
        borrowerOperationsAddress = _borrowerOperationsAddress;
        redeemerOperationsAddress = _redeemerOperationsAddress;
        troveManagerAddress = _troveMangerAddress;
    }
}
