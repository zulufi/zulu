// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Interfaces/ILocker.sol";

abstract contract Lockable {
    ILocker public locker;

    modifier mutex() {
        locker.lock();
        _;
        locker.unlock();
    }

    modifier notLocked() {
        _requireNotLocked();
        _;
    }

    function _requireNotLocked() internal view {
        require(locker.getLockStatus() == 0, "Operation is in locked status");
    }
}
