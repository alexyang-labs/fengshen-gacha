// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/// @title 封神榜 ERC-721 资产：SSR/UR/LR 高阶卡（逐张带个体 seed）
/// tier 编码与游戏合约一致：4=SSR / 5=UR / 6=LR
contract FengshenCards721 is ERC721, ERC2981, Ownable {
    address public game;
    bool public transfersUnlocked;
    uint256 public nextTokenId = 1;
    string private _customBaseURI;

    struct Attr {
        uint8 tier;
        uint8 typeIdx;
        uint256 seed;
    }

    mapping(uint256 => Attr) public attrs;

    /// @notice 版税硬上限 1000 bps（10%）：setDefaultRoyalty 超限直接回滚（2026-11-21 总装补）。
    uint96 public constant MAX_DEFAULT_ROYALTY_BPS = 1000;

    constructor(string memory baseURI_) ERC721("Fengshen Legends", "FSL") Ownable(msg.sender) {
        _customBaseURI = baseURI_;
        // 二级版税 5%（ERC2981，公示口径），收款默认为部署者（项目钱包），owner 可改
        _setDefaultRoyalty(msg.sender, 500);
    }

    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external onlyOwner {
        require(feeNumerator <= MAX_DEFAULT_ROYALTY_BPS, "royalty too high");
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _baseURI() internal view override returns (string memory) {
        return _customBaseURI;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        string memory base = _baseURI();
        return bytes(base).length > 0 ? string.concat(base, Strings.toString(tokenId), ".json") : "";
    }

    function setGame(address game_) external onlyOwner {
        require(game == address(0), "game set");
        game = game_;
    }

    function setTransfersUnlocked(bool unlocked) external {
        require(msg.sender == game, "only game");
        transfersUnlocked = unlocked;
    }

    modifier onlyGame() {
        require(msg.sender == game, "only game");
        _;
    }

    function mint(
        address to,
        uint8 tier,
        uint8 typeIdx,
        uint256 seed
    ) external onlyGame returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        attrs[tokenId] = Attr(tier, typeIdx, seed);
        _mint(to, tokenId);
    }

    function burn(uint256 tokenId) external onlyGame {
        _burn(tokenId);
        delete attrs[tokenId];
    }

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            require(transfersUnlocked, "transfers locked");
        }
        return super._update(to, tokenId, auth);
    }
}
