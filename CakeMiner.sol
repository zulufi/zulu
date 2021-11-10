// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Dependencies/BaseMath.sol";
import "./Dependencies/IERC20.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/LiquityMath.sol";
import "./Dependencies/MultiAssetInitializable.sol";
import "./Dependencies/SafeMath.sol";
import "./Interfaces/ICakeMiner.sol";
import "./Interfaces/IPayablePool.sol";
import "./Interfaces/ITroveManagerV2.sol";
import "./TransferHelper.sol";

interface IMasterChef {
    function cake() external view returns (address);

    function poolInfo(uint256 _pid)
        external
        view
        returns (
            address,
            uint256,
            uint256,
            uint256
        );

    function userInfo(uint256 _pid, address _user)
        external
        view
        returns (
            uint256,
            uint256
    );

    function deposit(uint256 _pid, uint256 _amount) external;

    function withdraw(uint256 _pid, uint256 _amount) external;
}

contract CakeMiner is BaseMath, CheckContract, MultiAssetInitializable, ICakeMiner {
    using SafeMath for uint256;
    using TransferHelper for address;

    ITroveManagerV2 public troveManager;

    address public borrowerOperationsAddress;

    address public liquidatorOperationsAddress;

    address public redeemerOperationsAddress;

    address public stabilityPoolAddress;

    address[] public assets;

    // asset address => last cake error correction
    mapping(address => uint256) public lastCakeErrors;

    // asset address => accrued cakes per stake
    mapping(address => uint256) public C_map;

    // asset address => user address => snapshot of C
    mapping(address => mapping(address => uint256)) public snapshots;

    IERC20 public cake;
    IMasterChef public masterChef;
    mapping(address => uint256) public pids;

    uint256 public reserveFactor;

    // asset address => reserved cake balance
    mapping(address => uint256) public assetCakeBalances;

    function initialize() public initializer {
        __Ownable_init();
    }

    function setParams(
        address _troveManagerAddress,
        address _borrowerOperationsAddress,
        address _liquidatorOperationsAddress,
        address _redeemerOperationsAddress,
        address _stabilityPoolAddress,
        address _masterChef
    ) external onlyOwner {
        checkContract(_troveManagerAddress);
        checkContract(_borrowerOperationsAddress);
        checkContract(_liquidatorOperationsAddress);
        checkContract(_redeemerOperationsAddress);
        checkContract(_stabilityPoolAddress);
        checkContract(_masterChef);

        troveManager = ITroveManagerV2(_troveManagerAddress);
        borrowerOperationsAddress = _borrowerOperationsAddress;
        liquidatorOperationsAddress = _liquidatorOperationsAddress;
        redeemerOperationsAddress = _redeemerOperationsAddress;
        stabilityPoolAddress = _stabilityPoolAddress;

        masterChef = IMasterChef(_masterChef);
        cake = IERC20(masterChef.cake());

        reserveFactor = DECIMAL_PRECISION;

        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit LiquidatorOperationsAddressChanged(_liquidatorOperationsAddress);
        emit RedeemerOperationsAddressChanged(_redeemerOperationsAddress);
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);
        emit MasterChefAddressChanged(_masterChef);
        emit CakeAddressChanged(address(cake));
        emit ReserveFactorChanged(reserveFactor);
    }

    function initializeAssetInternal(address asset, bytes calldata data) internal override {
        uint256 pid = abi.decode(data, (uint256));
        (address lpToken, , , ) = masterChef.poolInfo(pid);

        require(asset == lpToken, "CakeMiner: invalid asset or pid");
        pids[asset] = pid;
        assets.push(asset);

        emit AssetAdded(asset, pid);
    }

    function updateReserveFactor(uint256 _reserveFactor) external override onlyOwner {
        require(_reserveFactor <= DECIMAL_PRECISION, "CakeMiner: invalid reserveFactor");

        ITroveManagerV2 troveManagerCached = troveManager;
        for (uint256 idx = 0; idx < assets.length; idx++) {
            address asset = assets[idx];
            uint256 totalStakes = troveManagerCached.getTotalStakes(asset);

            _accrueCake(asset, totalStakes);
        }

        reserveFactor = _reserveFactor;
        emit ReserveFactorChanged(_reserveFactor);
    }

    function withdrawCake(
        address _asset,
        address _account,
        uint256 _amount
    ) external override onlyOwner {
        require(_account != address(0), "CakeMiner: can't withdraw to address(0)");
        require(_amount <= assetCakeBalances[_asset], "CakeMiner: insufficient cake to withdraw");

        _updateAssetCakeBalance(_asset, _amount, false);

        cake.transfer(_account, _amount);
    }

    function isSupported(address _asset) external view override returns (bool) {
        return initializedAssets[_asset];
    }

    function balanceOfAsset(address _asset) external view override returns (uint256) {
        (uint256 balance,) = masterChef.userInfo(pids[_asset], address(this));
        return balance;
    }

    function _accrueCake(address _asset, uint256 totalStakes) internal {
        uint256 cakeBalanceBefore = cake.balanceOf(address(this));
        masterChef.deposit(pids[_asset], 0);
        uint256 cakeBalanceAfter = cake.balanceOf(address(this));
        uint256 cakeGain = cakeBalanceAfter.sub(cakeBalanceBefore);
        if (cakeGain == 0) {
            return;
        }

        if (totalStakes > 0) {
            uint256 reservedCakeGain = cakeGain.mul(reserveFactor).div(DECIMAL_PRECISION);
            _updateAssetCakeBalance(_asset, reservedCakeGain, true);

            cakeGain = cakeGain.sub(reservedCakeGain);
            uint256 cakeNumerator = cakeGain.mul(DECIMAL_PRECISION).add(lastCakeErrors[_asset]);
            uint256 cakePerLp = cakeNumerator.div(totalStakes);
            lastCakeErrors[_asset] = cakeNumerator.sub(cakePerLp.mul(totalStakes));
            uint256 newC = C_map[_asset].add(cakePerLp);
            C_map[_asset] = newC;
            emit C_Updated(_asset, newC);
        } else {
            _updateAssetCakeBalance(_asset, cakeGain, true);
        }
    }

    function _updateAssetCakeBalance(
        address _asset,
        uint256 _balanceChange,
        bool _isBalanceIncrease
    ) internal {
        uint256 newAssetCakeBalance = _isBalanceIncrease
            ? assetCakeBalances[_asset].add(_balanceChange)
            : assetCakeBalances[_asset].sub(_balanceChange);
        assetCakeBalances[_asset] = newAssetCakeBalance;
        emit AssetCakeBalanceUpdated(_asset, newAssetCakeBalance);
    }

    function _getPendingCake(
        address _asset,
        address _user,
        uint256 _stake
    ) internal view returns (uint256) {
        if (_stake == 0) {
            return 0;
        }

        return _stake.mul(C_map[_asset].sub(snapshots[_asset][_user])).div(DECIMAL_PRECISION);
    }

    function _sendCake(
        address _asset,
        address _user,
        uint256 _pendingCake
    ) internal {
        _requireNonZeroAmount(_pendingCake);
        cake.transfer(_user, _pendingCake);

        emit CakeSent(_asset, _user, _pendingCake);
    }

    function _sendCakeAndUpdateSnapshot(
        address _asset,
        address _user,
        uint256 _stake
    ) internal {
        uint256 pendingCake = _getPendingCake(_asset, _user, _stake);

        uint256 currentC = C_map[_asset];
        snapshots[_asset][_user] = currentC;

        emit UserSnapshotUpdated(_asset, _user, currentC);

        if (pendingCake == 0) {
            return;
        }
        _sendCake(_asset, _user, pendingCake);
    }

    function deposit(address _asset, uint256 _amount) external override onlySupportedAsset(_asset) {
        _requireCallerIsBO();
        _requireNonZeroAmount(_amount);

        IERC20(_asset).approve(address(masterChef), _amount);

        uint256 cakeBalanceBefore = cake.balanceOf(address(this));
        masterChef.deposit(pids[_asset], _amount);
        uint256 cakeBalanceAfter = cake.balanceOf(address(this));
        // cake should have been correctly accured and no cake reward will happen here
        assert(cakeBalanceBefore == cakeBalanceAfter);

        emit Deposited(_asset, _amount);
    }

    function _withdraw(address _asset, uint256 _amount) internal {
        _requireNonZeroAmount(_amount);

        uint256 cakeBalanceBefore = cake.balanceOf(address(this));
        masterChef.withdraw(pids[_asset], _amount);
        uint256 cakeBalanceAfter = cake.balanceOf(address(this));
        // cake should have been correctly accured and no cake reward will happen here
        assert(cakeBalanceBefore == cakeBalanceAfter);

        emit Withdrawn(_asset, _amount);
    }

    function _sendAsset(
        address _asset,
        address _to,
        uint256 _amount
    ) internal {
        uint256 _balance = address(_asset).balanceOf(address(this));
        if (_balance < _amount) {
            _withdraw(_asset, _amount.sub(_balance));
        }
        address(_asset).safeTransferToken(_to, _amount);
        emit AssetSent(_asset, _to, _amount);
    }

    function sendAsset(
        address _asset,
        address _user,
        uint256 _amount
    ) external override onlySupportedAsset(_asset) {
        _requireCallerIsBOorLOorRO();
        if (_amount == 0) {
            return;
        }
        _sendAsset(_asset, _user, _amount);
    }

    function sendAssetToPool(
        address _asset,
        address _pool,
        uint256 _amount
    ) external override onlySupportedAsset(_asset) {
        _requireCallerIsLOorROorSP();
        if (_amount == 0) {
            return;
        }
        _sendAsset(_asset, _pool, _amount);
        IPayablePool(_pool).increaseAssetBalance(_asset, _amount);
    }

    function _issueCake(address _asset, address _user) internal {
        ITroveManagerV2 troveManagerCached = troveManager;
        uint256 stake = troveManagerCached.getTroveStake(_user, _asset);
        uint256 totalStakes = troveManagerCached.getTotalStakes(_asset);

        _accrueCake(_asset, totalStakes);

        _sendCakeAndUpdateSnapshot(_asset, _user, stake);
    }

    function issueCake(address _asset, address _user) external override onlySupportedAsset(_asset) {
        _requireCallerIsTOOrBO();

        _issueCake(_asset, _user);
    }

    function claimRewards(address _asset, address _user)
        external
        override
        onlySupportedAsset(_asset)
    {
        _requireCallerIsBO();

        _issueCake(_asset, _user);
    }

    function getPendingCake(address _asset, address _user)
        external
        view
        override
        onlySupportedAsset(_asset)
        returns (uint256)
    {
        uint256 stake = troveManager.getTroveStake(_user, _asset);
        return _getPendingCake(_asset, _user, stake);
    }

    function _requireCallerIsTOOrBO() internal view {
        require(msg.sender == address(troveManager) || msg.sender == borrowerOperationsAddress,
                "CakeMiner: Caller is not TroveManager or BorrowerOperations");
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
        require(_amount > 0, "CakeMiner: Amount must be non-zero");
    }

    function _requireUserHasDeposit(uint256 _lpTokenAmount) internal pure {
        require(_lpTokenAmount > 0, "CakeMiner: User must have a non-zero deposit");
    }
}
