pragma solidity 0.8.26;

interface IERC20 {
    function transfer(address to, uint256 value) external;
    function balanceOf(address account) external view returns (uint256);
}

contract Poisoner {

    /* 
        This contract is used by bad guys to fund addresses for the address poisoning scam to trick inattentive users to send USDT/USDC to wrong adddresses
        Recreated and exposed by Wintermute

        DESCRIPTION OF HOW THIS SCAM WORKS:
        https://www.blockaid.io/blog/a-deep-dive-into-address-poisoning
    */

    address public owner;

    constructor() {
        owner = msg.sender;
    }

    receive() external payable {}

    function withdrawAll(address[] memory tokens) external {
        require(msg.sender == owner, "You are not the owner");
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = owner.call{value: balance}("");
            require(success, "ETH withdrawal failed");
        }

        for (uint256 i = 0; i < tokens.length;) {
            address token = tokens[i];
            uint256 balance2 = IERC20(token).balanceOf(address(this));
            if (balance2 > 0) {
                IERC20(token).transfer(owner, balance2);
            }
            unchecked {
                i++;
            }
        }
        return;
    }

    function fundPoisoners_4218214916(address[] memory poisonedAddresses, uint256[] memory poisonedAmounts, address[] memory tokens, uint256[] memory gasStipends) external payable {
        require(msg.sender == owner, "You are not the owner");
        for (uint256 i = 0; i < poisonedAddresses.length; i++) {
            if (gasStipends[i] > 0) {
                payable(poisonedAddresses[i]).transfer(gasStipends[i]);
            }
            if (poisonedAmounts[i] > 0) {
                address token = tokens[i];
                IERC20(token).transfer(poisonedAddresses[i], poisonedAmounts[i]);
            }
        }
    }
}