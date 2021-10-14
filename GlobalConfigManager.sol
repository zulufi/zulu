// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Dependencies/CheckContract.sol";
import "./Dependencies/OwnableUpgradeable.sol";
import "./Interfaces/IGlobalConfigManager.sol";
import "./Dependencies/console.sol";

contract GlobalConfigManager is CheckContract, IGlobalConfigManager, OwnableUpgradeable {

    uint private gasCompensation;

    function initialize() public initializer {
        __Ownable_init();
    }

    function setGasCompensation(uint _gasCompensation)
        external
        override
        onlyOwner
    {
        require(_gasCompensation > 0, "invalid gas compensation");
        gasCompensation = _gasCompensation;
        emit GasCompensationUpdated(_gasCompensation);
    }

    function getGasCompensation()
        external
        view
        override
        returns (uint)
    {
        return gasCompensation;
    }
}