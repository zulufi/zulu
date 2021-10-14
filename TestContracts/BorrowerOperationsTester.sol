// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "../BorrowerOperations.sol";

/* Tester contract inherits from BorrowerOperations, and provides external functions 
for testing the parent's internal functions. */
contract BorrowerOperationsTester is BorrowerOperations {

    function getUSDValue(uint _coll, uint _price) external pure returns (uint) {
        return _getUSDValue(_coll, _price);
    }

    function callInternalAdjustLoan
    (
        address _asset,
        address _borrower,
        uint _collWithdrawal,
        uint _debtChange, 
        bool _isDebtIncrease, 
        address _upperHint,
        address _lowerHint)
        external 
    {
        AdjustTroveInputValues memory inputValues = AdjustTroveInputValues(_asset, _borrower, _collWithdrawal, false, _debtChange, _isDebtIncrease, _upperHint, _lowerHint, 0);
        _adjustTrove(inputValues);
    }


    // Payable fallback function
    receive() external payable { }
}
