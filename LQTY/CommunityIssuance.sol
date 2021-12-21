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

    uint public totalStabilityLQTYIssued;
    uint public totalLiquidityLQTYIssued;
    mapping (address => uint) public totalStabilityLQTYIssuedPerAsset;
    mapping (address => uint) public totalLiquidityLQTYIssuedPerAsset;
    uint public LQTYSupplyCap;
    uint public deploymentTime;

    // --- Functions ---

    function initialize() public initializer {
        __Ownable_init();
        deploymentTime = block.timestamp;
    }

    function initializeAssetInternal(address _asset, bytes calldata _data) internal override {
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

    function sendLQTY(address _account, uint _LQTYamount) external override {
        _requireCallerIsSPOrTM();

        lqtyToken.transfer(_account, _LQTYamount);
    }

    function updateTotalStabilityLQTYIssued(address _asset, uint _issued) external override {
        _requireCallerIsSPOrTM();
        _requireEnoughSupply(_issued);

        uint latest = totalStabilityLQTYIssuedPerAsset[_asset].add(_issued);
        totalStabilityLQTYIssuedPerAsset[_asset] = latest;
        totalStabilityLQTYIssued = totalStabilityLQTYIssued.add(_issued);
        emit TotalStabilityLQTYIssued(_asset, latest);
    }

    function updateTotalLiquidityLQTYIssued(address _asset, uint _issued) external override {
        _requireCallerIsSPOrTM();
        _requireEnoughSupply(_issued);

        uint latest = totalLiquidityLQTYIssuedPerAsset[_asset].add(_issued);
        totalLiquidityLQTYIssuedPerAsset[_asset] = latest;
        totalLiquidityLQTYIssued = totalLiquidityLQTYIssued.add(_issued);
        emit TotalLiquidityLQTYIssued(_asset, latest);
    }

    function increaseCap(address _from, uint _LQTYamount) external override onlyOwner {
        lqtyToken.transferFrom(_from, address(this), _LQTYamount);

        LQTYSupplyCap = LQTYSupplyCap.add(_LQTYamount);
    }

    // --- 'require' functions ---

    function _requireEnoughSupply(uint _issued) internal view {
        require(
            totalStabilityLQTYIssued.add(totalLiquidityLQTYIssued).add(_issued) <= LQTYSupplyCap,
            "Out of LQTY supply"
        );
    }

    function _requireCallerIsSPOrTM() internal view {
        require(
            msg.sender == stabilityPoolAddress || msg.sender == troveManagerAddress,
            "CommunityIssuance: caller is not SP or TM"
        );
    }
}
