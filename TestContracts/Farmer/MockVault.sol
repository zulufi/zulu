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

// Adapted from: https://github.com/alpaca-finance/bsc-alpaca-contract/blob/main/contracts/6/protocol/Vault.sol

import "../../LPRewards/TestContracts/ERC20Mock.sol";
import "../WETH9.sol";

contract MockVault is ERC20Mock {
    /// @notice Libraries
    using SafeMath for uint256;

    /// @dev Attributes for Vault
    /// token - address of the token to be deposited in this pool
    /// name - name of the ibERC20
    /// symbol - symbol of ibERC20
    /// decimals - decimals of ibERC20, this depends on the decimal of the token
    /// debtToken - just a simple ERC20 token for staking with FairLaunch
    address public token;

    WETH9 public weth;

    uint256 public vaultDebtVal;
    uint256 public lastAccrueTime;
    uint256 public reservePool;

    /// @dev Get token from msg.sender
    modifier transferTokenToVault(uint256 value) {
        if (msg.value != 0) {
            require(token == address(weth), "baseToken is not wNative");
            require(value == msg.value, "value != msg.value");
            weth.deposit{value: msg.value}();
        } else {
            IERC20(token).transferFrom(msg.sender, address(this), value);
        }
        _;
    }

    /// @dev Add more debt to the bank debt pool.
    modifier accrue(uint256 value) {
        if (now > lastAccrueTime) {
            uint256 interest = pendingInterest(value);
            reservePool = reservePool.add(0);
            vaultDebtVal = vaultDebtVal.add(interest);
            lastAccrueTime = now;
        }
        _;
    }

    constructor(
        address _token,
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        WETH9 _weth
    ) public ERC20Mock(_name, _symbol, msg.sender, 0) {
        _setupDecimals(_decimals);

        lastAccrueTime = now;
        token = _token;

        weth = _weth;
    }

    /// @dev Return the pending interest that will be accrued in the next call.
    /// @param value Balance value to subtract off address(this).balance when called from payable functions.
    function pendingInterest(uint256 value) public view returns (uint256) {
        if (now > lastAccrueTime) {
            uint256 timePast = now.sub(lastAccrueTime);
            uint256 ratePerSec = 105e16 / uint256(31536000);
            return ratePerSec.mul(vaultDebtVal).mul(timePast).div(1e18);
        } else {
            return 0;
        }
    }

    /// @dev Return the total token entitled to the token holders. Be careful of unaccrued interests.
    function totalToken() public view returns (uint256) {
        return IERC20(token).balanceOf(address(this)).add(vaultDebtVal).sub(reservePool);
    }

    function unprotectedAddDebt(uint256 debtVal) external {
        vaultDebtVal = vaultDebtVal.add(debtVal);
    }

    /// @dev Add more token to the lending pool. Hope to get some good returns.
    function deposit(uint256 amountToken)
        external
        payable
        transferTokenToVault(amountToken)
        accrue(amountToken)
    {
        _deposit(amountToken);
    }

    function _deposit(uint256 amountToken) internal {
        uint256 total = totalToken().sub(amountToken);
        uint256 share = total == 0 ? amountToken : amountToken.mul(totalSupply()).div(total);
        _mint(msg.sender, share);
        require(totalSupply() > 1e17, "no tiny shares");
    }

    /// @dev Withdraw token from the lending and burning ibToken.
    function withdraw(uint256 share) external accrue(0) {
        uint256 amount = share.mul(totalToken()).div(totalSupply());
        _burn(msg.sender, share);
        _safeUnwrap(msg.sender, amount);
        require(totalSupply() > 1e17, "no tiny shares");
    }

    /// @dev Transfer to "to". Automatically unwrap if BTOKEN is WBNB
    /// @param to The address of the receiver
    /// @param amount The amount to be withdrawn
    function _safeUnwrap(address to, uint256 amount) internal {
        if (token == address(weth)) {
            weth.withdraw(amount);
            (bool success, ) = to.call{value: amount}("");
            assert(success);
        } else {
            IERC20(token).transfer(to, amount);
        }
    }

    /// @dev Fallback function to accept BNB.
    receive() external payable {}
}
