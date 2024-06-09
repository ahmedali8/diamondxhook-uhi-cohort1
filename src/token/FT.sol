// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract FT is ERC20, Ownable {
    constructor(string memory _name, string memory _symbol, address _mintTo, uint256 _supply)
        Ownable(_msgSender())
        ERC20(_name, _symbol)
    {
        _mint(_mintTo, _supply);
    }

    function burn(address _from, uint256 _amount) external onlyOwner {
        _burn(_from, _amount);
    }
}
