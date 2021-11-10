// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "../Interfaces/ICommunityIssuance.sol";
import "../Interfaces/ILQTYToken.sol";
import "../Interfaces/ITroveManagerV2.sol";
import "../Dependencies/BaseMath.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/LiquityMath.sol";
import "../Dependencies/MultiAssetInitializable.sol";
import "../Dependencies/OwnableUpgradeable.sol";
import "../Dependencies/SafeMath.sol";


contract CommunityIssuance is ICommunityIssuance, MultiAssetInitializable, CheckContract, BaseMath {
    using SafeMath for uint;

    // --- Data ---

    string constant public NAME = "CommunityIssuance";

    uint constant public SECONDS_IN_ONE_MINUTE = 60;

    /*
    * The community LQTY supply cap is the starting balance of the Community Issuance contract.
    * It should be minted to this contract by LQTYToken, when the token is deployed.
    */

    ILQTYToken public lqtyToken;
    address public troveManagerAddress;
    address public stabilityPoolAddress;
    address public borrowerOperationsAddress;
    address public liquidatorOperationsAddress;
    address public redeemerOperationsAddress;

    mapping (address => uint) public totalStabilityLQTYIssued;
    mapping (address => uint) public totalLiquidityLQTYIssued;
    mapping (address => uint) public assetInitTimes;
    uint public LQTYSupplyCap;
    uint public deploymentTime;

    struct RewardSpeed {
        uint liquidityRewardSpeed;
        uint stabilityRewardSpeed;
    }

    /**
     * Stability reward is distributed to all assets on a configured speed.
     */
    struct S_Snapshot {
        uint lastRewardedTime;
    }
    mapping (address => uint) public stabilityRewardSpeeds; // asset => reward speed
    mapping (address => S_Snapshot) public S_Snapshots; // asset => snapshot
    mapping (address => uint) public accruedStabilityRewards; // asset => accrued LQTY

    /**
     * Liquidity reward is distributed to all assets on a configured speed
     */
    struct L_Snapshot {
        uint lastRewardedTime;
    }
    mapping (address => uint) public liquidityRewardSpeeds; // asset => reward speed
    mapping (address => L_Snapshot) public L_Snapshots; // asset => last rewarded time
    mapping (address => uint) public accruedLiquidityRewards; // asset => accrued LQTY

    // --- Functions ---

    function initialize() public initializer {
        __Ownable_init();
        deploymentTime = block.timestamp;
    }

    function initializeAssetInternal(address _asset, bytes calldata _data) internal override {
        RewardSpeed memory _rewardSpeed = abi.decode(_data, (RewardSpeed));
        liquidityRewardSpeeds[_asset] = _rewardSpeed.liquidityRewardSpeed;
        stabilityRewardSpeeds[_asset] = _rewardSpeed.stabilityRewardSpeed;
        L_Snapshots[_asset].lastRewardedTime = block.timestamp;
        S_Snapshots[_asset].lastRewardedTime = block.timestamp;
        assetInitTimes[_asset] = block.timestamp;
    }

    function setAddresses
    (
        address _lqtyTokenAddress,
        address _stabilityPoolAddress,
        address _troveManagerAddress,
        address _borrowerOperationsAddress,
        address _liquidatorOperationsAddress,
        address _redeemerOperationsAddress
    )
        external
        onlyOwner
        override
    {
        require(address(lqtyToken) == address(0), "address has already been set");

        checkContract(_lqtyTokenAddress);
        checkContract(_stabilityPoolAddress);
        checkContract(_troveManagerAddress);
        checkContract(_borrowerOperationsAddress);
        checkContract(_liquidatorOperationsAddress);
        checkContract(_redeemerOperationsAddress);

        lqtyToken = ILQTYToken(_lqtyTokenAddress);

        troveManagerAddress = _troveManagerAddress;
        stabilityPoolAddress = _stabilityPoolAddress;
        borrowerOperationsAddress = _borrowerOperationsAddress;
        liquidatorOperationsAddress = _liquidatorOperationsAddress;
        redeemerOperationsAddress = _redeemerOperationsAddress;

        // When LQTYToken deployed, it should have transferred CommunityIssuance's LQTY entitlement
        LQTYSupplyCap = lqtyToken.getCommunityIssuanceEntitlement();
        assert(LQTYSupplyCap > 0);
        uint LQTYBalance = lqtyToken.balanceOf(address(this));
        assert(LQTYBalance == LQTYSupplyCap);

        emit LQTYTokenAddressSet(_lqtyTokenAddress);
        emit StabilityPoolAddressSet(_stabilityPoolAddress);
        emit TroveManagerAddressSet(_troveManagerAddress);
        emit BorrowerOperationsAddressSet(_borrowerOperationsAddress);
        emit LiquidatorOperationsAddressSet(_liquidatorOperationsAddress);
        emit RedeemerOperationsAddressSet(_redeemerOperationsAddress);
    }

    // --- Stability Reward Functions ---
    function updateStabilitySpeed(address _asset, uint _speed)
        external
        override
        onlySupportedAsset(_asset)
        onlyOwner
    {
        _accrueStabilityLQTY(_asset);

        stabilityRewardSpeeds[_asset] = _speed;
        emit StabilityRewardSpeedUpdated(_asset, _speed);
    }

    function issueStabilityLQTY(address _asset)
        external
        override
        onlySupportedAsset(_asset)
        returns (uint)
    {
        _requireCallerIsStabilityPool();

        uint latestAccruedReward = _accrueStabilityLQTY(_asset);
        if (latestAccruedReward > 0) {
            accruedStabilityRewards[_asset] = 0;
        }

        emit StabilityLQTYIssued(_asset, latestAccruedReward);
        return latestAccruedReward;
    }

    function _accrueStabilityLQTY(address _asset)
        internal
        returns (uint)
    {
        S_Snapshot memory snapshotCached = S_Snapshots[_asset];

        uint curTime = block.timestamp;
        if (curTime <= snapshotCached.lastRewardedTime) {
            return accruedStabilityRewards[_asset];
        }

        // calculate reward
        uint reward = curTime.sub(snapshotCached.lastRewardedTime).mul(stabilityRewardSpeeds[_asset]);
        uint latestAccruedReward = accruedStabilityRewards[_asset].add(reward);
        accruedStabilityRewards[_asset] = latestAccruedReward;

        // update total issued
        _updateTotalIssued(_asset, 0, reward);

        // update snapshot
        S_Snapshots[_asset].lastRewardedTime = block.timestamp;
        emit S_SnapshotUpdated(_asset, block.timestamp);

        return latestAccruedReward;
    }

    // --- Liquidity Reward Functions ---

    function updateLiquiditySpeed(address _asset, uint _speed)
        external
        override
        onlySupportedAsset(_asset)
        onlyOwner
    {
        _accrueLiquidityLQTY(_asset);

        liquidityRewardSpeeds[_asset] = _speed;
        emit LiquidityRewardSpeedUpdated(_asset, _speed);
    }

    function issueLiquidityLQTY(address _asset)
        external
        override
        onlySupportedAsset(_asset)
        returns (uint)
    {
        _requireCallerIsTroveManager();

        uint latestAccruedReward = _accrueLiquidityLQTY(_asset);
        if (latestAccruedReward > 0) {
            accruedLiquidityRewards[_asset] = 0;
        }

        emit LiquidityLQTYIssued(_asset, latestAccruedReward);
        return latestAccruedReward;
    }

    function _accrueLiquidityLQTY(address _asset)
        internal
        returns (uint)
    {
        L_Snapshot memory snapshotCached = L_Snapshots[_asset];

        uint curTime = block.timestamp;
        if (curTime <= snapshotCached.lastRewardedTime) {
            return accruedLiquidityRewards[_asset];
        }

        // calculate reward
        uint reward = curTime.sub(snapshotCached.lastRewardedTime).mul(liquidityRewardSpeeds[_asset]);
        uint latestAccruedReward = accruedLiquidityRewards[_asset].add(reward);
        accruedLiquidityRewards[_asset] = latestAccruedReward;

        // update total issued
        _updateTotalIssued(_asset, reward, 0);

        // update snapshot
        L_Snapshots[_asset].lastRewardedTime = block.timestamp;
        emit L_SnapshotUpdated(_asset, block.timestamp);

        return latestAccruedReward;
    }

    function sendLQTY(address _account, uint _LQTYamount) external override {
        _requireCallerIsSPOrBO();

        lqtyToken.transfer(_account, _LQTYamount);
    }

    function _updateTotalIssued(address _asset, uint _liquidityLQTYAccrued, uint _stabilityLQTYAccrued) internal {
        uint latest_L = totalLiquidityLQTYIssued[_asset];
        if (_liquidityLQTYAccrued > 0) {
            latest_L = latest_L.add(_liquidityLQTYAccrued);
            totalLiquidityLQTYIssued[_asset] = latest_L;
            emit LiquidityLQTYAccrued(_asset, latest_L);
        }

        uint latest_S = totalStabilityLQTYIssued[_asset];
        if (_stabilityLQTYAccrued > 0) {
            latest_S = latest_S.add(_stabilityLQTYAccrued);
            totalStabilityLQTYIssued[_asset] = latest_S;
            emit StabilityLQTYAccrued(_asset, latest_S);
        }

        require(latest_S.add(latest_L) < LQTYSupplyCap, "out of LQTY balance");
    }

    // --- 'require' functions ---

    function _requireCallerIsStabilityPool() internal view {
        require(msg.sender == stabilityPoolAddress, "CommunityIssuance: caller is not SP");
    }

    function _requireCallerIsSPOrBO() internal view {
        require(
            msg.sender == stabilityPoolAddress || msg.sender == borrowerOperationsAddress,
            "CommunityIssuance: caller is not SP or BO"
        );
    }

    function _requireCallerIsTroveManager() internal view {
        require(msg.sender == troveManagerAddress, "CommunityIssuance: caller is not TM");
    }

    function _requireCallerIsUserOperations() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == liquidatorOperationsAddress ||
            msg.sender == redeemerOperationsAddress,
            "CommunityIssuance: caller must be BO or LO or RO"
        );
    }
}
