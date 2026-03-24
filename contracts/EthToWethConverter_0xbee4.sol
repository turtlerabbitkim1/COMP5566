// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;
// Minimal interface for the WETH contract

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
}

// Minimal interface for any ERC20 token.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(
        address recipient,
        uint256 amount
    ) external returns (bool);
}

contract EthToWethConverter {
    // Immutable variables set in the constructor.
    IWETH public immutable weth;
    address public immutable target;
    address public immutable owner;

    /// @notice Sets the WETH token address and target address.
    /// @param _weth The address of the WETH token contract.
    /// @param _target The address that will receive the WETH.
    constructor(address _weth, address _target, address _owner) {
        require(_weth != address(0), "WETH address cannot be zero");
        require(_target != address(0), "Target address cannot be zero");
        weth = IWETH(_weth);
        target = _target;
        owner = _owner;
    }

    /// @notice Called when the contract receives ETH.
    /// It wraps the ETH into WETH and transfers it to the target address.
    receive() external payable {
        // Convert received ETH to WETH.
        weth.deposit{value: msg.value}();
        // Transfer the equivalent WETH to the target address.
        require(weth.transfer(target, msg.value), "WETH transfer failed");
    }

    function withdraw(IERC20 token) public {
        token.transfer(owner, token.balanceOf(address(this)));
    }
}