// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "../Dependencies/IERC20.sol";
import "../Dependencies/IERC2612.sol";

interface ILQTYToken is IERC20, IERC2612 {
    struct Checkpoint {
        uint256 blockNo;
        uint256 balance;
    }

    // --- Events ---

    event CommunityIssuanceAddressSet(address _communityIssuanceAddress);
    event LQTYStakingAddressSet(address _lqtyStakingAddress);
    event LockupContractFactoryAddressSet(address _lockupContractFactoryAddress);
    event CheckpointUpdated(
        address indexed _account,
        uint256 indexed _index,
        Checkpoint _checkpoint
    );

    // --- Functions ---

    function getCurrentVotes(address account) external view returns (uint256);

    function getPriorVotes(address account, uint256 blockNo) external view returns (uint256);

    function sendToLQTYStaking(address _sender, uint256 _amount) external;

    function getDeploymentStartTime() external view returns (uint256);

    function getLpRewardsEntitlement() external view returns (uint256);

    function getCommunityIssuanceEntitlement() external view returns (uint256);

    function getLockupPeriod() external view returns (uint256);
}
