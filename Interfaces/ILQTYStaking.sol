// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

interface ILQTYStaking {
    struct Checkpoint {
        uint256 blockNo;
        uint256 totalStakes; // demand stakes + locked stakes
    }

    struct DemandStake {
        uint256 stakes;
        uint256 F; // snapshots of F, taken at the point at which their latest deposit was made
    }

    struct LockedStake {
        uint256 index;
        uint256 stakes;
        uint256 multiplier;
        uint256 stakeTime;
        uint256 unlockTime;
        uint256 F; // snapshots of F, taken at the point at which their latest deposit was made
        uint256 arrayIndex; // index of user locked stake array
    }

    // --- Events --

    event LQTYTokenAddressSet(address _lqtyTokenAddress);
    event LUSDTokenAddressSet(address _lusdTokenAddress);
    event BorrowerOperationsAddressSet(address _borrowerOperationsAddress);
    event RedeemerOperationsAddressSet(address _redeemerOperationsAddress);
    event GuardianAddressSet(address _guardianAddress);
    event LockerAddressSet(address _lockerAddress);
    event BonusMultiplierPerWeekSet(uint256 _bonusMultiplierPerWeek);
    event MaxMultiplierSet(uint256 _maxMultiplier);

    event DemandStakesUpdated(address indexed _user, DemandStake _newStake);
    event DemandSnapshotsUpdated(address indexed _user, uint256 _F);
    event DemandStakingGainsWithdrawn(address indexed _user, uint256 _LUSDGain);
    event LockedStaked(address indexed _user, uint256 indexed _index, LockedStake _stake);
    event LockedUnstaked(address indexed _user, uint256 indexed _index);
    event LockedSnapshotsUpdated(address indexed _user, uint256 indexed _index, uint256 _F);
    event LockedStakingGainsWithdrawn(
        address indexed _user,
        uint256 indexed _index,
        uint256 _LUSDGain
    );
    event FUpdated(uint256 _F);
    event TotalDemandStakesUpdated(uint256 _totalDemandStakes);
    event CheckpointUpdated(address indexed _user, uint256 indexed _index, Checkpoint _checkpoint);

    // --- Functions ---

    function setAddresses(
        address _lqtyTokenAddress,
        address _lusdTokenAddress,
        address _borrowerOperationsAddress,
        address _redeemerOperationsAddress,
        address _guardianAddress,
        address _lockerAddress
    )  external;

    function setBonusMultiplierPerWeek(uint256 _bonusMultiplierPerWeek) external;

    function setMaxMultiplier(uint256 _maxMultiplier) external;

    function totalStakesAt(address _user, uint256 _blockNo) external view returns (uint256);

    function stakeDemand(uint256 _LQTYamount) external;

    function unstakeDemand(uint256 _LQTYamount) external;

    function stakeLocked(uint256 _LQTYamount, uint256 _unlockTime) external;

    function unstakeLocked(uint256 _index) external;

    function getLockedStakes(address _user) external view returns (LockedStake[] memory);

    // claim demand stake rewards
    function claimDemandStakeRewards() external;

    // claim one locked stake rewards
    function claimLockedStakeRewards(uint256 _index) external;

    // claim all locked stakes rewards
    function claimAllLockedStakeRewards() external;

    // claim demand + locked stakes rewards
    function claimAllRewards() external;

    function increaseF(uint256 _LQTYFee) external;

    function getPendingDemandGain(address _user) external view returns (uint256);

    function getPendingLockedGain(uint256 _index) external view returns (uint256);
}
