// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface IGlobalConfigManager {

    // events
    event GasCompensationUpdated(uint newValue);

    // setters
    function setGasCompensation(uint gasCompensation) external;

    // getters
    function getGasCompensation() external view returns (uint);

}
