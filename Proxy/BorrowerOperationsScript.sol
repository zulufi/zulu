// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Dependencies/CheckContract.sol";
import "../Interfaces/IBorrowerOperations.sol";


contract BorrowerOperationsScript is CheckContract {
    IBorrowerOperations immutable borrowerOperations;

    constructor(IBorrowerOperations _borrowerOperations) public {
        checkContract(address(_borrowerOperations));
        borrowerOperations = _borrowerOperations;
    }

    function openTrove(address _asset, uint _maxFee, uint _collAmount, uint _LUSDAmount, address _upperHint, address _lowerHint) external payable {
        borrowerOperations.openTrove{ value: msg.value }(_asset, _maxFee, _collAmount, _LUSDAmount, _upperHint, _lowerHint);
    }

    function addColl(address _asset, uint _collAmount, address _upperHint, address _lowerHint) external payable {
        borrowerOperations.addColl{ value: msg.value }(_asset, _collAmount, _upperHint, _lowerHint);
    }

    function withdrawColl(address _asset, uint _amount, address _upperHint, address _lowerHint) external {
        borrowerOperations.withdrawColl(_asset, _amount, _upperHint, _lowerHint);
    }

    function withdrawLUSD(address _asset, uint _maxFee, uint _amount, address _upperHint, address _lowerHint) external {
        borrowerOperations.withdrawLUSD(_asset, _maxFee, _amount, _upperHint, _lowerHint);
    }

    function repayLUSD(address _asset, uint _amount, address _upperHint, address _lowerHint) external {
        borrowerOperations.repayLUSD(_asset, _amount, _upperHint, _lowerHint);
    }

    function closeTrove(address _asset) external {
        borrowerOperations.closeTrove(_asset);
    }

    function claimCollateral(address _asset) external {
        borrowerOperations.claimCollateral(_asset);
    }
}
