// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Dependencies/LiquityMath.sol";

/* Tester contract for math functions in Math.sol library. */

contract LiquityMathTester {

    function callMax(uint _a, uint _b) external pure returns (uint) {
        return LiquityMath._max(_a, _b);
    }

    function callMin(uint _a, uint _b) external pure returns (uint) {
        return LiquityMath._min(_a, _b);
    }

    function callDecMul(uint _a, uint _b) external pure returns (uint) {
        return LiquityMath.decMul(_a, _b);
    }

    // Non-view wrapper for gas test
    function callDecPowTx(uint _base, uint _n) external returns (uint) {
        return LiquityMath._decPow(_base, _n);
    }

    function callGetAbsoluteDifference(uint _a, uint _b) external pure returns (uint) {
        return LiquityMath._getAbsoluteDifference(_a, _b);
    }

    // External wrapper
    function callDecPow(uint _base, uint _n) external pure returns (uint) {
        return LiquityMath._decPow(_base, _n);
    }

    function callComputeNCR(uint _coll, uint _debt) external pure returns (uint) {
        return LiquityMath._computeNominalCR(_coll, _debt);
    }

    function callComputeCR(uint _coll, uint _decimalsOfColl, uint _debt, uint _price) external pure returns (uint) {
        return LiquityMath._computeCR(_coll, _decimalsOfColl, _debt, _price);
    }
}
