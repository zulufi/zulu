// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Interfaces/IFlashLoanReceiver.sol";
import "../TransferHelper.sol";
import "../Dependencies/SafeMath.sol";
import "../Interfaces/IBorrowerOperations.sol";
import "../Dependencies/BaseMath.sol";
import "../Dependencies/CheckContract.sol";
import "../Interfaces/ILiquidatorOperations.sol";
import "../Interfaces/IRedeemerOperations.sol";
import "../Interfaces/IFlashLoanOperations.sol";

contract FlashLoanReceiverTester is BaseMath, CheckContract {
    using TransferHelper for address;
    using SafeMath for uint256;

    // 0 => repay enough
    // 1 => repay not enough
    // 2 => reentrancy BO
    // 3 => reentrancy LO
    // 4 => reentrancy RO
    // 5 => reentrancy FlashLoan
    uint operator;
    IBorrowerOperations borrowerOperations;
    ILiquidatorOperations liquidatorOperations;
    IRedeemerOperations redeemerOperations;

    function setAddress(
        address _borrowerOperationsAddress,
        address _liquidatorOperationsAddress,
        address _redeemerOperationsAddress
    ) external {
        checkContract(_borrowerOperationsAddress);
        checkContract(_liquidatorOperationsAddress);
        checkContract(_redeemerOperationsAddress);
        borrowerOperations = IBorrowerOperations(_borrowerOperationsAddress);
        liquidatorOperations = ILiquidatorOperations(_liquidatorOperationsAddress);
        redeemerOperations = IRedeemerOperations(_redeemerOperationsAddress);
    }

    function executeOperation(address _asset, uint _amount, uint _fee, address _repayAddress, bytes calldata _params) external {
        uint _balance = address(_asset).balanceOf(address(this));
        uint _repayAmount = _amount;
        if (operator == 0) {
            _repayAmount = _repayAmount.add(_fee);
            require(_balance >= _repayAmount, "receiver: don't have enough asset to repay");
        } else if (operator == 2) {
            borrowerOperations.openTrove(_asset, 0, _amount, 200 * DECIMAL_PRECISION, address(0), address (0));
        } else if (operator == 3) {
            liquidatorOperations.liquidate(address(0), _asset);
        } else if (operator == 4) {
            redeemerOperations.redeemCollateral(_asset, 0, address(0), address(0), address(0), 0, 0, 0);
        } else if (operator == 5) {
            IFlashLoanOperations flashLoanOperations = IFlashLoanOperations(address(borrowerOperations));
            flashLoanOperations.flashLoan(address(0), _asset, _amount, _params);
        }
        address(_asset).safeTransferToken(_repayAddress, _repayAmount);
    }

    function setOperator(uint _operator) external {
        operator = _operator;
    }

    receive() external payable {
    }
}
