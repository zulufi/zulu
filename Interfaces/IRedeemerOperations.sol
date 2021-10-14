// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

interface IRedeemerOperations {
    // --- Events ---
    event AssetConfigManagerAddressChanged(address _assetConfigManagerAddress);
    event GlobalConfigManagerAddressChanged(address _globalConfigManagerAddress);
    event TroveManagerAddressChanged(address _troveManagerAddress);
    event PriceFeedAddressChanged(address _priceFeedAddress);
    event LUSDTokenAddressChanged(address _LUSDTokenAddress);
    event ActivePoolAddressChanged(address _activePoolAddress);
    event CakeMinerAddressChanged(address _cakeMinerAddress);
    event GasPoolAddressChanged(address _gasPoolAddress);
    event CollSurplusPoolAddressChanged(address _collSurplusPoolAddress);
    event ReservePoolAddressChanged(address _reservePoolAddress);
    event LQTYStakingAddressChanged(address _lqtyStakingAddress);
    event GuardianAddressChanged(address _guardianAddress);
    event CommunityIssuanceAddressChanged(address _communityIssuanceAddress);
    event LockerAddressChanged(address _lockerAddress);

    event TroveRedeemed(
        address indexed _asset,
        address indexed _borrower,
        uint256 _redeemedDebt,
        uint256 _redeemedColl,
        uint256 _debt,
        uint256 _coll
    );

    event Redemption(
        address indexed _asset,
        uint256 _attemptedLUSDAmount,
        uint256 _actualLUSDAmount,
        uint256 _collSent,
        uint256 _stakingRewardAmount,
        uint256 _reserveAmount,
        uint256 _LUSDFee
    );

    struct ContractAddresses {
        address assetConfigManagerAddress;
        address globalConfigManagerAddress;
        address troveManagerAddress;
        address activePoolAddress;
        address cakeMinerAddress;
        address gasPoolAddress;
        address collSurplusPoolAddress;
        address reservePoolAddress;
        address priceFeedAddress;
        address lusdTokenAddress;
        address lqtyStakingAddress;
        address guardianAddress;
        address communityIssuanceAddress;
        address lockerAddress;
    }

    // --- Functions ---
    function setAddresses(ContractAddresses memory addresses) external;

    function redeemCollateral(
        address _asset,
        uint256 _LUSDAmount,
        address _firstRedemptionHint,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint256 _partialRedemptionHintNICR,
        uint256 _maxIterations,
        uint256 _maxFee
    ) external;
}
