// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Interfaces/IFarmer.sol";
import "../Interfaces/IPayablePool.sol";
import "../Interfaces/ITroveManagerV2.sol";
import "../Dependencies/OwnableUpgradeable.sol";
import "../Dependencies/SafeMath.sol";
import "../TransferHelper.sol";

abstract contract AbstractFarmer is IFarmer, OwnableUpgradeable {
    using TransferHelper for address;
    using SafeMath for uint256;

    ITroveManagerV2 public troveManager;

    address public borrowerOperationsAddress;

    address public liquidatorOperationsAddress;

    address public redeemerOperationsAddress;

    address public stabilityPoolAddress;

    bool public stop;

    function deposit(address _asset, uint256 _amount) external override {
        _requireCallerIsBO();
        _requireNonZeroAmount(_amount);

        if (!stop) {
            _deposit(_asset, _amount);
        }

        emit Deposited(_asset, _amount);
    }

    function sendAsset(
        address _asset,
        address _user,
        uint256 _amount
    ) external override {
        _requireCallerIsBOorLOorRO();

        _sendAsset(_asset, _user, _amount);
    }

    function sendAssetToPool(
        address _asset,
        address _pool,
        uint256 _amount
    ) external override {
        _requireCallerIsLOorROorSP();

        _sendAsset(_asset, _pool, _amount);

        IPayablePool(_pool).increaseAssetBalance(_asset, _amount);
    }

    function issueRewards(address _asset, address _user) external override {
        _requireCallerIsTOOrBO();

        _issueRewards(_asset, _user);
    }

    function emergencyStop() external override onlyOwner {
        require(!stop, "already stoppped!");

        _emergencyStop();

        stop = true;

        emit EmergencyStop(msg.sender);
    }

    // --- Internal helper functions ---
    function _deposit(address _asset, uint256 _amount) internal virtual;

    function _withdraw(address _asset, uint256 _amount) internal virtual;

    function _sendAsset(
        address _asset,
        address _to,
        uint256 _amount
    ) internal {
        if (_amount == 0) {
            return;
        }

        if (!stop) {
            uint256 balance = address(_asset).balanceOf(address(this));
            if (balance < _amount) {
                _withdraw(_asset, _amount.sub(balance));
            }
        }
        address(_asset).safeTransferToken(_to, _amount);

        emit AssetSent(_asset, _to, _amount);
    }

    function _issueRewards(address _asset, address _user) internal virtual;

    function _emergencyStop() internal virtual;

    // --- 'require' functions ---

    function _requireCallerIsTOOrBO() internal view {
        require(
            msg.sender == address(troveManager) || msg.sender == borrowerOperationsAddress,
            "CakeMiner: Caller is not TroveManager or BorrowerOperations"
        );
    }

    function _requireCallerIsBO() internal view {
        require(
            msg.sender == borrowerOperationsAddress,
            "CakeMiner: Caller is not BorrowerOperations"
        );
    }

    function _requireCallerIsBOorLOorRO() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
                msg.sender == liquidatorOperationsAddress ||
                msg.sender == redeemerOperationsAddress,
            "CakeMiner: Caller is neither BorrowerOperations nor LiquidatorOperations nor RedeemerOperations"
        );
    }

    function _requireCallerIsLOorROorSP() internal view {
        require(
            msg.sender == liquidatorOperationsAddress ||
                msg.sender == redeemerOperationsAddress ||
                msg.sender == stabilityPoolAddress,
            "CakeMiner: Caller is neither LiquidatorOperations nor RedeemerOperations nor StabilityPool"
        );
    }

    function _requireNonZeroAmount(uint256 _amount) internal pure {
        require(_amount > 0, "AlpacaFarmer: Amount must be non-zero");
    }
}
