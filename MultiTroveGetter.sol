// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "./Interfaces/ITroveManagerV2.sol";
import "./SortedTroves.sol";
import "./Dependencies/Initializable.sol";
import "./Dependencies/SafeMath.sol";

/*  Helper contract for grabbing Trove data for the front end. Not part of the core Liquity system. */
contract MultiTroveGetter is Initializable {
    using SafeMath for uint;

    struct CombinedTroveData {
        address owner;

        uint debt;
        uint coll;
        uint stake;

    }

    ITroveManagerV2 public troveManager;
    ISortedTroves public sortedTroves;

    function initialize(ITroveManagerV2 _troveManager, ISortedTroves _sortedTroves) public initializer {
        troveManager = _troveManager;
        sortedTroves = _sortedTroves;
    }

    function getMultipleSortedTroves(address _asset, int _startIdx, uint _count)
        external view returns (CombinedTroveData[] memory _troves)
    {
        uint startIdx;
        bool descend;

        if (_startIdx >= 0) {
            startIdx = uint(_startIdx);
            descend = true;
        } else {
            startIdx = uint(-(_startIdx + 1));
            descend = false;
        }

        uint sortedTrovesSize = sortedTroves.getSize(_asset);

        if (startIdx >= sortedTrovesSize) {
            _troves = new CombinedTroveData[](0);
        } else {
            uint maxCount = sortedTrovesSize - startIdx;

            if (_count > maxCount) {
                _count = maxCount;
            }

            if (descend) {
                _troves = _getMultipleSortedTrovesFromHead(_asset, startIdx, _count);
            } else {
                _troves = _getMultipleSortedTrovesFromTail(_asset, startIdx, _count);
            }
        }
    }

    function _getMultipleSortedTrovesFromHead(address _asset, uint _startIdx, uint _count)
        internal view returns (CombinedTroveData[] memory _troves)
    {
        address currentTroveowner = sortedTroves.getFirst(_asset);

        for (uint idx = 0; idx < _startIdx; ++idx) {
            currentTroveowner = sortedTroves.getNext(_asset, currentTroveowner);
        }

        _troves = new CombinedTroveData[](_count);

        for (uint idx = 0; idx < _count; ++idx) {
            _troves[idx] = _getTroveData(currentTroveowner, _asset);

            currentTroveowner = sortedTroves.getNext(_asset, currentTroveowner);
        }
    }

    function _getMultipleSortedTrovesFromTail(address _asset, uint _startIdx, uint _count)
        internal view returns (CombinedTroveData[] memory _troves)
    {
        address currentTroveowner = sortedTroves.getLast(_asset);

        for (uint idx = 0; idx < _startIdx; ++idx) {
            currentTroveowner = sortedTroves.getPrev(_asset, currentTroveowner);
        }

        _troves = new CombinedTroveData[](_count);

        for (uint idx = 0; idx < _count; ++idx) {
            _troves[idx] = _getTroveData(currentTroveowner, _asset);

            currentTroveowner = sortedTroves.getPrev(_asset, currentTroveowner);
        }
    }

    function _getTroveData(address _borrower, address _asset) internal view returns (CombinedTroveData memory troveData) {
        ITroveManagerV2 troveManagerCached = troveManager;
        troveData.owner = _borrower;
        (uint debt, uint coll) = troveManagerCached.getTroveDebtAndColl(msg.sender, _asset);
        troveData.debt = debt;
        troveData.coll = coll;
        troveData.stake = troveManagerCached.getTroveStake(_borrower, _asset);
    }
}
