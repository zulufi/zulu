// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./IPayablePool.sol";

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
 * Please see the implementation spec in the proof document, which closely follows on from the compounded deposit / ETH gain derivations:
 * https://github.com/liquity/liquity/blob/master/papers/Scalable_Reward_Distribution_with_Compounding_Stakes.pdf
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
 */
interface IStabilityPool is IPayablePool {

    // --- Events ---

    event StabilityPoolAssetBalanceUpdated(address indexed _asset, uint _newBalance);
    event StabilityPoolLUSDBalanceUpdated(address indexed _asset, uint _newBalance);

    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event LiquidatorOperationsAddressChanged(address _liquidatorOperationsAddress);
    event RedeemerOperationsAddressChanged(address _redeemerOperationsAddress);
    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event ActivePoolAddressChanged(address _newActivePoolAddress);
    event LUSDTokenAddressChanged(address _newLUSDTokenAddress);
    event CommunityIssuanceAddressChanged(address _newCommunityIssuanceAddress);
    event AssetConfigManagerAddressChanged(address _newAssetConfigManagerAddress);
    event GuardianAddressChanged(address _guardianAddress);
    event LockerAddressChanged(address _lockerAddress);

    event P_Updated(address indexed _asset, uint _P);
    event S_Updated(address indexed _asset, uint _S, uint128 _epoch, uint128 _scale);
    event G_Updated(address indexed _asset, uint _G, uint128 _epoch, uint128 _scale);
    event L_Updated(uint _L);
    event EpochUpdated(address indexed _asset, uint128 _currentEpoch);
    event ScaleUpdated(address indexed _asset, uint128 _currentScale);

    event DepositSnapshotUpdated(address indexed _asset, address indexed _depositor, uint _P, uint _S, uint _G);
    event UserDepositChanged(address indexed _asset, address indexed _depositor, uint _newDeposit);
    event AssetLSnapshotUpdated(address indexed _asset, uint _L);
    event AssetDebtChanged(address indexed _asset, uint _debt);
    event TotalDebtChanged(uint _totalDebt);

    event AssetGainWithdrawn(address indexed _asset, address indexed _depositor, uint _assetGain, uint _LUSDLoss);
    event LQTYPaidToDepositor(address indexed _asset, address indexed _depositor, uint _LQTY);
    event AssetSent(address indexed _asset, address indexed _to, uint _amount);

    event StabilityRewardSpeedUpdated(address _asset, uint _speed);
    event S_SnapshotUpdated(address _asset, uint _lastTimestamp);

    // --- Functions ---

    /*
     * Called only once on init, to set addresses of other Liquity contracts
     * Callable only by owner, renounces ownership at the end
     */
    function setAddresses(
        address _borrowerOperationsAddress,
        address _liquidatorOperationsAddress,
        address _redeemerOperationsAddress,
        address _troveManagerAddress,
        address _activePoolAddress,
        address _lusdTokenAddress,
        address _communityIssuanceAddress,
        address _assetConfigManagerAddress,
        address _guardianAddress,
        address _lockerAddress
    ) external;

    function updateStabilityRewardSpeed(address _asset, uint _speed) external;

    /*
     * Initial checks:
     * - _asset is supported
     * - _amount is not zero
     * ---
     * - Triggers a LQTY issuance, based on time passed since the last issuance.
     * - LQTY is issued to *all* stability pools on a pro-rata basis of debt.
     * - Within one pool, LQTY is issued to *all* depositors on a pro-rata basis of staked LUSD.
     * - Sends depositor's accumulated gains (LQTY, Asset) to depositor
     * - Increases deposit and takes new snapshots.
     */
    function provideToSP(address _asset, uint _amount) external;

    /*
     * Initial checks:
     * - _asset is supported
     * - _amount is zero or there are no under collateralized troves left in the system
     * - User has a non zero deposit
     * ---
     * - Triggers a LQTY issuance, based on time passed since the last issuance.
     * - LQTY is issued to *all* stability pools on a pro-rata basis of debt.
     * - Within one pool, LQTY is issued to *all* depositors on a pro-rata basis of staked LUSD.
     * - Sends all depositor's accumulated gains (LQTY, Asset) to depositor
     * - Decreases deposit and takes new snapshots for each.
     *
     * If _amount > userDeposit, the user withdraws all of their compounded deposit.
     */
    function withdrawFromSP(address _asset, uint _amount) external;

    /*
     * Initial checks:
     * - Caller is TroveManager
     * ---
     * Cancels out the specified debt against the LUSD contained in the Stability Pool (as far as possible)
     * and transfers the Trove's collateral from ActivePool to StabilityPool.
     * Only called by liquidation functions in the TroveManager.
     */
    function offset(address _asset, uint _debt, uint _coll) external;

    /*
     * Returns the total amount of asset held by the pool, accounted in an internal variable instead of `balance`,
     * to exclude edge cases like asset received from a self-destruct.
     */
    function getAssetBalance(address _asset) external view returns (uint);

    /*
     * Returns LUSD held in the pool. Changes when users deposit/withdraw, and when Trove debt is offset.
     */
    function getTotalLUSDDeposits(address _asset) external view returns (uint);

    /*
     * Calculates the asset gain earned by the deposit since its last snapshots were taken.
     */
    function getDepositorAssetGain(address _asset, address _depositor) external view returns (uint);

    /*
     * Calculate the LQTY gain earned by a deposit since its last snapshots were taken.
     */
    function getDepositorLQTYGain(address _asset, address _depositor) external view returns (uint);

    /*
     * Return the user's compounded deposit.
     */
    function getCompoundedLUSDDeposit(address _asset, address _depositor) external view returns (uint);
}
