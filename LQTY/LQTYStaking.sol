// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "../Dependencies/BaseMath.sol";
import "../Dependencies/Guardable.sol";
import "../Dependencies/LiquityMath.sol";
import "../Dependencies/SafeMath.sol";
import "../Dependencies/OwnableUpgradeable.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/console.sol";
import "../Interfaces/ILQTYToken.sol";
import "../Interfaces/ILQTYStaking.sol";
import "../Interfaces/IGuardian.sol";
import "../Interfaces/ILUSDToken.sol";
import "../Dependencies/Lockable.sol";

contract LQTYStaking is ILQTYStaking, Guardable, Lockable, OwnableUpgradeable, CheckContract, BaseMath {
    using SafeMath for uint256;

    // --- Data ---
    string public constant NAME = "LQTYStaking";

    uint256 public constant WEEK = 7 * 86400;

    uint256 public bonusMultiplierPerWeek;
    uint256 public maxMultiplier;

    // user address => DemandStake
    mapping(address => DemandStake) public demandStakes;

    uint256 public totalDemandStakes;

    // index => LockedStake
    mapping(uint256 => LockedStake) public lockedStakes;

    uint256 public globalLockedStakeId;

    // user address => LockedStakes index array
    mapping(address => uint256[]) public userToLockedStakesIds;

    // week => total locked stakes
    mapping(uint256 => uint256) public totalLockedStakesPerWeek;

    uint256 public F; // Running sum of LUSD fees per-LQTY-staked

    mapping(uint256 => uint256) public F_snapshotsPerWeek;

    uint256 public lastUpdatedWeek;

    // user address => (index => CheckPoint)
    mapping(address => Checkpoint[]) public checkpointHistory;

    ILQTYToken public lqtyToken;
    ILUSDToken public lusdToken;

    address public borrowerOperationsAddress;
    address public redeemerOperationsAddress;

    // --- Functions ---

    function initialize() public initializer {
        __Ownable_init();
    }

    function setAddresses(
        address _lqtyTokenAddress,
        address _lusdTokenAddress,
        address _borrowerOperationsAddress,
        address _redeemerOperationsAddress,
        address _guardianAddress,
        address _lockerAddress
    ) external override onlyOwner {
        require(address(lqtyToken) == address(0), "address has already been set");

        checkContract(_lqtyTokenAddress);
        checkContract(_lusdTokenAddress);
        checkContract(_borrowerOperationsAddress);
        checkContract(_redeemerOperationsAddress);
        checkContract(_guardianAddress);
        checkContract(_lockerAddress);

        lqtyToken = ILQTYToken(_lqtyTokenAddress);
        lusdToken = ILUSDToken(_lusdTokenAddress);
        borrowerOperationsAddress = _borrowerOperationsAddress;
        redeemerOperationsAddress = _redeemerOperationsAddress;
        guardian = IGuardian(_guardianAddress);
        locker = ILocker(_lockerAddress);

        // set to 2% per week
        bonusMultiplierPerWeek = 2e16;
        maxMultiplier = DECIMAL_PRECISION.mul(4);

        emit LQTYTokenAddressSet(_lqtyTokenAddress);
        emit LUSDTokenAddressSet(_lusdTokenAddress);
        emit BorrowerOperationsAddressSet(_borrowerOperationsAddress);
        emit RedeemerOperationsAddressSet(_redeemerOperationsAddress);
        emit GuardianAddressSet(_guardianAddress);
        emit LockerAddressSet(_lockerAddress);

        emit BonusMultiplierPerWeekSet(bonusMultiplierPerWeek);
        emit MaxMultiplierSet(maxMultiplier);
    }

    function setBonusMultiplierPerWeek(uint256 _bonusMultiplierPerWeek) external override onlyOwner {
        bonusMultiplierPerWeek = _bonusMultiplierPerWeek;

        emit BonusMultiplierPerWeekSet(_bonusMultiplierPerWeek);
    }

    function setMaxMultiplier(uint256 _maxMultiplier) external override onlyOwner {
        maxMultiplier = _maxMultiplier;

        emit MaxMultiplierSet(_maxMultiplier);
    }

    function totalStakesAt(address _user, uint256 _blockNo)
        external
        view
        override
        returns (uint256)
    {
        require(_blockNo <= block.number, "LQTYStaking: invalid blockNo");

        uint256 curLength = checkpointHistory[_user].length;
        if (curLength == 0) {
            return 0;
        }

        // Binary search
        uint256 min = 0;
        uint256 max = curLength - 1;

        if (_blockNo < checkpointHistory[_user][min].blockNo) {
            return 0;
        }

        while (min < max) {
            uint256 mid = (min + max + 1) / 2;
            if (checkpointHistory[_user][mid].blockNo <= _blockNo) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return checkpointHistory[_user][min].totalStakes;
    }

    function stakeDemand(uint256 _LQTYamount) external notLocked override {
        _requireNonZeroAmount(_LQTYamount);

        claimDemandStakeRewards();

        // Transfer LQTY from caller to this contract
        lqtyToken.sendToLQTYStaking(msg.sender, _LQTYamount);

        DemandStake memory demandStake = demandStakes[msg.sender];
        if (demandStake.stakes == 0) {
            demandStake.stakes = _LQTYamount;
        } else {
            demandStake.stakes = demandStake.stakes.add(_LQTYamount);
        }

        // Increase user’s stake and total LQTY staked
        demandStakes[msg.sender] = demandStake;
        emit DemandStakesUpdated(msg.sender, demandStake);

        totalDemandStakes = totalDemandStakes.add(_LQTYamount);
        emit TotalDemandStakesUpdated(totalDemandStakes);

        _updateCheckpoint(msg.sender, _LQTYamount, true);
    }

    function unstakeDemand(uint256 _LQTYamount) external notLocked override {
        _requireNonZeroAmount(_LQTYamount);

        DemandStake memory demandStake = demandStakes[msg.sender];
        uint256 currentStake = demandStake.stakes;

        _requireUserHasStake(currentStake);

        claimDemandStakeRewards();

        uint256 LQTYToWithdraw = LiquityMath._min(_LQTYamount, currentStake);

        // Decrease user's stake and total LQTY staked
        demandStake.stakes = currentStake.sub(LQTYToWithdraw);
        demandStakes[msg.sender] = demandStake;
        emit DemandStakesUpdated(msg.sender, demandStake);

        totalDemandStakes = totalDemandStakes.sub(LQTYToWithdraw);
        emit TotalDemandStakesUpdated(totalDemandStakes);

        _updateCheckpoint(msg.sender, LQTYToWithdraw, false);

        // Transfer unstaked LQTY to user
        lqtyToken.transfer(msg.sender, LQTYToWithdraw);
    }

    function stakeLocked(uint256 _LQTYamount, uint256 _unlockTime) external notLocked override {
        _requireNonZeroAmount(_LQTYamount);
        _unlockTime = _roundToWeek(_unlockTime);
        require(
            _unlockTime > block.timestamp,
            "LQTYStaking: Can only lock until time in the future"
        );

        // Transfer LQTY from caller to this contract
        lqtyToken.sendToLQTYStaking(msg.sender, _LQTYamount);

        uint256 multiplier = _computeMultiplier(_unlockTime);
        LockedStake memory lockedStake = LockedStake(
            globalLockedStakeId,
            _LQTYamount,
            multiplier,
            block.timestamp,
            _unlockTime,
            F,
            userToLockedStakesIds[msg.sender].length
        );
        lockedStakes[globalLockedStakeId] = lockedStake;
        userToLockedStakesIds[msg.sender].push(globalLockedStakeId);
        emit LockedStaked(msg.sender, globalLockedStakeId, lockedStake);
        globalLockedStakeId = globalLockedStakeId + 1;

        for (
            uint256 curWeek = _getCurrentWeek();
            curWeek <= _unlockTime;
            curWeek = curWeek.add(WEEK)
        ) {
            totalLockedStakesPerWeek[curWeek] = totalLockedStakesPerWeek[curWeek].add(
                _LQTYamount.mul(multiplier).div(DECIMAL_PRECISION)
            );
        }

        _updateCheckpoint(msg.sender, _LQTYamount, true);
    }

    function unstakeLocked(uint256 _index) external notLocked override {
        require(_index < globalLockedStakeId, "LQTYStaking: invalid index");

        LockedStake storage lockedStake = lockedStakes[_index];

        _requireUserOwnsLockedStake(msg.sender, lockedStake);
        _requireUserHasStake(lockedStake.stakes);
        require(
            block.timestamp > lockedStake.unlockTime,
            "LQTYStaking: The lockup duration must have passed"
        );

        _fillFsnapshotsPerWeekGap(_getCurrentWeek());

        uint256 rewards = _claimLockedStakeRewards(msg.sender, _index, lockedStake);

        uint256 LQTYToWithdraw = lockedStake.stakes;

        _removeLockedStake(msg.sender, lockedStake);

        _updateCheckpoint(msg.sender, LQTYToWithdraw, false);

        if (rewards > 0) {
            // transfer LUSD to user
            lusdToken.transfer(msg.sender, rewards);
        }

        // Transfer unstaked LQTY to user
        lqtyToken.transfer(msg.sender, LQTYToWithdraw);

        emit LockedUnstaked(msg.sender, _index);
    }

    function getLockedStakes(address _user) external view override returns (LockedStake[] memory) {
        uint256[] memory lockedStakeIds = userToLockedStakesIds[_user];
        LockedStake[] memory lockedStakeArray = new LockedStake[](lockedStakeIds.length);
        for (uint256 idx = 0; idx < lockedStakeIds.length; idx++) {
            lockedStakeArray[idx] = lockedStakes[lockedStakeIds[idx]];
        }
        return lockedStakeArray;
    }

    function claimDemandStakeRewards() public notLocked override {
        DemandStake memory demandStake = demandStakes[msg.sender];
        uint256 rewards = _getPendingDemandGain(demandStake);

        if (rewards > 0) {
            lusdToken.transfer(msg.sender, rewards);

            emit DemandStakingGainsWithdrawn(msg.sender, rewards);
        }

        _updateDemandStakeSnapshots(msg.sender);
    }

    function claimLockedStakeRewards(uint256 _index) external notLocked override {
        require(_index < globalLockedStakeId, "LQTYStaking: invalid index");

        LockedStake memory lockedStake = lockedStakes[_index];

        _requireUserOwnsLockedStake(msg.sender, lockedStake);
        _requireUserHasStake(lockedStake.stakes);

        _fillFsnapshotsPerWeekGap(_getCurrentWeek());

        uint256 rewards = _claimLockedStakeRewards(msg.sender, _index, lockedStake);

        if (rewards > 0) {
            // transfer LUSD to user
            lusdToken.transfer(msg.sender, rewards);
        }
    }

    function claimAllLockedStakeRewards() public notLocked override {
        _fillFsnapshotsPerWeekGap(_getCurrentWeek());
        uint256 rewards = 0;
        uint256 curLength = userToLockedStakesIds[msg.sender].length;
        for (uint256 index = 0; index < curLength; index++) {
            LockedStake memory lockedStake = lockedStakes[userToLockedStakesIds[msg.sender][index]];
            rewards = rewards.add(_claimLockedStakeRewards(msg.sender, index, lockedStake));
        }

        if (rewards > 0) {
            // transfer LUSD to user
            lusdToken.transfer(msg.sender, rewards);
        }
    }

    function claimAllRewards() external notLocked override {
        claimDemandStakeRewards();
        claimAllLockedStakeRewards();
    }

    // --- Reward-per-unit-staked increase functions. Called by Liquity core contracts ---

    function increaseF(uint256 _LUSDFee) external override {
        _requireCallerIsBOorRO();

        uint256 curWeek = _getCurrentWeek();

        uint256 totalLQTYStaked = totalDemandStakes.add(totalLockedStakesPerWeek[curWeek]);

        uint256 LUSDFeePerLQTYStaked;

        if (totalLQTYStaked > 0) {
            LUSDFeePerLQTYStaked = _LUSDFee.mul(DECIMAL_PRECISION).div(totalLQTYStaked);
        }

        F = F.add(LUSDFeePerLQTYStaked);
        emit FUpdated(F);

        F_snapshotsPerWeek[curWeek] = F;
        _fillFsnapshotsPerWeekGap(curWeek.sub(WEEK));
        lastUpdatedWeek = curWeek;
    }

    // --- Pending reward functions ---

    function getPendingDemandGain(address _user) external view override returns (uint256) {
        DemandStake memory demandStake = demandStakes[_user];
        return _getPendingDemandGain(demandStake);
    }

    function _getPendingDemandGain(DemandStake memory _demandStake) internal view returns (uint256) {
        if (_demandStake.stakes == 0) {
            return 0;
        }
        return _demandStake.stakes.mul(F.sub(_demandStake.F)).div(DECIMAL_PRECISION);
    }

    function _claimLockedStakeRewards(
        address _user,
        uint256 _index,
        LockedStake memory _lockedStake
    ) internal returns (uint256) {
        (uint256 rewards, uint256 F_snapshot) = _getPendingLockedGain(_lockedStake);

        if (rewards > 0) {
            emit LockedStakingGainsWithdrawn(_user, _index, rewards);
        }

        _updateLockedStakeSnapshots(_user, _index, F_snapshot);

        return rewards;
    }

    function getPendingLockedGain(uint256 _index) external view override returns (uint256) {
        require(_index < globalLockedStakeId, "LQTYStaking: invalid index");

        LockedStake memory lockedStake = lockedStakes[_index];

        (uint256 rewards, ) = _getPendingLockedGain(lockedStake);
        return rewards;
    }

    function _getPendingLockedGain(LockedStake memory _lockedStake)
        internal
        view
        returns (uint256, uint256)
    {
        if (_lockedStake.stakes == 0) {
            return (0, 0);
        }
        uint256 F_snapshot;
        if (block.timestamp > _lockedStake.unlockTime) {
            F_snapshot = F_snapshotsPerWeek[_lockedStake.unlockTime];
        } else {
            F_snapshot = F;
        }
        return (
            _lockedStake
                .stakes
                .mul(_lockedStake.multiplier)
                .div(DECIMAL_PRECISION)
                .mul(F_snapshot.sub(_lockedStake.F))
                .div(DECIMAL_PRECISION),
            F_snapshot
        );
    }

    // --- Internal helper functions ---
    function _updateDemandStakeSnapshots(address _user) internal {
        demandStakes[_user].F = F;
        emit DemandSnapshotsUpdated(_user, F);
    }

    function _fillFsnapshotsPerWeekGap(uint256 _to) internal {
        if (lastUpdatedWeek > 0 && lastUpdatedWeek < _to) {
            for (uint256 week = lastUpdatedWeek + WEEK; week <= _to; week = week.add(WEEK)) {
                F_snapshotsPerWeek[week] = F_snapshotsPerWeek[lastUpdatedWeek];
            }
        }
    }

    function _removeLockedStake(address _user, LockedStake memory _lockedStake) internal {
        uint256 length = userToLockedStakesIds[_user].length;
        uint256 arrayIndex = _lockedStake.arrayIndex;

        LockedStake storage lockedStakeToMove = lockedStakes[
            userToLockedStakesIds[_user][length - 1]
        ];
        userToLockedStakesIds[_user][arrayIndex] = lockedStakeToMove.index;
        lockedStakeToMove.arrayIndex = arrayIndex;

        userToLockedStakesIds[_user].pop();
        delete lockedStakes[_lockedStake.index];
    }

    function _updateLockedStakeSnapshots(
        address _user,
        uint256 _index,
        uint256 _F
    ) internal {
        lockedStakes[_index].F = _F;
        emit LockedSnapshotsUpdated(_user, _index, _F);
    }

    function _updateCheckpoint(
        address _user,
        uint256 adjustedAmount,
        bool increase
    ) internal {
        uint256 curLength = checkpointHistory[_user].length;
        Checkpoint memory checkpoint;
        if (curLength > 0) {
            checkpoint = checkpointHistory[_user][curLength - 1];
        }
        uint256 newStakes = increase
            ? checkpoint.totalStakes.add(adjustedAmount)
            : checkpoint.totalStakes.sub(adjustedAmount);
        checkpoint.totalStakes = newStakes;
        if (checkpoint.blockNo == block.number) {
            checkpointHistory[_user][curLength - 1] = checkpoint;
        } else {
            checkpoint.blockNo = block.number;
            checkpointHistory[_user].push(checkpoint);
            curLength = curLength + 1;
        }

        emit CheckpointUpdated(_user, curLength - 1, checkpoint);
    }

    function _roundToWeek(uint256 _ts) internal pure returns (uint256) {
        return _ts.div(WEEK).mul(WEEK);
    }

    function _getCurrentWeek() internal view returns (uint256) {
        return _roundToWeek(block.timestamp.add(WEEK));
    }

    function _computeMultiplier(uint256 _unlockTime) internal view returns (uint256) {
        uint256 weekNums = _unlockTime.sub(_getCurrentWeek()).div(WEEK);
        return
            LiquityMath._min(
                maxMultiplier,
                DECIMAL_PRECISION.add(bonusMultiplierPerWeek.mul(weekNums))
            );
    }

    // --- 'require' functions ---

    function _requireCallerIsBOorRO() internal view {
        require(
            msg.sender == borrowerOperationsAddress || msg.sender == redeemerOperationsAddress,
            "LQTYStaking: caller is not BO or RO"
        );
    }

    function _requireUserOwnsLockedStake(address _user, LockedStake memory _lockedStake)
        internal
        view
    {
        uint256[] memory lockedStakeIds = userToLockedStakesIds[_user];
        require(
            lockedStakeIds.length > 0 &&
                lockedStakeIds[_lockedStake.arrayIndex] == _lockedStake.index,
            "LQTYStaking: User doesn't own locked stake"
        );
    }

    function _requireUserHasStake(uint256 currentStake) internal pure {
        require(currentStake > 0, "LQTYStaking: User must have a non-zero stake");
    }

    function _requireNonZeroAmount(uint256 _amount) internal pure {
        require(_amount > 0, "LQTYStaking: Amount must be non-zero");
    }
}
