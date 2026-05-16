// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
     
        return 6; // 6 decimals for USDT
    }

    function mint(address to, uint256 amount) external {
        return _mint(to, amount);
    }

}