// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Interfaces/IGuardian.sol";

abstract contract Guardable {

    IGuardian public guardian;

    modifier guardianGlobalAllowed(uint opKey) {
        require(!guardian.globalGuarded(opKey), "Operation is paused");
        _;
    }

    modifier guardianAllowed(address asset, uint opKey) {
        require(!guardian.guarded(asset, opKey), "Operation is paused");
        _;
    }
}
