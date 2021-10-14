// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/ILocker.sol";
import "./Dependencies/OwnableUpgradeable.sol";

contract Locker is ILocker, OwnableUpgradeable {
    // 0 => unlocked, 1 => locked
    uint public _lockStatus;
    address public borrowerOperationsAddress;

    function setAddress(address _borrowerOperationsAddress) public onlyOwner {
        require(borrowerOperationsAddress == address(0), "address has already been set");
        borrowerOperationsAddress = _borrowerOperationsAddress;
    }

    function initialize() public initializer {
        __Ownable_init();
    }

    function lock() external override {
        _requireCallerIsBorrowerOperations();
        _lockStatus = 1;
    }

    function unlock() external override {
        _requireCallerIsBorrowerOperations();
        _lockStatus = 0;
    }

    function getLockStatus() external override view returns (uint) {
        return _lockStatus;
    }

    function _requireCallerIsBorrowerOperations() internal view {
        require(msg.sender == borrowerOperationsAddress, "Guardian: Caller is not the BorrowerOperations");
    }
}