// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface ILocker {
    function lock() external;
    function unlock() external;
    function getLockStatus() external view returns (uint);
}