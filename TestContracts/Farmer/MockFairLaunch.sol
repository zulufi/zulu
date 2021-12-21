// SPDX-License-Identifier: MIT
/**
  ∩~~~~∩
  ξ ･×･ ξ
  ξ　~　ξ
  ξ　　 ξ
  ξ　　 “~～~～〇
  ξ　　　　　　 ξ
  ξ ξ ξ~～~ξ ξ ξ
　 ξ_ξξ_ξ　ξ_ξξ_ξ
Alpaca Fin Corporation
*/

pragma solidity 0.6.11;

import "../../LPRewards/TestContracts/ERC20Mock.sol";

// Adapted from: https://github.com/alpaca-finance/bsc-alpaca-contract/blob/main/contracts/6/token/FairLaunch.sol

// FairLaunch is a smart contract for distributing ALPACA by asking user to stake the ERC20-based token.
contract MockFairLaunch {
    using SafeMath for uint256;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many Staking tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 bonusDebt; // Last block that user exec something to the pool.
        address fundedBy; // Funded by who?
        //
        // We do some fancy math here. Basically, any point in time, the amount of ALPACAs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accAlpacaPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws Staking tokens to a pool. Here's what happens:
        //   1. The pool's `accAlpacaPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        address stakeToken; // Address of Staking token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. ALPACAs to distribute per block.
        uint256 lastRewardBlock; // Last block number that ALPACAs distribution occurs.
        uint256 accAlpacaPerShare; // Accumulated ALPACAs per share, times 1e12. See below.
        uint256 accAlpacaPerShareTilBonusEnd; // Accumated ALPACAs per share until Bonus End.
    }

    // The Alpaca TOKEN!
    ERC20Mock public alpaca;
    // ALPACA tokens created per block.
    uint256 public alpacaPerBlock;
    // Bonus lock-up in BPS
    uint256 public bonusLockUpBps;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes Staking tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // The block number when ALPACA mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(ERC20Mock _alpaca) public {
        alpaca = _alpaca;
        alpacaPerBlock = 100e18;
        startBlock = block.number;
    }

    /*
  ██████╗░░█████╗░██████╗░░█████╗░███╗░░░███╗  ░██████╗███████╗████████╗████████╗███████╗██████╗░
  ██╔══██╗██╔══██╗██╔══██╗██╔══██╗████╗░████║  ██╔════╝██╔════╝╚══██╔══╝╚══██╔══╝██╔════╝██╔══██╗
  ██████╔╝███████║██████╔╝███████║██╔████╔██║  ╚█████╗░█████╗░░░░░██║░░░░░░██║░░░█████╗░░██████╔╝
  ██╔═══╝░██╔══██║██╔══██╗██╔══██║██║╚██╔╝██║  ░╚═══██╗██╔══╝░░░░░██║░░░░░░██║░░░██╔══╝░░██╔══██╗
  ██║░░░░░██║░░██║██║░░██║██║░░██║██║░╚═╝░██║  ██████╔╝███████╗░░░██║░░░░░░██║░░░███████╗██║░░██║
  ╚═╝░░░░░╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░░░░╚═╝  ╚═════╝░╚══════╝░░░╚═╝░░░░░░╚═╝░░░╚══════╝╚═╝░░╚═╝
  */

    function setAlpacaPerBlock(uint256 _alpacaPerBlock) external {
        alpacaPerBlock = _alpacaPerBlock;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function addPool(address _stakeToken, bool _withUpdate) external {
        if (_withUpdate) {
            massUpdatePools();
        }
        require(_stakeToken != address(0), "add: not stakeToken addr");
        require(!isDuplicatedPool(_stakeToken), "add: stakeToken dup");
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        poolInfo.push(
            PoolInfo({
                stakeToken: _stakeToken,
                allocPoint: 0,
                lastRewardBlock: lastRewardBlock,
                accAlpacaPerShare: 0,
                accAlpacaPerShareTilBonusEnd: 0
            })
        );
    }

    /*
  ░██╗░░░░░░░██╗░█████╗░██████╗░██╗░░██╗
  ░██║░░██╗░░██║██╔══██╗██╔══██╗██║░██╔╝
  ░╚██╗████╗██╔╝██║░░██║██████╔╝█████═╝░
  ░░████╔═████║░██║░░██║██╔══██╗██╔═██╗░
  ░░╚██╔╝░╚██╔╝░╚█████╔╝██║░░██║██║░╚██╗
  ░░░╚═╝░░░╚═╝░░░╚════╝░╚═╝░░╚═╝╚═╝░░╚═╝
  */

    function isDuplicatedPool(address _stakeToken) public view returns (bool) {
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; _pid++) {
            if (poolInfo[_pid].stakeToken == _stakeToken) return true;
        }
        return false;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _lastRewardBlock, uint256 _currentBlock)
        public
        pure
        returns (uint256)
    {
        return _currentBlock.sub(_lastRewardBlock);
    }

    // View function to see pending ALPACAs on frontend.
    function pendingAlpaca(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accAlpacaPerShare = pool.accAlpacaPerShare;
        uint256 lpSupply = IERC20(pool.stakeToken).balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 alpacaReward = multiplier.mul(alpacaPerBlock);
            accAlpacaPerShare = accAlpacaPerShare.add(alpacaReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accAlpacaPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = IERC20(pool.stakeToken).balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 alpacaReward = multiplier.mul(alpacaPerBlock);
        alpaca.mint(address(this), alpacaReward);
        pool.accAlpacaPerShare = pool.accAlpacaPerShare.add(alpacaReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit Staking tokens to FairLaunchToken for ALPACA allocation.
    function deposit(
        address _for,
        uint256 _pid,
        uint256 _amount
    ) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_for];
        if (user.fundedBy != address(0)) require(user.fundedBy == msg.sender, "bad sof");
        require(pool.stakeToken != address(0), "deposit: not accept deposit");
        updatePool(_pid);
        if (user.amount > 0) _harvest(_for, _pid);
        if (user.fundedBy == address(0)) user.fundedBy = msg.sender;
        IERC20(pool.stakeToken).transferFrom(address(msg.sender), address(this), _amount);
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accAlpacaPerShare).div(1e12);
        user.bonusDebt = user.amount.mul(pool.accAlpacaPerShareTilBonusEnd).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw Staking tokens from FairLaunchToken.
    function withdraw(
        address _for,
        uint256 _pid,
        uint256 _amount
    ) external {
        _withdraw(_for, _pid, _amount);
    }

    function _withdraw(
        address _for,
        uint256 _pid,
        uint256 _amount
    ) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_for];
        require(user.fundedBy == msg.sender, "only funder");
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        _harvest(_for, _pid);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accAlpacaPerShare).div(1e12);
        user.bonusDebt = user.amount.mul(pool.accAlpacaPerShareTilBonusEnd).div(1e12);
        if (user.amount == 0) user.fundedBy = address(0);
        if (pool.stakeToken != address(0)) {
            IERC20(pool.stakeToken).transfer(address(msg.sender), _amount);
        }
        emit Withdraw(msg.sender, _pid, user.amount);
    }

    // Harvest ALPACAs earn from the pool.
    function harvest(uint256 _pid) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        _harvest(msg.sender, _pid);
        user.rewardDebt = user.amount.mul(pool.accAlpacaPerShare).div(1e12);
        user.bonusDebt = user.amount.mul(pool.accAlpacaPerShareTilBonusEnd).div(1e12);
    }

    function _harvest(address _to, uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_to];
        require(user.amount > 0, "nothing to harvest");
        uint256 pending = user.amount.mul(pool.accAlpacaPerShare).div(1e12).sub(user.rewardDebt);
        require(pending <= alpaca.balanceOf(address(this)), "wtf not enough alpaca");
        safeAlpacaTransfer(_to, pending);
    }

    // Safe alpaca transfer function, just in case if rounding error causes pool to not have enough ALPACAs.
    function safeAlpacaTransfer(address _to, uint256 _amount) internal {
        uint256 alpacaBal = alpaca.balanceOf(address(this));
        if (_amount > alpacaBal) {
            require(alpaca.transfer(_to, alpacaBal), "failed to transfer ALPACA");
        } else {
            require(alpaca.transfer(_to, _amount), "failed to transfer ALPACA");
        }
    }
}
