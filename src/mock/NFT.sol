// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * Custom errors for the contract
 */
error Unauthorized(address caller);
error TokenDoesNotExist(uint256 tokenId);

contract NFT is Ownable, ERC721URIStorage, ReentrancyGuard {
    uint256 private _tokenIdCounter = 1;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    constructor(string memory _name, string memory _symbol, address _initialOwner)
        ERC721(_name, _symbol)
        Ownable(_initialOwner)
    {}

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function mint(address to, string memory uri) public onlyOwner returns (uint256) {
        uint256 _newItemId = _tokenIdCounter;
        ++_tokenIdCounter;

        _mint(to, _newItemId);
        _setTokenURI(_newItemId, uri);

        return _newItemId;
    }

    function burn(uint256 tokenId) public onlyOwner {
        _burn(tokenId);
    }
}
