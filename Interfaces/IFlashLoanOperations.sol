// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface IFlashLoanOperations {
    // --- Events ---
    event FlashLoan(address indexed _receiver, address indexed _asset, uint256 _amount, uint256 _fee, uint256 _realFee);


    // --- Functions ---
    function flashLoan(address _receiver, address _asset, uint256 _amount, bytes memory _params) external;
}
