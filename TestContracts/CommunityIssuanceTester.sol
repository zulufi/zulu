// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "../LQTY/CommunityIssuance.sol";

contract CommunityIssuanceTester is CommunityIssuance {
    function obtainLQTY(address _account, uint _LQTYamount) external {
        lqtyToken.transfer(_account, _LQTYamount);
    }

    function requireEnoughSupply(uint _issued) public view {
        _requireEnoughSupply(_issued);
    }
}
