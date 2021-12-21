// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import './Interfaces/IActivePool.sol';
import './Interfaces/IGlobalConfigManager.sol';
import "./Interfaces/IPayablePool.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/IWETH.sol";
import "./Dependencies/OwnableUpgradeable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/console.sol";
import "./TransferHelper.sol";

/*
 * The Active Pool holds the ETH collateral and LUSD debt (but not LUSD tokens) for all active troves.
 *
 * When a trove is liquidated, it's ETH and LUSD debt are transferred from the Active Pool, to either the
 * Stability Pool, the Default Pool, or both, depending on the liquidation conditions.
 *
 */
contract ActivePool is OwnableUpgradeable, CheckContract, IActivePool {
    using SafeMath for uint256;
    using TransferHelper for address;

    string constant public NAME = "ActivePool";

    address public borrowerOperationsAddress;
    address public liquidatorOperationsAddress;
    address public redeemerOperationsAddress;
    address public stabilityPoolAddress;

    // --- Contract setters ---

    function initialize() public initializer {
        __Ownable_init();
    }

    function setAddresses(
        address _borrowerOperationsAddress,
        address _liquidatorOperationsAddress,
        address _redeemerOperationsAddress,
        address _stabilityPoolAddress
    )
        external
        onlyOwner
    {
        require(borrowerOperationsAddress == address(0), "address has already been set");

        checkContract(_borrowerOperationsAddress);
        checkContract(_liquidatorOperationsAddress);
        checkContract(_redeemerOperationsAddress);
        checkContract(_stabilityPoolAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        liquidatorOperationsAddress = _liquidatorOperationsAddress;
        redeemerOperationsAddress = _redeemerOperationsAddress;
        stabilityPoolAddress = _stabilityPoolAddress;

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit LiquidatorOperationsAddressChanged(_liquidatorOperationsAddress);
        emit RedeemerOperationsAddressChanged(_redeemerOperationsAddress);
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);
    }

    // --- Pool functionality ---

    function sendAsset(address _asset, address _account, uint _amount) external override {
        _sendAsset(_asset, _account, _amount);
    }

    function sendAssetToPool(address _asset, address _pool, uint _amount) external override {
        _sendAsset(_asset, _pool, _amount);
        IPayablePool(_pool).increaseAssetBalance(_asset, _amount);
    }

    function _sendAsset(address _asset, address _account, uint _amount) internal {
        _requireCallerIsBOorLOorROorSP();

        address(_asset).safeTransferToken(_account, _amount);

        emit AssetSent(_asset, _account, _amount);
    }

    // --- 'require' functions ---
    function _requireCallerIsBOorLOorROorSP() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == liquidatorOperationsAddress ||
            msg.sender == redeemerOperationsAddress ||
            msg.sender == stabilityPoolAddress,
            "ActivePool: Caller is neither BorrowerOperations nor LiquidatorOperations nor RedeemerOperations nor StabilityPool");
    }

    receive() external payable {
    }
}
