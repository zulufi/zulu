// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "../LQTY/CommunityIssuance.sol";

contract CommunityIssuanceTester is CommunityIssuance {
    function obtainLQTY(uint _amount) external {
        lqtyToken.transfer(msg.sender, _amount);
    }

    function unprotectedIssueStabilityLQTY(address _asset) external returns (uint) {
        uint latestAccruedReward = _accrueStabilityLQTY(_asset);
        if (latestAccruedReward > 0) {
            accruedStabilityRewards[_asset] = 0;
        }

        emit StabilityLQTYIssued(_asset, latestAccruedReward);
        return latestAccruedReward;
    }

    function unprotectedIssueLiquidityLQTY(address _asset) external returns (uint) {
        uint latestAccruedReward = _accrueLiquidityLQTY(_asset);
        if (latestAccruedReward > 0) {
            accruedLiquidityRewards[_asset] = 0;
        }

        emit LiquidityLQTYIssued(_asset, latestAccruedReward);
        return latestAccruedReward;
    }
}
