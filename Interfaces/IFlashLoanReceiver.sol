// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface IFlashLoanReceiver {
   function executeOperation(address _asset, uint256 _amount, uint256 _fee, address _repayAddress, bytes calldata _params) external;
}
