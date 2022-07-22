// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract USDT is ERC20 {
    constructor() ERC20("USD token", "USDT") {
        _mint(msg.sender, 1000000000 * 10 ** decimals());
    }

    function decimals() override public pure returns (uint8) {
        return 6;
    }
}