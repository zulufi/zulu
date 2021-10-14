// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;


interface IFeeRateModel {
    function calcBorrowRate(address asset, uint price, uint borrowAmount) external returns (uint);
    function calcRedeemRate(address asset, uint price, uint redeemAmount) external returns (uint);
    function getBorrowRate(address asset, uint price, uint borrowAmount) external view returns (uint);
    function getRedeemRate(address asset, uint price, uint redeemAmount) external view returns (uint);
}
