// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import {FT} from "../token/FT.sol";

contract NFTVault is Ownable, ERC721Holder {
    enum State {
        fractionalized,
        redeemed
    }

    struct VaultInfo {
        address collection;
        uint256 tokenId;
        State state;
        address ft;
    }

    /// @notice Mapping of vault ID to vault information
    mapping(uint256 => VaultInfo) public vaults;
    uint256 public vaultCount;

    /// @notice Emitted when a new NFT vault is created and fractionalized
    event VaultCreated(address indexed collection, uint256 indexed tokenId, address ft, uint256 vaultId);
    event Redeemed(address indexed sender, address indexed collection, uint256 indexed tokenId);

    constructor(address _initialOwner) Ownable(_initialOwner) {}

    /// @notice Function to lock an NFT and create a new vault
    /// @param _collection The ERC721 token address of the NFT
    /// @param _tokenId The uint ID of the token
    /// @param _supply The total supply amount of fractions of the fractionalized NFT
    /// @param _name The desired name of the vault
    /// @param _symbol The desired symbol of the vault
    function createVault(
        address _collection,
        uint256 _tokenId,
        uint256 _supply,
        address _mintTo,
        string memory _name,
        string memory _symbol
    ) external onlyOwner {
        // Transfer the NFT to the contract
        IERC721(_collection).transferFrom(_msgSender(), address(this), _tokenId);

        // Deploy a new ERC20 token contract
        FT _newToken = new FT(_name, _symbol, _mintTo, _supply);

        // Create vault info
        vaultCount++;
        vaults[vaultCount] =
            VaultInfo({collection: _collection, tokenId: _tokenId, state: State.fractionalized, ft: address(_newToken)});

        emit VaultCreated(_collection, _tokenId, address(_newToken), vaultCount);
    }

    /// @notice Function to redeem an NFT by burning the entire supply of its corresponding ERC20 tokens
    /// @param _vaultId The ID of the vault to redeem
    function redeem(uint256 _vaultId) external onlyOwner {
        VaultInfo storage _vault = vaults[_vaultId];
        require(_vault.state == State.fractionalized, "NFT not fractionalized");

        FT token = FT(_vault.ft);

        uint256 redeemerBalance = token.balanceOf(_msgSender());
        require(redeemerBalance == token.totalSupply(), "Redeemer does not hold the entire supply");

        // Burn the tokens and transfer the NFT back to the redeemer
        token.burn(_msgSender(), redeemerBalance);
        IERC721(_vault.collection).safeTransferFrom(address(this), _msgSender(), _vault.tokenId);

        _vault.state = State.redeemed;
        emit Redeemed(_msgSender(), _vault.collection, _vault.tokenId);
    }
}
