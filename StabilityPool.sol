// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import './Interfaces/IActivePool.sol';
import './Interfaces/IAssetConfigManager.sol';
import "./Interfaces/ICakeMiner.sol";
import "./Interfaces/ICommunityIssuance.sol";
import './Interfaces/IGuardian.sol';
import './Interfaces/ILUSDToken.sol';
import './Interfaces/IPriceFeed.sol';
import './Interfaces/IStabilityPool.sol';
import './Interfaces/ITroveManagerV2.sol';
import "./Dependencies/Guardable.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/BaseMath.sol";
import "./Dependencies/LiquitySafeMath128.sol";
import "./Dependencies/LiquityMath.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/console.sol";
import "./Dependencies/MultiAssetInitializable.sol";
import "./TransferHelper.sol";
import "./Dependencies/Lockable.sol";

/*
 * The Stability Pool holds LUSD tokens deposited by Stability Pool depositors.
 *
 * When a trove is liquidated, then depending on system conditions, some of its LUSD debt gets offset with
 * LUSD in the Stability Pool:  that is, the offset debt evaporates, and an equal amount of LUSD tokens in the Stability Pool is burned.
 *
 * Thus, a liquidation causes each depositor to receive a LUSD loss, in proportion to their deposit as a share of total deposits.
 * They also receive an ETH gain, as the ETH collateral of the liquidated trove is distributed among Stability depositors,
 * in the same proportion.
 *
 * When a liquidation occurs, it depletes every deposit by the same fraction: for example, a liquidation that depletes 40%
 * of the total LUSD in the Stability Pool, depletes 40% of each deposit.
 *
 * A deposit that has experienced a series of liquidations is termed a "compounded deposit": each liquidation depletes the deposit,
 * multiplying it by some factor in range ]0,1[
 *
 *
 * --- IMPLEMENTATION ---
 *
 * We use a highly scalable method of tracking deposits and ETH gains that has O(1) complexity.
 *
 * When a liquidation occurs, rather than updating each depositor's deposit and ETH gain, we simply update two state variables:
 * a product P, and a sum S.
 *
 * A mathematical manipulation allows us to factor out the initial deposit, and accurately track all depositors' compounded deposits
 * and accumulated ETH gains over time, as liquidations occur, using just these two variables P and S. When depositors join the
 * Stability Pool, they get a snapshot of the latest P and S: P_t and S_t, respectively.
 *
 * The formula for a depositor's accumulated ETH gain is derived here:
 * https://github.com/liquity/dev/blob/main/packages/contracts/mathProofs/Scalable%20Compounding%20Stability%20Pool%20Deposits.pdf
 *
 * For a given deposit d_t, the ratio P/P_t tells us the factor by which a deposit has decreased since it joined the Stability Pool,
 * and the term d_t * (S - S_t)/P_t gives us the deposit's total accumulated ETH gain.
 *
 * Each liquidation updates the product P and sum S. After a series of liquidations, a compounded deposit and corresponding ETH gain
 * can be calculated using the initial deposit, the depositor’s snapshots of P and S, and the latest values of P and S.
 *
 * Any time a depositor updates their deposit (withdrawal, top-up) their accumulated ETH gain is paid out, their new deposit is recorded
 * (based on their latest compounded deposit and modified by the withdrawal/top-up), and they receive new snapshots of the latest P and S.
 * Essentially, they make a fresh deposit that overwrites the old one.
 *
 *
 * --- SCALE FACTOR ---
 *
 * Since P is a running product in range ]0,1] that is always-decreasing, it should never reach 0 when multiplied by a number in range ]0,1[.
 * Unfortunately, Solidity floor division always reaches 0, sooner or later.
 *
 * A series of liquidations that nearly empty the Pool (and thus each multiply P by a very small number in range ]0,1[ ) may push P
 * to its 18 digit decimal limit, and round it to 0, when in fact the Pool hasn't been emptied: this would break deposit tracking.
 *
 * So, to track P accurately, we use a scale factor: if a liquidation would cause P to decrease to <1e-9 (and be rounded to 0 by Solidity),
 * we first multiply P by 1e9, and increment a currentScale factor by 1.
 *
 * The added benefit of using 1e9 for the scale factor (rather than 1e18) is that it ensures negligible precision loss close to the
 * scale boundary: when P is at its minimum value of 1e9, the relative precision loss in P due to floor division is only on the
 * order of 1e-9.
 *
 * --- EPOCHS ---
 *
 * Whenever a liquidation fully empties the Stability Pool, all deposits should become 0. However, setting P to 0 would make P be 0
 * forever, and break all future reward calculations.
 *
 * So, every time the Stability Pool is emptied by a liquidation, we reset P = 1 and currentScale = 0, and increment the currentEpoch by 1.
 *
 * --- TRACKING DEPOSIT OVER SCALE CHANGES AND EPOCHS ---
 *
 * When a deposit is made, it gets snapshots of the currentEpoch and the currentScale.
 *
 * When calculating a compounded deposit, we compare the current epoch to the deposit's epoch snapshot. If the current epoch is newer,
 * then the deposit was present during a pool-emptying liquidation, and necessarily has been depleted to 0.
 *
 * Otherwise, we then compare the current scale to the deposit's scale snapshot. If they're equal, the compounded deposit is given by d_t * P/P_t.
 * If it spans one scale change, it is given by d_t * P/(P_t * 1e9). If it spans more than one scale change, we define the compounded deposit
 * as 0, since it is now less than 1e-9'th of its initial value (e.g. a deposit of 1 billion LUSD has depleted to < 1 LUSD).
 *
 *
 *  --- TRACKING DEPOSITOR'S ETH GAIN OVER SCALE CHANGES AND EPOCHS ---
 *
 * In the current epoch, the latest value of S is stored upon each scale change, and the mapping (scale -> S) is stored for each epoch.
 *
 * This allows us to calculate a deposit's accumulated ETH gain, during the epoch in which the deposit was non-zero and earned ETH.
 *
 * We calculate the depositor's accumulated ETH gain for the scale at which they made the deposit, using the ETH gain formula:
 * e_1 = d_t * (S - S_t) / P_t
 *
 * and also for scale after, taking care to divide the latter by a factor of 1e9:
 * e_2 = d_t * S / (P_t * 1e9)
 *
 * The gain in the second scale will be full, as the starting point was in the previous scale, thus no need to subtract anything.
 * The deposit therefore was present for reward events from the beginning of that second scale.
 *
 *        S_i-S_t + S_{i+1}
 *      .<--------.------------>
 *      .         .
 *      . S_i     .   S_{i+1}
 *   <--.-------->.<----------->
 *   S_t.         .
 *   <->.         .
 *      t         .
 *  |---+---------|-------------|-----...
 *         i            i+1
 *
 * The sum of (e_1 + e_2) captures the depositor's total accumulated ETH gain, handling the case where their
 * deposit spanned one scale change. We only care about gains across one scale change, since the compounded
 * deposit is defined as being 0 once it has spanned more than one scale change.
 *
 *
 * --- UPDATING P WHEN A LIQUIDATION OCCURS ---
 *
 * Please see the implementation spec in the proof document, which closely follows on from the compounded deposit / ETH gain derivations:
 * https://github.com/liquity/liquity/blob/master/papers/Scalable_Reward_Distribution_with_Compounding_Stakes.pdf
 *
 *
 * --- LQTY ISSUANCE TO STABILITY POOL DEPOSITORS ---
 *
 * An LQTY issuance event occurs at every deposit operation, and every liquidation.
 *
 * Each deposit is tagged with the address of the front end through which it was made.
 *
 * All deposits earn a share of the issued LQTY in proportion to the deposit as a share of total deposits. The LQTY earned
 * by a given deposit, is split between the depositor and the front end through which the deposit was made, based on the front end's kickbackRate.
 *
 * Please see the system Readme for an overview:
 * https://github.com/liquity/dev/blob/main/README.md#lqty-issuance-to-stability-providers
 *
 * We use the same mathematical product-sum approach to track LQTY gains for depositors, where 'G' is the sum corresponding to LQTY gains.
 * The product P (and snapshot P_t) is re-used, as the ratio P/P_t tracks a deposit's depletion due to liquidations.
 *
 */
contract StabilityPool is BaseMath, CheckContract, MultiAssetInitializable, Guardable, Lockable, IStabilityPool {
    using LiquitySafeMath128 for uint128;
    using TransferHelper for address;
    using SafeMath for uint;

    string constant public NAME = "StabilityPool";

    address public borrowerOperationsAddress;

    address public liquidatorOperationsAddress;

    address public redeemerOperationsAddress;

    IActivePool public activePool;

    ICakeMiner public cakeMiner;

    IPriceFeed public priceFeed;

    ITroveManagerV2 public troveManager;

    ILUSDToken public lusdToken;

    ICommunityIssuance public communityIssuance;

    IAssetConfigManager public assetConfigManager;

    // asset -> balance
    mapping (address => uint256) internal assetBalances;

    // asset -> total lusd deposits in the pool
    // Changes when users deposit/withdraw, and when Trove debt is offset.
    mapping (address => uint256) totalLUSDDeposits;

   // --- Data structures ---

    struct Deposit {
        uint initialValue;
    }

    struct Snapshots {
        uint S;
        uint P;
        uint G;
        uint128 scale;
        uint128 epoch;
    }

    // asset address -> depositor address -> deposits
    mapping (address => mapping (address => Deposit)) public deposits;

    // asset address -> depositor address -> snapshot
    mapping (address => mapping (address => Snapshots)) public depositSnapshots;

    /*  Product 'P': Running product by which to multiply an initial deposit, in order to find the current compounded deposit,
    * after a series of liquidations have occurred, each of which cancel some LUSD debt with the deposit.
    *
    * During its lifetime, a deposit's value evolves from d_t to d_t * P / P_t , where P_t
    * is the snapshot of P taken at the instant the deposit was made. 18-digit decimal.
    */
    mapping (address => uint) public P_map;

    uint public constant SCALE_FACTOR = 1e9;

    // Each time the scale of P shifts by SCALE_FACTOR, the scale is incremented by 1
    // asset address -> scale value
    mapping (address => uint128) public currentScales;

    // With each offset that fully empties the Pool, the epoch is incremented by 1
    // asset address -> epoch value
    mapping (address => uint128) public currentEpochs;

    /* ETH Gain sum 'S': During its lifetime, each deposit d_t earns an ETH gain of ( d_t * [S - S_t] )/P_t, where S_t
    * is the depositor's snapshot of S taken at the time t when the deposit was made.
    *
    * The 'S' sums are stored in a nested mapping (epoch => scale => sum):
    *
    * - The inner mapping records the sum S at different scales
    * - The outer mapping records the (scale => sum) mappings, for different epochs.
    */
    mapping (address => mapping (uint128 => mapping(uint128 => uint))) public assetToEpochToScaleToSum;

    /*
    * Similarly, the sum 'G' is used to calculate LQTY gains for each depositor in one pool.
    * During it's lifetime, each deposit d_t earns a LQTY gain of
    *  ( d_t * [G - G_t] )/P_t, where G_t is the depositor's snapshot of G taken at time t when  the deposit was made.
    *
    *  LQTY reward events occur are triggered by depositor operations (new deposit, topup, withdrawal), and liquidations.
    *  In each case, the LQTY reward is issued (i.e. G is updated), before other state changes are made.
    */
    mapping (address => mapping (uint128 => mapping(uint128 => uint))) public assetToEpochToScaleToG;

    // Error tracker for the error correction in the LQTY issuance calculation per stability pool
    // asset address -> lqty error correction
    mapping (address => uint) public lastLQTYErrors;

    // Error trackers for the error correction in the offset calculation
    // asset address -> asset error correction
    mapping (address => uint) public lastAssetError_Offsets;

    // asset address -> lusd error correction
    mapping (address => uint) public lastLUSDLossError_Offsets;

    // --- Contract setters ---

    function initialize() public initializer {
        __Ownable_init();
        // P = DECIMAL_PRECISION;
    }

    function setAddresses(
        address _borrowerOperationsAddress,
        address _liquidatorOperationsAddress,
        address _redeemerOperationsAddress,
        address _troveManagerAddress,
        address _activePoolAddress,
        address _cakeMinerAddress,
        address _lusdTokenAddress,
        address _priceFeedAddress,
        address _communityIssuanceAddress,
        address _assetConfigManagerAddress,
        address _guardianAddress,
        address _lockerAddress
    )
        external
        override
        onlyOwner
    {
        require(borrowerOperationsAddress == address(0), "address has already been set");

        checkContract(_borrowerOperationsAddress);
        checkContract(_liquidatorOperationsAddress);
        checkContract(_redeemerOperationsAddress);
        checkContract(_troveManagerAddress);
        checkContract(_activePoolAddress);
        checkContract(_cakeMinerAddress);
        checkContract(_lusdTokenAddress);
        checkContract(_priceFeedAddress);
        checkContract(_communityIssuanceAddress);
        checkContract(_assetConfigManagerAddress);
        checkContract(_guardianAddress);
        checkContract(_lockerAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        liquidatorOperationsAddress = _liquidatorOperationsAddress;
        redeemerOperationsAddress = _redeemerOperationsAddress;
        troveManager = ITroveManagerV2(_troveManagerAddress);
        activePool = IActivePool(_activePoolAddress);
        cakeMiner = ICakeMiner(_cakeMinerAddress);
        lusdToken = ILUSDToken(_lusdTokenAddress);
        priceFeed = IPriceFeed(_priceFeedAddress);
        communityIssuance = ICommunityIssuance(_communityIssuanceAddress);
        assetConfigManager = IAssetConfigManager(_assetConfigManagerAddress);
        guardian = IGuardian(_guardianAddress);
        locker = ILocker(_lockerAddress);

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit LiquidatorOperationsAddressChanged(_liquidatorOperationsAddress);
        emit RedeemerOperationsAddressChanged(_redeemerOperationsAddress);
        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);
        emit CakeMinerAddressChanged(_cakeMinerAddress);
        emit LUSDTokenAddressChanged(_lusdTokenAddress);
        emit PriceFeedAddressChanged(_priceFeedAddress);
        emit CommunityIssuanceAddressChanged(_communityIssuanceAddress);
        emit AssetConfigManagerAddressChanged(_assetConfigManagerAddress);
        emit GuardianAddressChanged(_guardianAddress);
        emit LockerAddressChanged(_lockerAddress);
    }

    function getAssetBalance(address _asset) external view override returns (uint) {
        return assetBalances[_asset];
    }

    function getTotalLUSDDeposits(address _asset) external view override returns (uint) {
        return totalLUSDDeposits[_asset];
    }

    // --- Abstract methods of MultiAssetContract ---

    function initializeAssetInternal(address asset, bytes calldata data)
        override
        internal
    {
        P_map[asset] = DECIMAL_PRECISION;
    }

    // --- External Depositor Functions ---

    /*  provideToSP():
     *
     * - Triggers a LQTY issuance, based on time passed since the last issuance. The LQTY issuance is shared between *all* depositors.
     * - Sends depositor's accumulated gains (LQTY, Asset) to depositor
     * - Increases deposit and takes new snapshots for each.
     */
    function provideToSP(
        address _asset,
        uint _amount
    )
        external
        override
        notLocked
        guardianAllowed(_asset, 0xb75e38f7)
        onlySupportedAsset(_asset)
    {
        _requireNonZeroAmount(_amount);

        uint initialDeposit = deposits[_asset][msg.sender].initialValue;

        ICommunityIssuance communityIssuanceCached = communityIssuance;

        _triggerLQTYIssuance(communityIssuanceCached, _asset);

        uint depositorAssetGain = getDepositorAssetGain(_asset, msg.sender);
        uint compoundedLUSDDeposit = getCompoundedLUSDDeposit(_asset, msg.sender);
        uint LUSDLoss = initialDeposit.sub(compoundedLUSDDeposit); // Needed only for event log

        // First pay out any LQTY gains
        _payOutLQTYGains(communityIssuanceCached, _asset, msg.sender);

        // Second send lusd to pool
        _sendLUSDtoStabilityPool(_asset, msg.sender, _amount);

        uint newDeposit = compoundedLUSDDeposit.add(_amount);
        _updateDepositAndSnapshots(_asset, msg.sender, newDeposit);
        emit UserDepositChanged(_asset, msg.sender, newDeposit);

        emit AssetGainWithdrawn(_asset, msg.sender, depositorAssetGain, LUSDLoss); // LUSD Loss required for event log

        _sendAssetGainToDepositor(_asset, depositorAssetGain);
     }

    /*  withdrawFromSP():
     *
     * - Triggers a LQTY issuance, based on time passed since the last issuance. The LQTY issuance is shared between *all* depositors.
     * - Sends all depositor's accumulated gains (LQTY, Asset) to depositor
     * - Decreases deposit and takes new snapshots for each.
     *
     * If _amount > userDeposit, the user withdraws all of their compounded deposit.
     */
    function withdrawFromSP(
        address _asset,
        uint _amount
    )
        external
        override
        notLocked
        guardianAllowed(_asset, 0xeb34a789)
        onlySupportedAsset(_asset)
    {
        if (_amount !=0) {_requireNoUnderCollateralizedTroves(_asset);}
        uint initialDeposit = deposits[_asset][msg.sender].initialValue;
        _requireUserHasDeposit(initialDeposit);

        ICommunityIssuance communityIssuanceCached = communityIssuance;

        _triggerLQTYIssuance(communityIssuanceCached, _asset);

        uint depositorAssetGain = getDepositorAssetGain(_asset, msg.sender);

        uint compoundedLUSDDeposit = getCompoundedLUSDDeposit(_asset, msg.sender);
        uint LUSDtoWithdraw = LiquityMath._min(_amount, compoundedLUSDDeposit);
        uint LUSDLoss = initialDeposit.sub(compoundedLUSDDeposit); // Needed only for event log

        // First pay out any LQTY gains
        _payOutLQTYGains(communityIssuanceCached, _asset, msg.sender);

        _sendLUSDToDepositor(_asset, msg.sender, LUSDtoWithdraw);

        // Update deposit
        uint newDeposit = compoundedLUSDDeposit.sub(LUSDtoWithdraw);
        _updateDepositAndSnapshots(_asset, msg.sender, newDeposit);
        emit UserDepositChanged(_asset, msg.sender, newDeposit);

        emit AssetGainWithdrawn(_asset, msg.sender, depositorAssetGain, LUSDLoss);  // LUSD Loss required for event log

        _sendAssetGainToDepositor(_asset, depositorAssetGain);
    }

    function increaseAssetBalance(address _asset, uint _amount) external override {
        _requireCallerIsActivePoolorCakeMiner();

        uint _newAssetBalance = assetBalances[_asset].add(_amount);
        assetBalances[_asset] = _newAssetBalance;

        emit StabilityPoolAssetBalanceUpdated(_asset, _newAssetBalance);
    }

    function _triggerLQTYIssuance(ICommunityIssuance _communityIssuance, address _asset) internal {
        uint totalLUSD = totalLUSDDeposits[_asset];
        if (totalLUSD > 0) {
            uint LQTYAccrued = communityIssuance.issueStabilityLQTY(_asset);
            if (LQTYAccrued > 0) {
                _updateG(_asset, LQTYAccrued, totalLUSD);
            }
        }
    }

    function _updateG(address _asset, uint _LQTYIssuance, uint _totalLUSD) internal {
        uint LQTYPerUnitStaked = _computeLQTYPerUnitStaked(_asset, _LQTYIssuance, _totalLUSD);

        uint128 currentEpoch = currentEpochs[_asset];
        uint128 currentScale = currentScales[_asset];
        uint marginalLQTYGain = LQTYPerUnitStaked.mul(P_map[_asset]);
        uint newG = assetToEpochToScaleToG[_asset][currentEpoch][currentScale].add(marginalLQTYGain);
        assetToEpochToScaleToG[_asset][currentEpoch][currentScale] = newG;

        emit G_Updated(_asset, newG, currentEpoch, currentScale);
    }

    function _computeLQTYPerUnitStaked(address _asset, uint _LQTYIssuance, uint _totalLUSDDeposits) internal returns (uint) {
        /*
        * Calculate the LQTY-per-unit staked.  Division uses a "feedback" error correction, to keep the
        * cumulative error low in the running total G:
        *
        * 1) Form a numerator which compensates for the floor division error that occurred the last time this
        * function was called.
        * 2) Calculate "per-unit-staked" ratio.
        * 3) Multiply the ratio back by its denominator, to reveal the current floor division error.
        * 4) Store this error for use in the next correction when this function is called.
        * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
        */
        uint LQTYNumerator = _LQTYIssuance.mul(DECIMAL_PRECISION).add(lastLQTYErrors[_asset]);

        uint LQTYPerUnitStaked = LQTYNumerator.div(_totalLUSDDeposits);
        lastLQTYErrors[_asset] = LQTYNumerator.sub(LQTYPerUnitStaked.mul(_totalLUSDDeposits));

        return LQTYPerUnitStaked;
    }

    // --- Liquidation functions ---

    /*
    * Cancels out the specified debt against the LUSD contained in the Stability Pool (as far as possible)
    * and transfers the Trove's collateral from ActivePool to StabilityPool.
    * Only called by liquidation functions in the LiquidatorOperations.
    */
    function offset(address _asset, uint _debtToOffset, uint _collToAdd) external override onlySupportedAsset(_asset) {
        _requireCallerIsLiquidatorOperations();

        DataTypes.AssetConfig memory config = assetConfigManager.get(_asset);

        uint totalLUSD = totalLUSDDeposits[_asset]; // cached to save an SLOAD
        if (totalLUSD == 0 || _debtToOffset == 0) { return; }

        // trigger LQTY issuance & accrue LQTY for this asset
        _triggerLQTYIssuance(communityIssuance, _asset);

        (uint assetGainPerUnitStaked,
            uint LUSDLossPerUnitStaked) = _computeRewardsPerUnitStaked(_asset, _collToAdd, _debtToOffset, totalLUSD);

        _updateRewardSumAndProduct(_asset, assetGainPerUnitStaked, LUSDLossPerUnitStaked);  // updates S and P

        _moveOffsetCollAndDebt(config, _collToAdd, _debtToOffset);
    }

    // --- Offset helper functions ---

    function _computeRewardsPerUnitStaked(
        address _asset,
        uint _collToAdd,
        uint _debtToOffset,
        uint _totalLUSDDeposits
    )
        internal
        returns (uint assetGainPerUnitStaked, uint LUSDLossPerUnitStaked)
    {
        /*
        * Compute the LUSD and asset rewards. Uses a "feedback" error correction, to keep
        * the cumulative error in the P and S state variables low:
        *
        * 1) Form numerators which compensate for the floor division errors that occurred the last time this
        * function was called.
        * 2) Calculate "per-unit-staked" ratios.
        * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
        * 4) Store these errors for use in the next correction when this function is called.
        * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
        */
        uint assetNumerator = _collToAdd.mul(DECIMAL_PRECISION).add(lastAssetError_Offsets[_asset]);

        assert(_debtToOffset <= _totalLUSDDeposits);
        if (_debtToOffset == _totalLUSDDeposits) {
            LUSDLossPerUnitStaked = DECIMAL_PRECISION;  // When the Pool depletes to 0, so does each deposit
            lastLUSDLossError_Offsets[_asset] = 0;
        } else {
            uint LUSDLossNumerator = _debtToOffset.mul(DECIMAL_PRECISION).sub(lastLUSDLossError_Offsets[_asset]);
            /*
            * Add 1 to make error in quotient positive. We want "slightly too much" LUSD loss,
            * which ensures the error in any given compoundedLUSDDeposit favors the Stability Pool.
            */
            LUSDLossPerUnitStaked = (LUSDLossNumerator.div(_totalLUSDDeposits)).add(1);
            lastLUSDLossError_Offsets[_asset] = (LUSDLossPerUnitStaked.mul(_totalLUSDDeposits)).sub(LUSDLossNumerator);
        }

        assetGainPerUnitStaked = assetNumerator.div(_totalLUSDDeposits);
        lastAssetError_Offsets[_asset] = assetNumerator.sub(assetGainPerUnitStaked.mul(_totalLUSDDeposits));

        return (assetGainPerUnitStaked, LUSDLossPerUnitStaked);
    }

    // Update the Stability Pool reward sum S and product P
    function _updateRewardSumAndProduct(address _asset, uint _assetGainPerUnitStaked, uint _LUSDLossPerUnitStaked) internal {
        uint currentP = P_map[_asset];
        uint newP;

        assert(_LUSDLossPerUnitStaked <= DECIMAL_PRECISION);
        /*
         * The newProductFactor is the factor by which to change all deposits, due to the depletion of Stability Pool LUSD in the liquidation.
         * We make the product factor 0 if there was a pool-emptying. Otherwise, it is (1 - LUSDLossPerUnitStaked)
         */
        uint newProductFactor = uint(DECIMAL_PRECISION).sub(_LUSDLossPerUnitStaked);

        uint128 currentScaleCached = currentScales[_asset];
        uint128 currentEpochCached = currentEpochs[_asset];
        uint currentS = assetToEpochToScaleToSum[_asset][currentEpochCached][currentScaleCached];

        /*
         * Calculate the new S first, before we update P.
         * The ETH gain for any given depositor from a liquidation depends on the value of their deposit
         * (and the value of totalDeposits) prior to the Stability being depleted by the debt in the liquidation.
         *
         * Since S corresponds to asset gain, and P to deposit loss, we update S first.
         */
        uint marginalAssetGain = _assetGainPerUnitStaked.mul(currentP);
        uint newS = currentS.add(marginalAssetGain);
        assetToEpochToScaleToSum[_asset][currentEpochCached][currentScaleCached] = newS;
        emit S_Updated(_asset, newS, currentEpochCached, currentScaleCached);

        // If the Stability Pool was emptied, increment the epoch, and reset the scale and product P
        if (newProductFactor == 0) {
            uint128 newEpoch = currentEpochCached.add(1);
            currentEpochs[_asset] = newEpoch;
            emit EpochUpdated(_asset, newEpoch);
            currentScales[_asset] = 0;
            emit ScaleUpdated(_asset, 0);
            newP = DECIMAL_PRECISION;

        // If multiplying P by a non-zero product factor would reduce P below the scale boundary, increment the scale
        } else if (currentP.mul(newProductFactor).div(DECIMAL_PRECISION) < SCALE_FACTOR) {
            newP = currentP.mul(newProductFactor).mul(SCALE_FACTOR).div(DECIMAL_PRECISION);
            uint128 newScale = currentScaleCached.add(1);
            currentScales[_asset] = newScale;
            emit ScaleUpdated(_asset, newScale);
        } else {
            newP = currentP.mul(newProductFactor).div(DECIMAL_PRECISION);
        }

        assert(newP > 0);
        P_map[_asset] = newP;

        emit P_Updated(_asset, newP);
    }

    function _moveOffsetCollAndDebt(DataTypes.AssetConfig memory _config, uint _collToAdd, uint _debtToOffset) internal {
        IActivePool activePoolCached = activePool;

        // Cancel the liquidated LUSD debt with the LUSD in the stability pool
        _decreaseLUSD(_config.asset, _debtToOffset);

        // Burn the debt that was successfully offset
        lusdToken.burn(address(this), _debtToOffset);

        if (cakeMiner.isSupported(_config.asset)) {
            cakeMiner.sendAssetToPool(_config.asset, address(this), _collToAdd);
        } else {
            activePoolCached.sendAssetToPool(_config.asset, address(this), _collToAdd);
        }
    }

    function _decreaseLUSD(address _asset, uint _amount) internal {
        uint newTotalLUSDDeposits = totalLUSDDeposits[_asset].sub(_amount);
        totalLUSDDeposits[_asset] = newTotalLUSDDeposits;
        emit StabilityPoolLUSDBalanceUpdated(_asset, newTotalLUSDDeposits);
    }

    // --- Reward calculator functions for depositor and front end ---

    /* Calculates the ETH gain earned by the deposit since its last snapshots were taken.
    * Given by the formula:  E = d0 * (S - S(0))/P(0)
    * where S(0) and P(0) are the depositor's snapshots of the sum S and product P, respectively.
    * d0 is the last recorded deposit value.
    */
    function getDepositorAssetGain(address _asset, address _depositor) public view override returns (uint) {
        uint initialDeposit = deposits[_asset][_depositor].initialValue;

        if (initialDeposit == 0) { return 0; }

        Snapshots memory snapshots = depositSnapshots[_asset][_depositor];

        return _getAssetGainFromSnapshots(_asset, initialDeposit, snapshots);
    }

    function _getAssetGainFromSnapshots(address _asset, uint initialDeposit, Snapshots memory snapshots) internal view returns (uint) {
        /*
        * Grab the sum 'S' from the epoch at which the stake was made. The ETH gain may span up to one scale change.
        * If it does, the second portion of the ETH gain is scaled by 1e9.
        * If the gain spans no scale change, the second portion will be 0.
        */
        uint128 epochSnapshot = snapshots.epoch;
        uint128 scaleSnapshot = snapshots.scale;
        uint S_Snapshot = snapshots.S;
        uint P_Snapshot = snapshots.P;

        uint firstPortion = assetToEpochToScaleToSum[_asset][epochSnapshot][scaleSnapshot].sub(S_Snapshot);
        uint secondPortion = assetToEpochToScaleToSum[_asset][epochSnapshot][scaleSnapshot.add(1)].div(SCALE_FACTOR);

        uint assetGain = initialDeposit.mul(firstPortion.add(secondPortion)).div(P_Snapshot).div(DECIMAL_PRECISION);

        return assetGain;
    }

    /*
    * Calculate the LQTY gain earned by a deposit since its last snapshots were taken.
    * Given by the formula:  LQTY = d0 * (G - G(0))/P(0)
    * where G(0) and P(0) are the depositor's snapshots of the sum G and product P, respectively.
    * d0 is the last recorded deposit value.
    */
    function getDepositorLQTYGain(address _asset, address _depositor) public view override returns (uint) {
        uint initialDeposit = deposits[_asset][_depositor].initialValue;
        if (initialDeposit == 0) {return 0;}

        Snapshots memory snapshots = depositSnapshots[_asset][_depositor];

        return _getLQTYGainFromSnapshots(_asset, initialDeposit, snapshots);
    }

    function _getLQTYGainFromSnapshots(address _asset, uint initialStake, Snapshots memory snapshots) internal view returns (uint) {
        /*
         * Grab the sum 'G' from the epoch at which the stake was made. The LQTY gain may span up to one scale change.
         * If it does, the second portion of the LQTY gain is scaled by 1e9.
         * If the gain spans no scale change, the second portion will be 0.
         */
        uint128 epochSnapshot = snapshots.epoch;
        uint128 scaleSnapshot = snapshots.scale;
        uint G_Snapshot = snapshots.G;
        uint P_Snapshot = snapshots.P;

        uint firstPortion = assetToEpochToScaleToG[_asset][epochSnapshot][scaleSnapshot].sub(G_Snapshot);
        uint secondPortion = assetToEpochToScaleToG[_asset][epochSnapshot][scaleSnapshot.add(1)].div(SCALE_FACTOR);

        uint LQTYGain = initialStake.mul(firstPortion.add(secondPortion)).div(P_Snapshot).div(DECIMAL_PRECISION);

        return LQTYGain;
    }

    // --- Compounded deposit and compounded front end stake ---

    /*
    * Return the user's compounded deposit. Given by the formula:  d = d0 * P/P(0)
    * where P(0) is the depositor's snapshot of the product P, taken when they last updated their deposit.
    */
    function getCompoundedLUSDDeposit(address _asset, address _depositor) public view override returns (uint) {
        uint initialDeposit = deposits[_asset][_depositor].initialValue;
        if (initialDeposit == 0) { return 0; }

        Snapshots memory snapshots = depositSnapshots[_asset][_depositor];

        return _getCompoundedStakeFromSnapshots(_asset, initialDeposit, snapshots);
    }

    // Internal function, used to calculcate compounded deposits and compounded front end stakes.
    function _getCompoundedStakeFromSnapshots(
        address asset,
        uint initialStake,
        Snapshots memory snapshots
    )
        internal
        view
        returns (uint)
    {
        uint snapshot_P = snapshots.P;
        uint128 scaleSnapshot = snapshots.scale;
        uint128 epochSnapshot = snapshots.epoch;

        // If stake was made before a pool-emptying event, then it has been fully cancelled with debt -- so, return 0
        if (epochSnapshot < currentEpochs[asset]) { return 0; }

        uint compoundedStake;
        uint128 scaleDiff = currentScales[asset].sub(scaleSnapshot);

        /* Compute the compounded stake. If a scale change in P was made during the stake's lifetime,
        * account for it. If more than one scale change was made, then the stake has decreased by a factor of
        * at least 1e-9 -- so return 0.
        */
        uint cur_P = P_map[asset];
        if (scaleDiff == 0) {
            compoundedStake = initialStake.mul(cur_P).div(snapshot_P);
        } else if (scaleDiff == 1) {
            compoundedStake = initialStake.mul(cur_P).div(snapshot_P).div(SCALE_FACTOR);
        } else { // if scaleDiff >= 2
            compoundedStake = 0;
        }

        /*
        * If compounded deposit is less than a billionth of the initial deposit, return 0.
        *
        * NOTE: originally, this line was in place to stop rounding errors making the deposit too large. However, the error
        * corrections should ensure the error in P "favors the Pool", i.e. any given compounded deposit should slightly less
        * than it's theoretical value.
        *
        * Thus it's unclear whether this line is still really needed.
        */
        if (compoundedStake < initialStake.div(1e9)) {return 0;}

        return compoundedStake;
    }

    // --- Sender functions for LUSD deposit, ETH gains and LQTY gains ---

    // Transfer the LUSD tokens from the user to the Stability Pool's address, and update its recorded LUSD
    function _sendLUSDtoStabilityPool(address _asset, address _depositor, uint _amount) internal {
        lusdToken.sendToPool(_depositor, address(this), _amount);
        uint newTotalLUSDDeposits = totalLUSDDeposits[_asset].add(_amount);
        totalLUSDDeposits[_asset] = newTotalLUSDDeposits;
        emit StabilityPoolLUSDBalanceUpdated(_asset, newTotalLUSDDeposits);
    }

    function _sendAssetGainToDepositor(address _asset, uint _amount) internal {
        if (_amount == 0) {return;}
        uint _newAssetBalance = assetBalances[_asset].sub(_amount);
        assetBalances[_asset] = _newAssetBalance;
        emit StabilityPoolAssetBalanceUpdated(_asset, _newAssetBalance);
        emit AssetSent(_asset, msg.sender, _amount);

        address(_asset).safeTransferToken(msg.sender, _amount);
    }

    // Send LUSD to user and decrease LUSD in Pool
    function _sendLUSDToDepositor(address _asset, address _depositor, uint LUSDWithdrawal) internal {
        if (LUSDWithdrawal == 0) {return;}

        lusdToken.returnFromPool(address(this), _depositor, LUSDWithdrawal);
        _decreaseLUSD(_asset, LUSDWithdrawal);
    }

    // --- Stability Pool Deposit Functionality ---

    function _updateDepositAndSnapshots(address _asset, address _depositor, uint _newValue) internal {
        deposits[_asset][_depositor].initialValue = _newValue;

        if (_newValue == 0) {
            delete depositSnapshots[_asset][_depositor];
            emit DepositSnapshotUpdated(_asset, _depositor, 0, 0, 0);
            return;
        }
        uint128 currentScaleCached = currentScales[_asset];
        uint128 currentEpochCached = currentEpochs[_asset];
        uint currentP = P_map[_asset];

        // Get S and G for the current epoch and current scale
        uint currentS = assetToEpochToScaleToSum[_asset][currentEpochCached][currentScaleCached];
        uint currentG = assetToEpochToScaleToG[_asset][currentEpochCached][currentScaleCached];

        // Record new snapshots of the latest running product P, sum S, and sum G, for the depositor
        depositSnapshots[_asset][_depositor].P = currentP;
        depositSnapshots[_asset][_depositor].S = currentS;
        depositSnapshots[_asset][_depositor].G = currentG;
        depositSnapshots[_asset][_depositor].scale = currentScaleCached;
        depositSnapshots[_asset][_depositor].epoch = currentEpochCached;

        emit DepositSnapshotUpdated(_asset, _depositor, currentP, currentS, currentG);
    }

    function _payOutLQTYGains(ICommunityIssuance _communityIssuance, address _asset, address _depositor) internal {
        // Pay out depositor's LQTY gain
        uint depositorLQTYGain = getDepositorLQTYGain(_asset, _depositor);
        _communityIssuance.sendLQTY(_depositor, depositorLQTYGain);
        emit LQTYPaidToDepositor(_asset, _depositor, depositorLQTYGain);
    }

    // --- 'require' functions ---

    function _requireCallerIsLiquidatorOperations() internal view {
        require(msg.sender == liquidatorOperationsAddress, "StabilityPool: Caller is not liquidatorOperations");
    }

    function _requireCallerIsActivePoolorCakeMiner() internal view {
        require(
            msg.sender == address(activePool) || msg.sender == address(cakeMiner),
            "StabilityPool: Caller is not ActivePool nor CakeMiner");
    }

    function _requireNoUnderCollateralizedTroves(address _asset) internal {
        uint price = priceFeed.fetchPrice(_asset);
        ITroveManagerV2 troveManagerCached = troveManager;
        address[] memory troves = troveManagerCached.getLastNTroveOwners(_asset, 1);
        require(troves[0] != address(0), "StabilityPool: no troves");
        bool underCollateralized = troveManagerCached.isUnderCollateralized(troves[0], _asset, price);
        require(!underCollateralized, "StabilityPool: Cannot withdraw while there are troves with ICR < MCR");
    }

    function _requireUserHasDeposit(uint _initialDeposit) internal pure {
        require(_initialDeposit > 0, 'StabilityPool: User must have a non-zero deposit');
    }

    function _requireNonZeroAmount(uint _amount) internal pure {
        require(_amount > 0, 'StabilityPool: Amount must be non-zero');
    }

    receive() external payable {
        _requireCallerIsActivePoolorCakeMiner();
    }
}
