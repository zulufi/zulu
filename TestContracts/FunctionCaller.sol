// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import '../Interfaces/ITroveManagerV2.sol';
import '../Interfaces/ISortedTroves.sol';
import '../Interfaces/IPriceFeed.sol';
import '../Dependencies/LiquityMath.sol';

/* Wrapper contract - used for calculating gas of read-only and internal functions. 
Not part of the Liquity application. */
contract FunctionCaller {

    ITroveManagerV2 troveManager;
    address public troveManagerAddress;

    ISortedTroves sortedTroves;
    address public sortedTrovesAddress;

    IPriceFeed priceFeed;
    address public priceFeedAddress;

    // --- Dependency setters ---

    function setTroveManagerAddress(address _troveManagerAddress) external {
        troveManagerAddress = _troveManagerAddress;
        troveManager = ITroveManagerV2(_troveManagerAddress);
    }
    
    function setSortedTrovesAddress(address _sortedTrovesAddress) external {
        troveManagerAddress = _sortedTrovesAddress;
        sortedTroves = ISortedTroves(_sortedTrovesAddress);
    }

     function setPriceFeedAddress(address _priceFeedAddress) external {
        priceFeedAddress = _priceFeedAddress;
        priceFeed = IPriceFeed(_priceFeedAddress);
    }

    // --- Non-view wrapper functions used for calculating gas ---
    
    function troveManager_getCurrentICR(address _address, address _asset, uint _price) external view returns (uint) {
        return troveManager.getCurrentICR(_address, _asset, _price);
    }

    function sortedTroves_findInsertPosition(address _asset, uint _NICR, address _prevId, address _nextId) external view returns (address, address) {
        return sortedTroves.findInsertPosition(_asset, _NICR, _prevId, _nextId);
    }
}
