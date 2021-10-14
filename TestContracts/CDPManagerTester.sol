// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "../TroveManagerV2.sol";

/* Tester contract inherits from TroveManager, and provides external functions 
for testing the parent's internal functions. */

contract TroveManagerTester is TroveManagerV2 {

    // use for test
    function setParams(address _borrowerOperationsAddress) external onlyOwner {
        borrowerOperationsAddress = _borrowerOperationsAddress;
        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
    }

    function computeICR(address _asset, uint _coll, uint _debt, uint _price) external view returns (uint) {
        return LiquityMath._computeCR(_coll, assetConfigManager.get(_asset).decimals, _debt, _price);
    }

    function getCollGasCompensation(address _asset, uint _coll) external view returns (uint) {
        uint divisor = assetConfigManager.get(_asset).liquidationBonusDivisor;
        return _coll.div(divisor);
    }

    function getLUSDGasCompensation() public view returns (uint) {
        return globalConfigManager.getGasCompensation();
    }

    function getCompositeDebt(uint _debt) external view returns (uint) {
        return _debt.add(getLUSDGasCompensation());
    }

    function getActualDebtFromComposite(uint _debt) external view returns (uint) {
        return _debt.sub(getLUSDGasCompensation());
    }

    function callInternalRemoveTroveOwner(address _troveOwner, address _asset) external {
        _removeTroveOwner(_troveOwner, _asset);
    }
}
