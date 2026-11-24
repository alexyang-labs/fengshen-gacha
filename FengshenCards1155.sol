// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title 封神榜 ERC-1155 资产：卡包（唯一 id）+ C/UC/R/SR 角色卡 + 法宝卡
/// @notice 铸造期内全量锁定转让；仅 LAUNCHED 后由游戏合约解锁。DRAW 终局永不解锁。
/// id 分段（游戏合约 FengshenGacha 与本合约共用约定）：
///   免费包 10001..10500 / 付费包 20001..21500（逐包唯一 id，amount=1）
///   C 100000+ / UC 101000+ / R 102000+ / SR 103000+
///   法宝 SR 104000+ / 法宝 SSR 105000+ / 法宝 UR 106000+
contract FengshenCards1155 is ERC1155, ERC2981, Ownable {
    address public game;
    bool public transfersUnlocked;

    /// @notice 版税硬上限 1000 bps（10%）：setDefaultRoyalty 超限直接回滚（2026-11-21 总装补）。
    uint96 public constant MAX_DEFAULT_ROYALTY_BPS = 1000;

    constructor(string memory uri_) ERC1155(uri_) Ownable(msg.sender) {
        // 二级版税 5%（ERC2981，公示口径），收款默认为部署者（项目钱包），owner 可改
        _setDefaultRoyalty(msg.sender, 500);
    }

    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external onlyOwner {
        require(feeNumerator <= MAX_DEFAULT_ROYALTY_BPS, "royalty too high");
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC1155, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
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

    function mint(address to, uint256 id, uint256 amount) external onlyGame {
        _mint(to, id, amount, "");
    }

    function burn(address from, uint256 id, uint256 amount) external onlyGame {
        _burn(from, id, amount);
    }

    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override {
        if (from != address(0) && to != address(0)) {
            require(transfersUnlocked, "transfers locked");
        }
        super._update(from, to, ids, values);
    }
}
