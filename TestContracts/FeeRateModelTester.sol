// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "../FeeRateModel.sol";
import "../Dependencies/SafeMath.sol";

contract FeeRateModelTester is FeeRateModel {

    using SafeMath for uint;

    function setBaseRate(uint rate) external {
        baseRate = rate;
    }

    function setLastFeeOpTimeToNow() external {
        lastFeeOperationTime = block.timestamp;
    }

    function unprotectedDecayBaseRateFromBorrowing() external {
        updateBaseRateFromBorrowing();
    }
}
