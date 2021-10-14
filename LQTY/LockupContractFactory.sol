// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Dependencies/CheckContract.sol";
import "../Dependencies/SafeMath.sol";
import "../Dependencies/OwnableUpgradeable.sol";
import "../Interfaces/ILockupContractFactory.sol";
import "./LockupContract.sol";
import "../Dependencies/console.sol";

/*
* The LockupContractFactory deploys LockupContracts - its main purpose is to keep a registry of valid deployed 
* LockupContracts. 
* 
* This registry is checked by LQTYToken when the Liquity deployer attempts to transfer LQTY tokens. During the lock up period,
* the Liquity deployer is only allowed to transfer LQTY to valid LockupContracts that have been
* deployed by and recorded in the LockupContractFactory. This ensures the deployer's LQTY can't be traded or staked in the
* lock up period, and can only be sent to a verified LockupContract which unlocks at least after lock up period.
*
* LockupContracts can of course be deployed directly, but only those deployed through and recorded in the LockupContractFactory 
* will be considered "valid" by LQTYToken. This is a convenient way to verify that the target address is a genuine 
* LockupContract.
*/

contract LockupContractFactory is ILockupContractFactory, OwnableUpgradeable, CheckContract {
    using SafeMath for uint;

    // --- Data ---
    string constant public NAME = "LockupContractFactory";

    address public lqtyTokenAddress;
    
    mapping (address => address) public lockupContractToDeployer;

    // --- Events ---

    event LQTYTokenAddressSet(address _lqtyTokenAddress);
    event LockupContractDeployedThroughFactory(address _lockupContractAddress, address _beneficiary, uint _unlockTime, address _deployer);

    // --- Functions ---

    function initialize() public initializer {
        __Ownable_init();
    }

    function setLQTYTokenAddress(address _lqtyTokenAddress) external override onlyOwner {
        require(lqtyTokenAddress == address(0), "address has already been set");

        checkContract(_lqtyTokenAddress);

        lqtyTokenAddress = _lqtyTokenAddress;
        emit LQTYTokenAddressSet(_lqtyTokenAddress);
    }

    function deployLockupContract(address _beneficiary, uint _unlockTime) external override {
        address lqtyTokenAddressCached = lqtyTokenAddress;
        _requireLQTYAddressIsSet(lqtyTokenAddressCached);
        LockupContract lockupContract = new LockupContract(
                                                        lqtyTokenAddressCached,
                                                        _beneficiary, 
                                                        _unlockTime);

        lockupContractToDeployer[address(lockupContract)] = msg.sender;
        emit LockupContractDeployedThroughFactory(address(lockupContract), _beneficiary, _unlockTime, msg.sender);
    }

    function isRegisteredLockup(address _contractAddress) public view override returns (bool) {
        return lockupContractToDeployer[_contractAddress] != address(0);
    }

    // --- 'require'  functions ---
    function _requireLQTYAddressIsSet(address _lqtyTokenAddress) internal pure {
        require(_lqtyTokenAddress != address(0), "LCF: LQTY Address is not set");
    }
}
