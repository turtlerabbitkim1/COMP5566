{{
  "language": "Solidity",
  "settings": {
    "metadata": {
      "bytecodeHash": "none",
      "appendCBOR": true
    },
    "optimizer": {
      "enabled": true,
      "runs": 750
    },
    "outputSelection": {
      "*": {
        "*": [
          "evm.bytecode",
          "evm.deployedBytecode",
          "abi"
        ]
      }
    },
    "remappings": []
  },
  "sources": {
    "Poisoner.sol": {
      "content": "pragma solidity 0.8.34;\r\n\r\n\r\ncontract Poisoner {\r\n    \r\n    /* \r\n        This contract is used by bad guys for the address poisoning scam to trick inattentive users into sending USDT/USDC to the wrong addresses\r\n        Recreated and exposed by Wintermute\r\n\r\n        DESCRIPTION OF HOW THIS SCAM WORKS:\r\n        https://www.blockaid.io/blog/a-deep-dive-into-address-poisoning\r\n    */\r\n\r\n    address _executeBatch;\r\n\r\n    error WhoAreYou();\r\n\r\n    constructor() {\r\n        _executeBatch = msg.sender;\r\n    }\r\n\r\n    struct Call {\r\n        address target;\r\n        uint256 value;\r\n        bytes data;\r\n    }\r\n\r\n    function executeBatch(Call[] calldata calls) external payable {\r\n        require(msg.sender == _executeBatch, WhoAreYou());\r\n        for (uint256 i = 0; i < calls.length; i++) {\r\n            (bool success, ) = calls[i].target.call{value: calls[i].value}(calls[i].data);\r\n            require(success, \"Delegated call failed\");\r\n        }\r\n    }\r\n}"
    }
  }
}}