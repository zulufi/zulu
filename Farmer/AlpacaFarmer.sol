// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Dependencies/AddressLib.sol";
import "../Dependencies/BaseMath.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/IERC20.sol";
import "../Dependencies/MultiAssetInitializable.sol";
import "../Dependencies/LiquityMath.sol";
import "../Interfaces/IAlpacaFarmer.sol";
import "./AbstractFarmer.sol";

// Adapted from: https://github.com/alpaca-finance/bsc-alpaca-contract/blob/main/contracts/6/protocol/interfaces/IVault.sol
interface IVault is IERC20 {
    /// @dev Return the total ERC20 entitled to the token holders. Be careful of unaccrued interests.
    function totalToken() external view returns (uint256);

    /// @dev Add more ERC20 to the bank. Hope to get some good returns.
    function deposit(uint256 amountToken) external payable;

    /// @dev Withdraw ERC20 from the bank by burning the share tokens.
    function withdraw(uint256 share) external;

    /// @dev Request funds from user through Vault
    function requestFunds(address targetedToken, uint256 amount) external;

    function token() external view returns (address);
}

// Adapted from: https://github.com/alpaca-finance/bsc-alpaca-contract/blob/main/contracts/6/token/interfaces/IFairLaunch.sol
interface IFairLaunch {
    function alpaca() external view returns (address);

    function poolInfo(uint256 _pid)
        external
        view
        returns (
            address,
            uint256,
            uint256,
            uint256,
            uint256
        );

    function userInfo(uint256 _pid, address _user)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            address
        );

    function poolLength() external view returns (uint256);

    function addPool(
        uint256 _allocPoint,
        address _stakeToken,
        bool _withUpdate
    ) external;

    function setPool(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) external;

    function pendingAlpaca(uint256 _pid, address _user) external view returns (uint256);

    function updatePool(uint256 _pid) external;

    function deposit(
        address _for,
        uint256 _pid,
        uint256 _amount
    ) external;

    function withdraw(
        address _for,
        uint256 _pid,
        uint256 _amount
    ) external;

    function withdrawAll(address _for, uint256 _pid) external;

    function harvest(uint256 _pid) external;
}

contract AlpacaFarmer is
    BaseMath,
    CheckContract,
    MultiAssetInitializable,
    IAlpacaFarmer,
    AbstractFarmer
{
    using AddressLib for address;

    address[] public assets;

    IERC20 public alpaca;
    IFairLaunch public fairLaunch;

    struct AlpacaInfo {
        address vault;
        uint256 pid;
    }

    mapping(address => AlpacaInfo) public alpacaInfoMap;

    // asset address => accrued alpaca per stake
    mapping(address => uint256) public A_map;

    // asset address => user address => snapshot of A
    mapping(address => mapping(address => uint256)) public snapshots;

    uint256 public reserveFactor;

    // asset address => reserved alpaca balance
    mapping(address => uint256) public alpacaBalances;

    function initialize() public initializer {
        __Ownable_init();
    }

    function setParams(
        address _troveManagerAddress,
        address _borrowerOperationsAddress,
        address _liquidatorOperationsAddress,
        address _redeemerOperationsAddress,
        address _stabilityPoolAddress,
        address _fairLaunchAddress
    ) external onlyOwner {
        require(borrowerOperationsAddress == address(0), "address has already been set");

        checkContract(_troveManagerAddress);
        checkContract(_borrowerOperationsAddress);
        checkContract(_liquidatorOperationsAddress);
        checkContract(_redeemerOperationsAddress);
        checkContract(_stabilityPoolAddress);

        troveManager = ITroveManagerV2(_troveManagerAddress);
        borrowerOperationsAddress = _borrowerOperationsAddress;
        liquidatorOperationsAddress = _liquidatorOperationsAddress;
        redeemerOperationsAddress = _redeemerOperationsAddress;
        stabilityPoolAddress = _stabilityPoolAddress;

        fairLaunch = IFairLaunch(_fairLaunchAddress);
        alpaca = IERC20(fairLaunch.alpaca());

        reserveFactor = DECIMAL_PRECISION;

        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit LiquidatorOperationsAddressChanged(_liquidatorOperationsAddress);
        emit RedeemerOperationsAddressChanged(_redeemerOperationsAddress);
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);
        emit FairLaunchAddressChanged(_fairLaunchAddress);

        emit ReserveFactorChanged(reserveFactor);
    }

    function initializeAssetInternal(address asset, bytes calldata data) internal override {
        (address vault, uint256 pid) = abi.decode(data, (address, uint256));
        checkContract(vault);
        address token = IVault(vault).token();
        // token address must match except bnb
        require(asset.isPlatformToken() || asset == token, "AlpacaFarmer: invalid vault address");

        (address stakeToken, , , , ) = fairLaunch.poolInfo(pid);
        require(vault == stakeToken, "AlpacaFarmer: invalid pid");

        alpacaInfoMap[asset] = AlpacaInfo(vault, pid);

        assets.push(asset);
    }

    function updateReserveFactor(uint256 _reserveFactor) external override onlyOwner {
        require(_reserveFactor <= DECIMAL_PRECISION, "AlpacaFarmer: invalid reserveFactor");

        ITroveManagerV2 troveManagerCached = troveManager;
        for (uint256 idx = 0; idx < assets.length; idx++) {
            address asset = assets[idx];
            uint256 totalStakes = troveManagerCached.getTotalStakes(asset);

            _accrueAlpaca(asset, totalStakes);
        }

        reserveFactor = _reserveFactor;
        emit ReserveFactorChanged(_reserveFactor);
    }

    function withdrawAlpaca(
        address _asset,
        address _account,
        uint256 _amount
    ) external override onlyOwner {
        require(_account != address(0), "AlpacaFarmer: can't withdraw to address(0)");
        require(_amount <= alpacaBalances[_asset], "AlpacaFarmer: insufficient alpaca to withdraw");

        _updateAlpacaBalance(_asset, _amount, false);

        alpaca.transfer(_account, _amount);

        emit AlpacaWithdrawn(_asset, _account, _amount);
    }

    function withdrawIBToken(
        address _asset,
        address _account,
        uint256 _amount
    ) external override onlyOwner {
        require(_account != address(0), "AlpacaFarmer: can't withdraw to address(0)");

        AlpacaInfo memory alpacaInfo = alpacaInfoMap[_asset];
        IVault vaultCached = IVault(alpacaInfo.vault);
        IFairLaunch fairLaunchCached = fairLaunch;

        // make sure the rest share can cover coll
        uint256 coll = troveManager.getEntireSystemColl(_asset);
        uint256 shareFromColl = _getShareFromAmount(vaultCached, coll);
        (uint256 share, , , ) = fairLaunchCached.userInfo(alpacaInfo.pid, address(this));
        require(
            _amount <= share.sub(shareFromColl),
            "AlpacaFarmer: insufficient ibtoken to withdraw"
        );

        // unstake ibtoken
        fairLaunchCached.withdraw(address(this), alpacaInfo.pid, _amount);

        address(vaultCached).safeTransferToken(_account, _amount);

        emit IBTokenWithdrawn(_asset, _account, _amount);
    }

    function getPendingAlpaca(address _asset, address _user)
        external
        view
        override
        returns (uint256)
    {
        uint256 stake = troveManager.getTroveStake(_user, _asset);
        return _getPendingAlpaca(_asset, _user, stake);
    }

    function balanceOfAsset(address _asset) external view override returns (uint256) {
        AlpacaInfo memory alpacaInfo = alpacaInfoMap[_asset];
        (uint256 share, , , ) = fairLaunch.userInfo(alpacaInfo.pid, address(this));
        return _getAmountFromShare(IVault(alpacaInfo.vault), share);
    }

    function _deposit(address _asset, uint256 _amount) internal override {
        AlpacaInfo memory alpacaInfo = alpacaInfoMap[_asset];
        IVault vaultCached = IVault(alpacaInfo.vault);

        // deposit and get ibtoken
        uint256 shareBefore = IERC20(vaultCached).balanceOf(address(this));
        if (_asset.isPlatformToken()) {
            vaultCached.deposit{value: _amount}(_amount);
        } else {
            IERC20(_asset).approve(address(vaultCached), _amount);
            vaultCached.deposit(_amount);
        }
        uint256 shareAfter = IERC20(vaultCached).balanceOf(address(this));
        uint256 shareGain = shareAfter.sub(shareBefore);
        // ensure we got enough share, slightly more share to resolve rounding
        require(
            _getAmountFromShare(vaultCached, shareGain.add(1)) >= _amount,
            "AlpacaFarmer: fail to deposit"
        );

        // stake ibtoken
        vaultCached.approve(address(fairLaunch), shareGain);
        fairLaunch.deposit(address(this), alpacaInfo.pid, shareGain);

        emit VaultDeposited(_asset, _amount, shareGain);
        emit Staked(_asset, shareGain);
    }

    function _withdraw(address _asset, uint256 _amount) internal override {
        _requireNonZeroAmount(_amount);

        AlpacaInfo memory alpacaInfo = alpacaInfoMap[_asset];
        IVault vaultCached = IVault(alpacaInfo.vault);
        IFairLaunch fairLaunchCached = fairLaunch;

        // withdraw 0 to accrue interest first
        vaultCached.withdraw(0);
        (uint256 share, , , ) = fairLaunchCached.userInfo(alpacaInfo.pid, address(this));
        uint256 shareToWithdraw = LiquityMath._min(_getShareFromAmount(vaultCached, _amount), share);

        // alpaca should have been correctly accrued and no reward should happen here
        require(
            fairLaunchCached.pendingAlpaca(alpacaInfo.pid, address(this)) == 0,
            "AlpacaFarmer: reward not accrued"
        );
        // unstake ibtoken
        fairLaunchCached.withdraw(address(this), alpacaInfo.pid, shareToWithdraw);

        // withdraw ibtoken
        uint256 balanceBefore = address(_asset).balanceOf(address(this));
        vaultCached.withdraw(shareToWithdraw);
        uint256 balanceAfter = address(_asset).balanceOf(address(this));
        // ensure we get enough asset amount
        require(balanceAfter.sub(balanceBefore) >= _amount, "AlpacaFarmer: fail to withdraw");

        emit Unstaked(_asset, shareToWithdraw);
        emit VaultWithdrawn(_asset, shareToWithdraw, balanceAfter.sub(balanceBefore));
    }

    function _issueRewards(address _asset, address _user) internal override {
        ITroveManagerV2 troveManagerCached = troveManager;
        uint256 stake = troveManagerCached.getTroveStake(_user, _asset);
        uint256 totalStakes = troveManagerCached.getTotalStakes(_asset);

        _accrueAlpaca(_asset, totalStakes);

        _sendAlpacaAndUpdateSnapshot(_asset, _user, stake);
    }

    function _accrueAlpaca(address _asset, uint256 totalStakes) internal {
        AlpacaInfo memory alpacaInfo = alpacaInfoMap[_asset];

        IFairLaunch fairLaunchCached = fairLaunch;
        if (fairLaunchCached.pendingAlpaca(alpacaInfo.pid, address(this)) == 0) {
            // no alpaca to harvest
            return;
        }

        uint256 alpacaBalanceBefore = alpaca.balanceOf(address(this));
        fairLaunchCached.harvest(alpacaInfo.pid);
        uint256 alpacaBalanceAfter = alpaca.balanceOf(address(this));
        uint256 alpacaGain = alpacaBalanceAfter.sub(alpacaBalanceBefore);
        if (alpacaGain == 0) {
            return;
        }

        if (totalStakes > 0) {
            uint256 reservedalpacaGain = alpacaGain.mul(reserveFactor).div(DECIMAL_PRECISION);
            _updateAlpacaBalance(_asset, reservedalpacaGain, true);

            alpacaGain = alpacaGain.sub(reservedalpacaGain);
            uint256 alpacaPerStake = alpacaGain.mul(DECIMAL_PRECISION).div(totalStakes);
            uint256 newA = A_map[_asset].add(alpacaPerStake);
            A_map[_asset] = newA;
            emit A_Updated(_asset, newA);
        } else {
            _updateAlpacaBalance(_asset, alpacaGain, true);
        }
    }

    function _sendAlpacaAndUpdateSnapshot(
        address _asset,
        address _user,
        uint256 _stake
    ) internal {
        uint256 pendingCake = _getPendingAlpaca(_asset, _user, _stake);

        uint256 currentA = A_map[_asset];
        snapshots[_asset][_user] = currentA;

        emit UserSnapshotUpdated(_asset, _user, currentA);

        if (pendingCake == 0) {
            return;
        }

        alpaca.transfer(_user, pendingCake);
        emit AlpacaSent(_asset, _user, pendingCake);
    }

    function _updateAlpacaBalance(
        address _asset,
        uint256 _balanceChange,
        bool _isBalanceIncrease
    ) internal {
        uint256 newAlpacaBalance = _isBalanceIncrease
            ? alpacaBalances[_asset].add(_balanceChange)
            : alpacaBalances[_asset].sub(_balanceChange);
        alpacaBalances[_asset] = newAlpacaBalance;
        emit AlpacaBalanceUpdated(_asset, newAlpacaBalance);
    }

    function _getPendingAlpaca(
        address _asset,
        address _user,
        uint256 _stake
    ) internal view returns (uint256) {
        if (_stake == 0) {
            return 0;
        }

        return _stake.mul(A_map[_asset].sub(snapshots[_asset][_user])).div(DECIMAL_PRECISION);
    }

    // calculate asset amount from ibtoken share
    // based on alpaca code: uint256 amount = share.mul(totalToken()).div(totalSupply());
    function _getAmountFromShare(IVault _vault, uint256 _share) internal view returns (uint256) {
        return _share.mul(_vault.totalToken()).div(_vault.totalSupply());
    }

    // calculate ibtoken share for given asset amount
    // based on alpaca code: uint256 amount = share.mul(totalToken()).div(totalSupply());
    function _getShareFromAmount(IVault _vault, uint256 _amount) internal view returns (uint256) {
        uint256 share = _amount.mul(_vault.totalSupply()).div(_vault.totalToken());
        if (_getAmountFromShare(_vault, share) == _amount) {
            return share;
        } else {
            // slightly more to resolve rounding
            return share.add(1);
        }
    }

    function _emergencyStop() internal virtual override {
        ITroveManagerV2 troveManagerCached = troveManager;
        for (uint256 idx = 0; idx < assets.length; idx++) {
            address asset = assets[idx];
            uint256 totalStakes = troveManagerCached.getTotalStakes(asset);

            _accrueAlpaca(asset, totalStakes);

            AlpacaInfo memory alpacaInfo = alpacaInfoMap[asset];
            IVault vaultCached = IVault(alpacaInfo.vault);
            IFairLaunch fairLaunchCached = fairLaunch;

            (uint256 share, , , ) = fairLaunchCached.userInfo(alpacaInfo.pid, address(this));

            if (share == 0) {
                continue;
            }

            // unstake ibtoken
            fairLaunchCached.withdraw(address(this), alpacaInfo.pid, share);

            // withdraw ibtoken
            uint256 balanceBefore = address(asset).balanceOf(address(this));
            vaultCached.withdraw(share);
            uint256 balanceAfter = address(asset).balanceOf(address(this));

            emit Unstaked(asset, share);
            emit VaultWithdrawn(asset, share, balanceAfter.sub(balanceBefore));
        }
    }

    receive() external payable {}
}
