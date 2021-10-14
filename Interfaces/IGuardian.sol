// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface IGuardian {

    event OperationGuarded(address indexed asset, uint indexed opKey);
    event GlobalOperationGuarded(uint indexed opKey);
    event OperationUnguarded(address indexed asset, uint indexed opKey);
    event GlobalOperationUnguarded(uint indexed opKey);

    function globalGuard(uint opKey) external;
    function guard(address asset, uint opKey) external;
    function globalUnguard(uint opKey) external;
    function unguard(address asset, uint opKey) external;
    function globalGuarded(uint opKey) external view returns (bool);
    function guarded(address asset, uint opKey) external view returns (bool);

}
