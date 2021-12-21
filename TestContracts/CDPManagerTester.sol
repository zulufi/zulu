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

    function computeDebtRate(uint _annualRate) external view returns (uint, uint) {
        uint _target = DECIMAL_PRECISION.add(_annualRate);
        uint _current = DECIMAL_PRECISION;
        uint _minAnnualRate = DECIMAL_PRECISION;
        uint _upperRate = 1e12;
        uint _rate = 0;
        uint _minRate = 0;
        uint _minDiff = _target.sub(_minAnnualRate);
        while (_rate < _upperRate) {
            uint _mid = _rate.add(_upperRate).div(2);
            if (_rate == _mid) {
                break;
            }
            uint _base = _mid.add(DECIMAL_PRECISION);
            _current = LiquityMath._baseDecPow(_base, 31536000);
            if (_current > _target) {
                _upperRate = _mid;
            } else {
                _rate = _mid;
            }
            uint _diff = _current > _target ? _current.sub(_target) : _target.sub(_current);
            if (_diff < _minDiff) {
                _minAnnualRate = _current.sub(DECIMAL_PRECISION);
                _minRate = _mid;
                _minDiff = _diff;
            }
        }
        return (_minRate, _minAnnualRate);
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
