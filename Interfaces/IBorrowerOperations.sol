// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

// Common interface for the Trove Manager.
interface IBorrowerOperations {

    // --- Events ---

    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event ActivePoolAddressChanged(address _activePoolAddress);
    event CakeMinerAddressChanged(address _cakeMinerAddress);
    event GasPoolAddressChanged(address _gasPoolAddress);
    event CollSurplusPoolAddressChanged(address _collSurplusPoolAddress);
    event ReservePoolAddressChanged(address _reserverPoolAddress);
    event PriceFeedAddressChanged(address  _newPriceFeedAddress);
    event LUSDTokenAddressChanged(address _lusdTokenAddress);
    event LQTYStakingAddressChanged(address _lqtyStakingAddress);
    event AssetConfigManagerAddressChanged(address _assetConfigManagerAddress);
    event GlobalConfigManagerAddressChanged(address _globalConfigManagerAddress);
    event GuardianAddressChanged(address _guardianAddress);
    event CommunityIssuanceAddressChanged(address _communityIssuanceAddress);
    event LockerAddressChanged(address _lockerAddress);

    event LUSDBorrowingFeePaid(address indexed _asset, address indexed _borrower, uint _stakingRewardAmount, uint _reserveAmount, uint _LUSDFee);
    event TroveCreatedFor(address indexed _asset, address indexed _caller, address indexed _borrower);

    enum BorrowerOperation {
        openTrove,
        closeTrove,
        adjustTrove
    }

    // --- Functions ---

    struct ContractAddresses {
        address troveManagerAddress;
        address activePoolAddress;
        address cakeMinerAddress;
        address gasPoolAddress;
        address collSurplusPoolAddress;
        address reservePoolAddress;
        address priceFeedAddress;
        address lusdTokenAddress;
        address lqtyStakingAddress;
        address assetConfigManagerAddress;
        address globalConfigManagerAddress;
        address guardianAddress;
        address communityIssuanceAddress;
        address lockerAddress;
    }

    function setAddresses(ContractAddresses memory addresses) external;

    function openTrove(address _asset, uint _maxFee, uint _collAmount,uint _LUSDAmount, address _upperHint, address _lowerHint) external payable;

    function openTroveOnBehalfOf(address _asset, address _borrower, uint _maxFee, uint _collAmount, uint _LUSDAmount, address _upperHint, address _lowerHint) external payable;

    function addColl(address _asset, uint _collAmount, address _upperHint, address _lowerHint) external payable;

    function withdrawColl(address _asset, uint _amount, address _upperHint, address _lowerHint) external;

    function withdrawLUSD(address _asset, uint _maxFee, uint _amount, address _upperHint, address _lowerHint) external;

    function repayLUSD(address _asset, uint _amount, address _upperHint, address _lowerHint) external;

    function closeTrove(address _asset) external;

    function claimCollateral(address _asset) external;

    function claimLQTYRewards(address _asset) external;

    function claimCake(address _asset) external;
}
