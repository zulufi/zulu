// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "./Interfaces/IAssetConfigManager.sol";
import "./Interfaces/ITroveManagerV2.sol";
import "./Dependencies/BaseMath.sol";
import "./Dependencies/LiquityMath.sol";
import "./Dependencies/OwnableUpgradeable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/LiquityMath.sol";

contract HintHelpers is BaseMath, OwnableUpgradeable, CheckContract {
    using SafeMath for uint256;

    string constant public NAME = "HintHelpers";

    IAssetConfigManager public assetConfigManager;
    ITroveManagerV2 public troveManager;

    /* --- Variable container structs  ---

    Used to hold, return and assign variables inside a function, in order to avoid the error:
    "CompilerError: Stack too deep". */

    struct SingleRedemptionValues {
        uint256 debt;
        uint256 coll;
        uint256 newDebt;
        uint256 newColl;
        uint256 gasCompensation;
    }

    struct RedemptionHints {
        address firstRedemptionHint;
        uint partialRedemptionHintNICR;
        uint truncatedLUSDamount;
    }

    // --- Events ---

    event AssetConfigManagerAddressChanged(address _assetConfigManagerAddress);
    event TroveManagerAddressChanged(address _troveManagerAddress);

    // --- Dependency setters ---

    function initialize() public initializer {
        __Ownable_init();
    }

    function setAddresses(
        address _assetConfigManagerAddress,
        address _troveManagerAddress
    )
        external
        onlyOwner
    {
        require(address(troveManager) == address(0), "address has already been set");

        checkContract(_assetConfigManagerAddress);
        checkContract(_troveManagerAddress);

        assetConfigManager = IAssetConfigManager(_assetConfigManagerAddress);
        troveManager = ITroveManagerV2(_troveManagerAddress);

        emit AssetConfigManagerAddressChanged(_assetConfigManagerAddress);
        emit TroveManagerAddressChanged(_troveManagerAddress);
    }

    // --- Functions ---

    /* getRedemptionHints() - Helper function for finding the right hints to pass to redeemCollateral().
     *
     * It simulates a redemption of `_LUSDamount` to figure out where the redemption sequence will start and what state the final Trove
     * of the sequence will end up in.
     *
     * Returns three hints:
     *  - `firstRedemptionHint` is the address of the first Trove with ICR >= MCR (i.e. the first Trove that will be redeemed).
     *  - `partialRedemptionHintNICR` is the final nominal ICR of the last Trove of the sequence after being hit by partial redemption,
     *     or zero in case of no partial redemption.
     *  - `truncatedLUSDamount` is the maximum amount that can be redeemed out of the the provided `_LUSDamount`. This can be lower than
     *    `_LUSDamount` when redeeming the full amount would leave the last Trove of the redemption sequence with less net debt than the
     *    minimum allowed value (i.e. MIN_NET_DEBT).
     *
     * The number of Troves to consider for redemption can be capped by passing a non-zero value as `_maxIterations`, while passing zero
     * will leave it uncapped.
     */

    function getRedemptionHints(
        address _asset,
        uint _LUSDamount,
        uint _price,
        uint _maxIterations
    )
        external
        view
        returns (RedemptionHints memory hints)
    {
        ITroveManagerV2 troveManagerCached = troveManager;
        DataTypes.AssetConfig memory _config = assetConfigManager.get(_asset);

        uint remainingLUSD = _LUSDamount;

        if (_maxIterations == 0) {
            _maxIterations = LiquityMath._min(remainingLUSD.div(_config.riskParams.minDebt).add(1), troveManagerCached.getTroveOwnersCount(_asset));
        }

        address[] memory troveArray = troveManagerCached.getLastNTrovesAboveMCR(
            _asset,
            _maxIterations,
            address(0),
            _price
        );

        if (troveArray.length > 0) {
            hints.firstRedemptionHint = troveArray[0];
        }

        for (uint256 i = 0; i < troveArray.length && remainingLUSD > 0; i++) {
            SingleRedemptionValues memory singleRedemption;
            (singleRedemption.debt, singleRedemption.coll) = troveManagerCached.getTroveDebtAndColl(
                troveArray[i],
                _asset
            );
            singleRedemption.gasCompensation = troveManagerCached.getTroveGasCompensation(troveArray[i], _asset);
            uint256 netLUSDDebt = singleRedemption.debt.sub(singleRedemption.gasCompensation);

            if (netLUSDDebt > remainingLUSD) {
                if (netLUSDDebt > _config.riskParams.minDebt) {
                    uint maxRedeemableLUSD = LiquityMath._min(remainingLUSD, netLUSDDebt.sub(_config.riskParams.minDebt));

                    singleRedemption.newColl = singleRedemption.coll.sub(LiquityMath._scaleToCollDecimals(
                        maxRedeemableLUSD.mul(DECIMAL_PRECISION).div(_price), _config.decimals));
                    singleRedemption.newDebt = singleRedemption.debt.sub(maxRedeemableLUSD);

                    hints.partialRedemptionHintNICR = troveManager.computeNominalICR(
                        _asset,
                        singleRedemption.newColl,
                        singleRedemption.newDebt
                    );

                    remainingLUSD = remainingLUSD.sub(maxRedeemableLUSD);
                }
                break;
            } else {
                remainingLUSD = remainingLUSD.sub(netLUSDDebt);
            }
        }

        hints.truncatedLUSDamount = _LUSDamount.sub(remainingLUSD);
    }

    /* getApproxHint() - return address of a Trove that is, on average, (length / numTrials) positions away in the
    sortedTroves list from the correct insert position of the Trove to be inserted.

    Note: The output address is worst-case O(n) positions away from the correct insert position, however, the function
    is probabilistic. Input can be tuned to guarantee results to a high degree of confidence, e.g:

    Submitting numTrials = k * sqrt(length), with k = 15 makes it very, very likely that the ouput address will
    be <= sqrt(length) positions away from the correct insert position.
    */
    function getApproxHint(address _asset, uint _CR, uint _numTrials, uint _inputRandomSeed)
        external
        view
        returns (address hintAddress, uint diff, uint latestRandomSeed)
    {
        ITroveManagerV2 troveManagerCached = troveManager;

        uint arrayLength = troveManagerCached.getTroveOwnersCount(_asset);

        if (arrayLength == 0) {
            return (address(0), 0, _inputRandomSeed);
        }

        hintAddress = troveManagerCached.getTroveFromTroveOwnersArray(_asset, arrayLength - 1);
        diff = LiquityMath._getAbsoluteDifference(_CR, troveManagerCached.getNominalICR(hintAddress, _asset));
        latestRandomSeed = _inputRandomSeed;

        uint i = 1;

        while (i < _numTrials) {
            latestRandomSeed = uint(keccak256(abi.encodePacked(latestRandomSeed)));

            uint arrayIndex = latestRandomSeed % arrayLength;
            address currentAddress = troveManagerCached.getTroveFromTroveOwnersArray(_asset, arrayIndex);
            uint currentNICR = troveManagerCached.getNominalICR(currentAddress, _asset);

            // check if abs(current - CR) > abs(closest - CR), and update closest if current is closer
            uint currentDiff = LiquityMath._getAbsoluteDifference(currentNICR, _CR);

            if (currentDiff < diff) {
                diff = currentDiff;
                hintAddress = currentAddress;
            }
            i++;
        }
    }
}
