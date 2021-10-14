// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Dependencies/CheckContract.sol";
import "../Interfaces/ITroveManagerV2.sol";


contract TroveManagerScript is CheckContract {
    string constant public NAME = "TroveManagerScript";

    ITroveManagerV2 immutable troveManager;

    constructor(ITroveManagerV2 _troveManager) public {
        checkContract(address(_troveManager));
        troveManager = _troveManager;
    }
}
