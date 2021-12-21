// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "../Dependencies/CheckContract.sol";
import "../Dependencies/SafeMath.sol";
import "../Interfaces/ILQTYStaking.sol";
import "../Interfaces/ILQTYToken.sol";
import "../Interfaces/ILockupContractFactory.sol";
import "../Dependencies/console.sol";
import "../Dependencies/Initializable.sol";

/*
* Based upon OpenZeppelin's ERC20 contract:
* https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol
*
* and their EIP2612 (ERC20Permit / ERC712) functionality:
* https://github.com/OpenZeppelin/openzeppelin-contracts/blob/53516bc555a454862470e7860a9b5254db4d00f5/contracts/token/ERC20/ERC20Permit.sol
*
*
*  --- Functionality added specific to the LQTYToken ---
*
* 1) Transfer protection: blacklist of addresses that are invalid recipients (i.e. core Liquity contracts) in external
* transfer() and transferFrom() calls. The purpose is to protect users from losing tokens by mistakenly sending LQTY directly to a Liquity
* core contract, when they should rather call the right function.
*
* 2) sendToLQTYStaking(): callable only by Liquity core contracts, which move LQTY tokens from user -> LQTYStaking contract.
*
* 3) Supply hard-capped at 1 billion
*
* 4) CommunityIssuance and LockupContractFactory addresses are set at deployment
*
* 5) The contributor mining allocation of 150 million tokens is minted at deployment to an EOA
*
* 6) The ido allocation of 50 million tokens are minted at deployment to the Liquity treasury multisig
*
* 7) The operational fund allocation of 170 million tokens are minted at deployment to the Liquity airdrop multisig
*
* 8) 450 million tokens are minted at deployment to the CommunityIssuance contract
*
* 9) 130 million tokens are minted at deployment to the Liquity investor multisig
*
* 10) 100 million tokens are minted at deployment to the Liquity team multisig
*
* 11) Until 90 days from deployment:
* -Liquity team & investor multisig may only transfer() tokens to LockupContracts that have been deployed via & registered in the
*  LockupContractFactory
* -approve(), increaseAllowance(), decreaseAllowance() revert when called by the multisig
* -transferFrom() reverts when the multisig is the sender
* -sendToLQTYStaking() reverts when the multisig is the sender, blocking the multisig from staking its LQTY.
*
* After 90 days has passed since deployment of the LQTYToken, the restrictions on multisig operations are lifted
* and the multisig has the same rights as any other address.
*/

contract LQTYToken is CheckContract, ILQTYToken, Initializable {
    using SafeMath for uint256;

    // --- ERC20 Data ---

    string constant internal _NAME = "ZULU";
    string constant internal _SYMBOL = "ZUL";
    string constant internal _VERSION = "1";
    uint8 constant internal  _DECIMALS = 18;

    mapping (address => Checkpoint[]) checkpoints;

    mapping (address => uint256) private _balances;
    mapping (address => mapping (address => uint256)) private _allowances;
    uint private _totalSupply;

    // --- EIP 2612 Data ---

    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant _PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _TYPE_HASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    // Cache the domain separator as an immutable value, but also store the chain id that it corresponds to, in order to
    // invalidate the cached domain separator if the chain id changes.
    bytes32 private _CACHED_DOMAIN_SEPARATOR;
    uint256 private _CACHED_CHAIN_ID;

    bytes32 private _HASHED_NAME;
    bytes32 private _HASHED_VERSION;

    mapping (address => uint256) private _nonces;

    // --- LQTYToken specific data ---

    uint public constant LOCKUP_PERIOD_IN_SECONDS = 7776000;  // 60 * 60 * 24 * 90

    // uint for use with SafeMath
    uint internal constant _1_MILLION = 1e24;    // 1e6 * 1e18 = 1e24

    uint internal deploymentStartTime;
    address public teamAddress;
    address public investorAddress;

    address public communityIssuanceAddress;
    ILQTYStaking public lqtyStaking;

    uint internal communityIssuanceEntitlement;

    ILockupContractFactory public lockupContractFactory;

    // --- Functions ---

    function initialize
    (
        address _communityIssuanceAddress,
        address _lqtyStakingAddress,
        address _lockupFactoryAddress,
        address _contributorMiningAddress,
        address _idoAddress,
        address _operationalFundAddress,
        address _teamAddress,
        address _investorAddress
    )
        public
        initializer
    {
        checkContract(_communityIssuanceAddress);
        checkContract(_lqtyStakingAddress);
        checkContract(_lockupFactoryAddress);

        teamAddress = _teamAddress;
        investorAddress = _investorAddress;
        deploymentStartTime  = block.timestamp;

        communityIssuanceAddress = _communityIssuanceAddress;
        lqtyStaking = ILQTYStaking(_lqtyStakingAddress);
        lockupContractFactory = ILockupContractFactory(_lockupFactoryAddress);

        bytes32 hashedName = keccak256(bytes(_NAME));
        bytes32 hashedVersion = keccak256(bytes(_VERSION));

        _HASHED_NAME = hashedName;
        _HASHED_VERSION = hashedVersion;
        _CACHED_CHAIN_ID = _chainID();
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(_TYPE_HASH, hashedName, hashedVersion);

        // --- Initial LQTY allocations ---

        communityIssuanceEntitlement = _1_MILLION.mul(400); // Allocate 400 million to the algorithmic issuance schedule
        _mint(_communityIssuanceAddress, communityIssuanceEntitlement);

        _mint(_contributorMiningAddress, _1_MILLION.mul(150)); // Allocate 150 million for contributor mining

        _mint(_idoAddress, _1_MILLION.mul(50)); // Allocate 50 million for IDO

        _mint(_operationalFundAddress, _1_MILLION.mul(170)); // Allocate 170 million for operational fund

        _mint(_investorAddress, _1_MILLION.mul(130)); // Allocate 130 million for investor

        _mint(_teamAddress, _1_MILLION.mul(100)); // Allocate the remainder 100 million to the team
    }

    // --- External functions ---

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function getCurrentVotes(address account) external view override returns (uint256) {
        uint256 stakes = lqtyStaking.totalStakes(account);
        uint256 curLength = checkpoints[account].length;
        if (curLength == 0) {
            return stakes;
        } else {
            return checkpoints[account][curLength - 1].balance.add(stakes);
        }
    }

    function getPriorVotes(address account, uint256 blockNo) external view override returns (uint256) {
        require(blockNo <= block.number, "LQTYToken: invalid blockNo");

        return _balanceOfAt(account, blockNo).add(lqtyStaking.totalStakesAt(account, blockNo));
    }

    function getDeploymentStartTime() external view override returns (uint256) {
        return deploymentStartTime;
    }

    function getCommunityIssuanceEntitlement() external view override returns (uint256) {
        return communityIssuanceEntitlement;
    }

    function getLockupPeriod() external view override returns (uint256) {
        return LOCKUP_PERIOD_IN_SECONDS;
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        // Restrict the multisig's transfers in 90 days
        if (_callerHasLockPeriod() && _isInLockupPeriod()) {
            _requireRecipientIsRegisteredLC(recipient);
        }

        _requireValidRecipient(recipient);

        // Otherwise, standard transfer functionality
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        if (_isInLockupPeriod()) { _requireCallerHasNoLockPeriod(); }

        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        if (_isInLockupPeriod()) { _requireSenderHasNoLockPeriod(sender); }

        _requireValidRecipient(recipient);

        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, _allowances[sender][msg.sender].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external override returns (bool) {
        if (_isInLockupPeriod()) { _requireCallerHasNoLockPeriod(); }

        _approve(msg.sender, spender, _allowances[msg.sender][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external override returns (bool) {
        if (_isInLockupPeriod()) { _requireCallerHasNoLockPeriod(); }

        _approve(msg.sender, spender, _allowances[msg.sender][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function sendToLQTYStaking(address _sender, uint256 _amount) external override {
        _requireCallerIsLQTYStaking();
        if (_isInLockupPeriod()) { _requireSenderHasNoLockPeriod(_sender); }  // Prevent the team & investor from staking LQTY
        _transfer(_sender, address(lqtyStaking), _amount);
    }

    // --- EIP 2612 functionality ---

    function domainSeparator() public view override returns (bytes32) {
        if (_chainID() == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        } else {
            return _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
        }
    }

    function permit
    (
        address owner,
        address spender,
        uint amount,
        uint deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        override
    {
        require(deadline >= now, 'LQTY: expired deadline');
        bytes32 digest = keccak256(abi.encodePacked('\x19\x01',
                         domainSeparator(), keccak256(abi.encode(
                         _PERMIT_TYPEHASH, owner, spender, amount,
                         _nonces[owner]++, deadline))));
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0), "LQTY ECDSA: invalid signature");
        require(recoveredAddress == owner, 'LQTY: invalid signature');
        _approve(owner, spender, amount);
    }

    function nonces(address owner) external view override returns (uint256) { // FOR EIP 2612
        return _nonces[owner];
    }

    // --- Internal operations ---

    function _chainID() private pure returns (uint256 chainID) {
        assembly {
            chainID := chainid()
        }
    }

    function _buildDomainSeparator(bytes32 typeHash, bytes32 name, bytes32 version) private view returns (bytes32) {
        return keccak256(abi.encode(typeHash, name, version, _chainID(), address(this)));
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);

        _updateCheckpoints(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);

        _updateCheckpoints(address(0), account, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _balanceOfAt(address account, uint256 blockNo) internal view returns (uint256) {
        uint256 curLength = checkpoints[account].length;
        if (curLength == 0) {
            return 0;
        }

        // Binary search
        uint256 min = 0;
        uint256 max = curLength - 1;

        if (blockNo < checkpoints[account][min].blockNo) {
            return 0;
        }

        while (min < max) {
            uint256 mid = (min + max + 1) / 2;
            if (checkpoints[account][mid].blockNo <= blockNo) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return checkpoints[account][min].balance;
    }

    function _updateCheckpoints(address from, address to, uint256 amount) internal {
        if (from != to && amount > 0) {
            if (from != address(0)) {
                _updateCheckpoint(from, amount, false);
            }
            if (to != address(0)) {
                _updateCheckpoint(to, amount, true);
            }
        }
    }

    function _updateCheckpoint(address account, uint256 amount, bool increase) internal {
        uint256 curLength = checkpoints[account].length;
        Checkpoint memory checkpoint;
        if (curLength > 0) {
            checkpoint = checkpoints[account][curLength - 1];
        }
        checkpoint.balance = increase
            ? checkpoint.balance.add(amount)
            : checkpoint.balance.sub(amount);
        if (checkpoint.blockNo == block.number) {
            checkpoints[account][curLength - 1] = checkpoint;
        } else {
            checkpoint.blockNo = block.number;
            checkpoints[account].push(checkpoint);
            curLength = curLength + 1;
        }

        emit CheckpointUpdated(account, curLength - 1, checkpoint);
    }

    // --- Helper functions ---

    function _callerHasLockPeriod() internal view returns (bool) {
        return (msg.sender == teamAddress || msg.sender == investorAddress);
    }

    function _isInLockupPeriod() internal view returns (bool) {
        return (block.timestamp.sub(deploymentStartTime) < LOCKUP_PERIOD_IN_SECONDS);
    }

    // --- 'require' functions ---

    function _requireValidRecipient(address _recipient) internal view {
        require(
            _recipient != address(0) &&
            _recipient != address(this),
            "LQTY: Cannot transfer tokens directly to the LQTY token contract or the zero address"
        );
        require(
            _recipient != address(lqtyStaking),
            "LQTY: Cannot transfer tokens directly to the staking contract"
        );
    }

    function _requireRecipientIsRegisteredLC(address _recipient) internal view {
        require(lockupContractFactory.isRegisteredLockup(_recipient),
        "LQTYToken: recipient must be a LockupContract registered in the Factory");
    }

    function _requireSenderHasNoLockPeriod(address _sender) internal view {
        require(_sender != teamAddress && _sender != investorAddress, "LQTYToken: sender must not be the multisig");
    }

    function _requireCallerHasNoLockPeriod() internal view {
        require(!_callerHasLockPeriod(), "LQTYToken: caller must not be the multisig");
    }

    function _requireCallerIsLQTYStaking() internal view {
         require(msg.sender == address(lqtyStaking), "LQTYToken: caller must be the LQTYStaking contract");
    }

    // --- Optional functions ---

    function name() external view override returns (string memory) {
        return _NAME;
    }

    function symbol() external view override returns (string memory) {
        return _SYMBOL;
    }

    function decimals() external view override returns (uint8) {
        return _DECIMALS;
    }

    function version() external view override returns (string memory) {
        return _VERSION;
    }

    function permitTypeHash() external view override returns (bytes32) {
        return _PERMIT_TYPEHASH;
    }
}
