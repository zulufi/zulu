// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

// Common interface for the SortedTroves Doubly Linked List.
interface ISortedTroves {

    // --- Events ---
    
    event TroveManagerAddressChanged(address _troveManagerAddress);
    event NodeAdded(address indexed _asset, address indexed _id, uint _NICR);
    event NodeRemoved(address indexed _asset, address indexed _id);

    // --- Functions ---
    
    function setParams(uint256 _size, address _troveManagerAddress) external;

    function insert(address _asset, address _id, uint256 _ICR, address _prevId, address _nextId) external;

    function remove(address _asset, address _id) external;

    function reInsert(address _asset, address _id, uint256 _newICR, address _prevId, address _nextId) external;

    function contains(address _asset, address _id) external view returns (bool);

    function isFull(address _asset) external view returns (bool);

    function isEmpty(address _asset) external view returns (bool);

    function getSize(address _asset) external view returns (uint256);

    function getFirst(address _asset) external view returns (address);

    function getLast(address _asset) external view returns (address);

    function getNext(address _asset, address _id) external view returns (address);

    function getPrev(address _asset, address _id) external view returns (address);

    function validInsertPosition(address _asset, uint256 _ICR, address _prevId, address _nextId) external view returns (bool);

    function findInsertPosition(address _asset, uint256 _ICR, address _prevId, address _nextId) external view returns (address, address);
}
