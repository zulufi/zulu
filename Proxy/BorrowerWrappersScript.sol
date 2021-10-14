// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "../Dependencies/SafeMath.sol";
import "../Dependencies/LiquityMath.sol";
import "../Dependencies/IERC20.sol";
import "../Interfaces/IAssetConfigManager.sol";
import "../Interfaces/IBorrowerOperations.sol";
import "../Interfaces/IFeeRateModel.sol";
import "../Interfaces/ITroveManagerV2.sol";
import "../Interfaces/IStabilityPool.sol";
import "../Interfaces/IPriceFeed.sol";
import "../Interfaces/ILQTYStaking.sol";
import "./BorrowerOperationsScript.sol";
import "./ETHTransferScript.sol";
import "./LQTYStakingScript.sol";
import "../Dependencies/console.sol";


contract BorrowerWrappersScript is BorrowerOperationsScript, ETHTransferScript, LQTYStakingScript {
    using SafeMath for uint;

    string constant public NAME = "BorrowerWrappersScript";

    ITroveManagerV2 immutable troveManager;
    IStabilityPool immutable stabilityPool;
    IPriceFeed immutable priceFeed;
    IERC20 immutable lusdToken;
    IERC20 immutable lqtyToken;
    ILQTYStaking immutable lqtyStaking;
    IAssetConfigManager public assetConfigManager;

    constructor(
        address _borrowerOperationsAddress,
        address _troveManagerAddress,
        address _lqtyStakingAddress,
        address _stabilityPoolAddress,
        address _priceFeedAddress,
        address _lusdTokenAddress,
        address _lqtyTokenAddress,
        address _assetConfigManagerAddress
    )
        BorrowerOperationsScript(IBorrowerOperations(_borrowerOperationsAddress))
        LQTYStakingScript(_lqtyStakingAddress)
        public
    {
        checkContract(_troveManagerAddress);
        troveManager = ITroveManagerV2(_troveManagerAddress);

        checkContract(_stabilityPoolAddress);
        stabilityPool = IStabilityPool(_stabilityPoolAddress);

        checkContract(_priceFeedAddress);
        priceFeed = IPriceFeed(_priceFeedAddress);

        checkContract(_lusdTokenAddress);
        lusdToken = IERC20(_lusdTokenAddress);

        checkContract(_lqtyTokenAddress);
        lqtyToken = IERC20(_lqtyTokenAddress);

        checkContract(_lqtyStakingAddress);
        lqtyStaking = ILQTYStaking(_lqtyStakingAddress);

        checkContract(_assetConfigManagerAddress);
        assetConfigManager = IAssetConfigManager(_assetConfigManagerAddress);
    }

    function claimCollateralAndOpenTrove(address _asset, uint _maxFee, uint _LUSDAmount, address _upperHint, address _lowerHint) external payable {
        uint balanceBefore = address(this).balance;

        // Claim collateral
        borrowerOperations.claimCollateral(_asset);

        uint balanceAfter = address(this).balance;

        // already checked in CollSurplusPool
        assert(balanceAfter > balanceBefore);

        uint totalCollateral = balanceAfter.sub(balanceBefore).add(msg.value);

        // Open trove with obtained collateral, plus collateral sent by user
        borrowerOperations.openTrove{ value: totalCollateral }(_asset, _maxFee, totalCollateral, _LUSDAmount, _upperHint, _lowerHint);
    }

    function _getNetLUSDAmount(address _asset, uint _collateral) internal returns (uint) {
        uint price = priceFeed.fetchPrice(_asset);
        uint ICR = troveManager.getCurrentICR(address(this), _asset, price);

        uint LUSDAmount = _collateral.mul(price).div(ICR);
        uint borrowingRate = IFeeRateModel(assetConfigManager.get(_asset).feeRateModelAddress).getBorrowRate(_asset, price, LUSDAmount);
        uint netDebt = LUSDAmount.mul(LiquityMath.DECIMAL_PRECISION).div(LiquityMath.DECIMAL_PRECISION.add(borrowingRate));

        return netDebt;
    }

    function _requireUserHasTrove(address _depositor, address _asset) internal view {
        require(troveManager.getTroveStatus(_depositor, _asset) == 1, "BorrowerWrappersScript: caller must have an active trove");
    }
}
