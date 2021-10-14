// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/ISortedTroves.sol";
import "./Interfaces/ITroveManagerV2.sol";
import "./Interfaces/IBorrowerOperations.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/console.sol";
import "./Dependencies/MultiAssetInitializable.sol";

/*
* A sorted doubly linked list with nodes sorted in descending order.
*
* Nodes map to active Troves in the system - the ID property is the address of a Trove owner.
* Nodes are ordered according to their current nominal individual collateral ratio (NICR),
* which is like the ICR but without the price, i.e., just collateral / debt.
*
* The list optionally accepts insert position hints.
*
* NICRs are computed dynamically at runtime, and not stored on the Node. This is because NICRs of active Troves
* change dynamically as liquidation events occur.
*
* The list relies on the fact that liquidation events preserve ordering: a liquidation decreases the NICRs of all active Troves,
* but maintains their order. A node inserted based on current NICR will maintain the correct position,
* relative to it's peers, as rewards accumulate, as long as it's raw collateral and debt have not changed.
* Thus, Nodes remain sorted by current NICR.
*
* Nodes need only be re-inserted upon a Trove operation - when the owner adds or removes collateral or debt
* to their position.
*
* The list is a modification of the following audited SortedDoublyLinkedList:
* https://github.com/livepeer/protocol/blob/master/contracts/libraries/SortedDoublyLL.sol
*
*
* Changes made in the Liquity implementation:
*
* - Keys have been removed from nodes
*
* - Ordering checks for insertion are performed by comparing an NICR argument to the current NICR, calculated at runtime.
*   The list relies on the property that ordering by ICR is maintained as the ETH:USD price varies.
*
* - Public functions with parameters have been made internal to save gas, and given an external wrapper function for external access
*/
contract SortedTroves is MultiAssetInitializable, CheckContract, ISortedTroves {
    using SafeMath for uint256;

    string constant public NAME = "SortedTroves";

    ITroveManagerV2 public troveManager;

    uint256 public maxSize; // Maximum size of the list

    // Information for a node in the list
    struct Node {
        bool exists;
        address nextId;                  // Id of next node (smaller NICR) in the list
        address prevId;                  // Id of previous node (larger NICR) in the list
    }

    // Information for the list
    struct Data {
        address asset;                       // underlying asset address
        address head;                        // Head of the list. Also the node in the list with the largest NICR
        address tail;                        // Tail of the list. Also the node in the list with the smallest NICR
        uint256 size;                        // Current size of the list
        mapping (address => Node) nodes;     // Track the corresponding ids for each node in the list
    }

    mapping (address => Data) public dataMap;

    // --- Dependency setters ---

    function initialize() public initializer {
        __Ownable_init();
    }

    function setParams(uint256 _size, address _troveManagerAddress) external override onlyOwner {
        require(_size > 0, "SortedTroves: Size can’t be zero");
        require(address(troveManager) == address(0), "address has already been set");

        checkContract(_troveManagerAddress);

        maxSize = _size;

        troveManager = ITroveManagerV2(_troveManagerAddress);

        emit TroveManagerAddressChanged(_troveManagerAddress);
    }

    // --- Abstract methods of MultiAssetContract ---

    function initializeAssetInternal(address asset, bytes calldata data)
        override
        internal
    {
        dataMap[asset].asset = asset;
    }

    /*
     * @dev Add a node to the list
     * @param _asset asset's address
     * @param _id Node's id
     * @param _NICR Node's NICR
     * @param _prevId Id of previous node for the insert position
     * @param _nextId Id of next node for the insert position
     */

    function insert (address _asset, address _id, uint256 _NICR, address _prevId, address _nextId) external override {
        ITroveManagerV2 troveManagerCached = troveManager;

        _requireCallerIsTroveManager();

        _insert(troveManagerCached, dataMap[_asset], _id, _NICR, _prevId, _nextId);
    }

    function _insert(ITroveManagerV2 _troveManager, Data storage _data, address _id, uint256 _NICR, address _prevId, address _nextId) internal {
        // List must not be full
        require(!_isFull(_data), "SortedTroves: List is full");
        // List must not already contain node
        require(!_contains(_data, _id), "SortedTroves: List already contains the node");
        // Node id must not be null
        require(_id != address(0), "SortedTroves: Id cannot be zero");
        // NICR must be non-zero
        require(_NICR > 0, "SortedTroves: NICR must be positive");

        address prevId = _prevId;
        address nextId = _nextId;

        if (!_validInsertPosition(_troveManager, _data, _NICR, prevId, nextId)) {
            // Sender's hint was not a valid insert position
            // Use sender's hint to find a valid insert position
            (prevId, nextId) = _findInsertPosition(_troveManager, _data, _NICR, prevId, nextId);
        }

        _data.nodes[_id].exists = true;

        if (prevId == address(0) && nextId == address(0)) {
            // Insert as head and tail
            _data.head = _id;
            _data.tail = _id;
        } else if (prevId == address(0)) {
            // Insert before `prevId` as the head
            _data.nodes[_id].nextId = _data.head;
            _data.nodes[_data.head].prevId = _id;
            _data.head = _id;
        } else if (nextId == address(0)) {
            // Insert after `nextId` as the tail
            _data.nodes[_id].prevId = _data.tail;
            _data.nodes[_data.tail].nextId = _id;
            _data.tail = _id;
        } else {
            // Insert at insert position between `prevId` and `nextId`
            _data.nodes[_id].nextId = nextId;
            _data.nodes[_id].prevId = prevId;
            _data.nodes[prevId].nextId = _id;
            _data.nodes[nextId].prevId = _id;
        }

        _data.size = _data.size.add(1);
        emit NodeAdded(_data.asset, _id, _NICR);
    }

    function remove(address _asset, address _id) external override {
        _requireCallerIsTroveManager();
        _remove(dataMap[_asset], _id);
    }

    /*
     * @dev Remove a node from the list
     * @param _data list information, passed in as param to save SLOAD’s
     * @param _id Node's id
     */
    function _remove(Data storage _data, address _id) internal {
        // List must contain the node
        require(_contains(_data, _id), "SortedTroves: List does not contain the id");

        if (_data.size > 1) {
            // List contains more than a single node
            if (_id == _data.head) {
                // The removed node is the head
                // Set head to next node
                _data.head = _data.nodes[_id].nextId;
                // Set prev pointer of new head to null
                _data.nodes[_data.head].prevId = address(0);
            } else if (_id == _data.tail) {
                // The removed node is the tail
                // Set tail to previous node
                _data.tail = _data.nodes[_id].prevId;
                // Set next pointer of new tail to null
                _data.nodes[_data.tail].nextId = address(0);
            } else {
                // The removed node is neither the head nor the tail
                // Set next pointer of previous node to the next node
                _data.nodes[_data.nodes[_id].prevId].nextId = _data.nodes[_id].nextId;
                // Set prev pointer of next node to the previous node
                _data.nodes[_data.nodes[_id].nextId].prevId = _data.nodes[_id].prevId;
            }
        } else {
            // List contains a single node
            // Set the head and tail to null
            _data.head = address(0);
            _data.tail = address(0);
        }

        delete _data.nodes[_id];
        _data.size = _data.size.sub(1);
        emit NodeRemoved(_data.asset, _id);
    }

    /*
     * @dev Re-insert the node at a new position, based on its new NICR
     * @param _asset asset's address
     * @param _id Node's id
     * @param _newNICR Node's new NICR
     * @param _prevId Id of previous node for the new insert position
     * @param _nextId Id of next node for the new insert position
     */
    function reInsert(address _asset, address _id, uint256 _newNICR, address _prevId, address _nextId) external override {
        _requireCallerIsTroveManager();
        ITroveManagerV2 troveManagerCached = troveManager;

        Data storage data = dataMap[_asset];
        // List must contain the node
        require(_contains(data, _id), "SortedTroves: List does not contain the id");
        // NICR must be non-zero
        require(_newNICR > 0, "SortedTroves: NICR must be positive");

        // Remove node from the list
        _remove(data, _id);

        _insert(troveManagerCached, data, _id, _newNICR, _prevId, _nextId);
    }

    function _contains(Data storage _data, address _id) internal view returns (bool) {
        return _data.nodes[_id].exists;
    }

    function _isFull(Data memory _data) internal view returns (bool) {
        return _data.size == maxSize;
    }

    function _isEmpty(Data memory _data) internal pure returns (bool) {
        return _data.size == 0;
    }

    /*
     * @dev Checks if the list contains a node
     */
    function contains(address _asset, address _id) public view override returns (bool) {
        return _contains(dataMap[_asset], _id);
    }

    /*
     * @dev Checks if the list is full
     */
    function isFull(address _asset) public view override returns (bool) {
        return _isFull(dataMap[_asset]);
    }

    /*
     * @dev Checks if the list is empty
     */
    function isEmpty(address _asset) public view override returns (bool) {
        return _isEmpty(dataMap[_asset]);
    }

    /*
     * @dev Returns the current size of the list
     */
    function getSize(address _asset) external view override returns (uint256) {
        return dataMap[_asset].size;
    }

    /*
     * @dev Returns the first node in the list (node with the largest NICR)
     */
    function getFirst(address _asset) external view override returns (address) {
        return dataMap[_asset].head;
    }

    /*
     * @dev Returns the last node in the list (node with the smallest NICR)
     */
    function getLast(address _asset) external view override returns (address) {
        return dataMap[_asset].tail;
    }

    /*
     * @dev Returns the next node (with a smaller NICR) in the list for a given node
     * @param _asset asset's address
     * @param _id Node's id
     */
    function getNext(address _asset, address _id) external view override returns (address) {
        return dataMap[_asset].nodes[_id].nextId;
    }

    /*
     * @dev Returns the previous node (with a larger NICR) in the list for a given node
     * @param _asset asset's address
     * @param _id Node's id
     */
    function getPrev(address _asset, address _id) external view override returns (address) {
        return dataMap[_asset].nodes[_id].prevId;
    }

    /*
     * @dev Check if a pair of nodes is a valid insertion point for a new node with the given NICR
     * @param _asset asset's address
     * @param _NICR Node's NICR
     * @param _prevId Id of previous node for the insert position
     * @param _nextId Id of next node for the insert position
     */
    function validInsertPosition(address _asset, uint256 _NICR, address _prevId, address _nextId) external view override returns (bool) {
        return _validInsertPosition(troveManager, dataMap[_asset], _NICR, _prevId, _nextId);
    }

    function _validInsertPosition(ITroveManagerV2 _troveManager, Data storage _data, uint256 _NICR, address _prevId, address _nextId) internal view returns (bool) {
        if (_prevId == address(0) && _nextId == address(0)) {
            // `(null, null)` is a valid insert position if the list is empty
            return _isEmpty(_data);
        } else if (_prevId == address(0)) {
            // `(null, _nextId)` is a valid insert position if `_nextId` is the head of the list
            return _data.head == _nextId && _NICR >= _troveManager.getNominalICR(_nextId, _data.asset);
        } else if (_nextId == address(0)) {
            // `(_prevId, null)` is a valid insert position if `_prevId` is the tail of the list
            return _data.tail == _prevId && _NICR <= _troveManager.getNominalICR(_prevId, _data.asset);
        } else {
            // `(_prevId, _nextId)` is a valid insert position if they are adjacent nodes and `_NICR` falls between the two nodes' NICRs
            return _data.nodes[_prevId].nextId == _nextId &&
                   _troveManager.getNominalICR(_prevId, _data.asset) >= _NICR &&
                   _NICR >= _troveManager.getNominalICR(_nextId, _data.asset);
        }
    }

    /*
     * @dev Descend the list (larger NICRs to smaller NICRs) to find a valid insert position
     * @param _troveManager TroveManager contract, passed in as param to save SLOAD’s
     * @param _data list information, passed in as param to save SLOAD’s
     * @param _NICR Node's NICR
     * @param _startId Id of node to start descending the list from
     */
    function _descendList(ITroveManagerV2 _troveManager, Data storage _data, uint256 _NICR, address _startId) internal view returns (address, address) {
        // If `_startId` is the head, check if the insert position is before the head
        if (_data.head == _startId && _NICR >= _troveManager.getNominalICR(_startId, _data.asset)) {
            return (address(0), _startId);
        }

        address prevId = _startId;
        address nextId = _data.nodes[prevId].nextId;

        // Descend the list until we reach the end or until we find a valid insert position
        while (prevId != address(0) && !_validInsertPosition(_troveManager, _data, _NICR, prevId, nextId)) {
            prevId = _data.nodes[prevId].nextId;
            nextId = _data.nodes[prevId].nextId;
        }

        return (prevId, nextId);
    }

    /*
     * @dev Ascend the list (smaller NICRs to larger NICRs) to find a valid insert position
     * @param _troveManager TroveManager contract, passed in as param to save SLOAD’s
     * @param _data list information, passed in as param to save SLOAD’s
     * @param _NICR Node's NICR
     * @param _startId Id of node to start ascending the list from
     */
    function _ascendList(ITroveManagerV2 _troveManager, Data storage _data, uint256 _NICR, address _startId) internal view returns (address, address) {
        // If `_startId` is the tail, check if the insert position is after the tail
        if (_data.tail == _startId && _NICR <= _troveManager.getNominalICR(_startId, _data.asset)) {
            return (_startId, address(0));
        }

        address nextId = _startId;
        address prevId = _data.nodes[nextId].prevId;

        // Ascend the list until we reach the end or until we find a valid insertion point
        while (nextId != address(0) && !_validInsertPosition(_troveManager, _data, _NICR, prevId, nextId)) {
            nextId = _data.nodes[nextId].prevId;
            prevId = _data.nodes[nextId].prevId;
        }

        return (prevId, nextId);
    }

    /*
     * @dev Find the insert position for a new node with the given NICR
     * @param _asset asset's address
     * @param _NICR Node's NICR
     * @param _prevId Id of previous node for the insert position
     * @param _nextId Id of next node for the insert position
     */
    function findInsertPosition(address _asset, uint256 _NICR, address _prevId, address _nextId) external view override returns (address, address) {
        return _findInsertPosition(troveManager, dataMap[_asset], _NICR, _prevId, _nextId);
    }

    function _findInsertPosition(ITroveManagerV2 _troveManager, Data storage _data, uint256 _NICR, address _prevId, address _nextId) internal view returns (address, address) {
        address prevId = _prevId;
        address nextId = _nextId;

        if (prevId != address(0)) {
            if (!_contains(_data, prevId) || _NICR > _troveManager.getNominalICR(prevId, _data.asset)) {
                // `prevId` does not exist anymore or now has a smaller NICR than the given NICR
                prevId = address(0);
            }
        }

        if (nextId != address(0)) {
            if (!_contains(_data, nextId) || _NICR < _troveManager.getNominalICR(nextId, _data.asset)) {
                // `nextId` does not exist anymore or now has a larger NICR than the given NICR
                nextId = address(0);
            }
        }

        if (prevId == address(0) && nextId == address(0)) {
            // No hint - descend list starting from head
            return _descendList(_troveManager, _data, _NICR, _data.head);
        } else if (prevId == address(0)) {
            // No `prevId` for hint - ascend list starting from `nextId`
            return _ascendList(_troveManager, _data, _NICR, nextId);
        } else if (nextId == address(0)) {
            // No `nextId` for hint - descend list starting from `prevId`
            return _descendList(_troveManager, _data, _NICR, prevId);
        } else {
            // Descend list starting from `prevId`
            return _descendList(_troveManager, _data, _NICR, prevId);
        }
    }

    // --- 'require' functions ---

    function _requireCallerIsTroveManager() internal view {
        require(msg.sender == address(troveManager), "SortedTroves: Caller is not the TroveManager");
    }
}
