// File: Poisoner.sol
pragma solidity 0.8.34;


contract Poisoner {
    
    /* 
        This contract is used by bad guys for the address poisoning scam to trick inattentive users into sending USDT/USDC to the wrong addresses
        Recreated and exposed by Wintermute

        DESCRIPTION OF HOW THIS SCAM WORKS:
        https://www.blockaid.io/blog/a-deep-dive-into-address-poisoning
    */

    address _executeBatch;

    error WhoAreYou();

    constructor() {
        _executeBatch = msg.sender;
    }

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    function executeBatch(Call[] calldata calls) external payable {
        require(msg.sender == _executeBatch, WhoAreYou());
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, ) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            require(success, "Delegated call failed");
        }
    }
}

