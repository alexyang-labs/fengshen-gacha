// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IGachaPlay {
    function phase() external view returns (uint8); // 0 SETUP / 1 MINTING / 2 LAUNCHED / 3 DRAW / 4 SEASON_END
    function launchedAt() external view returns (uint256);
    function prizeMint1155(address to, uint256 cardId, uint256 amount) external;
    function prizeMint721(address to, uint8 tierIdx) external returns (uint256);
    function prizeBurn1155(address from, uint256 cardId, uint256 amount) external;
    function prizeBurn721(uint256 tokenId) external;
    function mintPrizePack(address to, bool isPaid) external returns (uint256);
}

interface IERC1155Bal {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface IERC721Attrs {
    function ownerOf(uint256 tokenId) external view returns (address);
    function attrs(uint256 tokenId) external view returns (uint8 tier, uint8 typeIdx, uint256 seed);
}

/// @title 封神榜 · 玩法层合约 v1（对战/Boss、每周锦标赛、合成熔铸、养成升星）
/// @notice 口径：《封神榜完整规则-1121》第六节、《封神榜抽卡完整方案-1120》第八/九节、
///         白皮书第十/十一节；储备桶钱路按 2026-11-21 18:20 改定口径——主合约不设任何 owner
///         提款/划款函数，锦标赛奖金只来自 settle 时主合约自动转入的 BNB。
/// @dev 所有玩法函数 require 主合约 phase==LAUNCHED。铸造/烧毁一律经主合约 onlyPlay 转发
///      （卡合约 mint/burn 的 onlyGame 是主合约）。本合约不部署上链、不设任何 owner 提款函数。
contract FengshenPlay is Ownable, ReentrancyGuard {
    IGachaPlay public immutable gacha;
    IERC1155Bal public immutable cards1155;
    IERC721Attrs public immutable cards721;

    uint256 public constant WEEK = 7 days;
    uint256 public constant DAY = 1 days;

    // 档位基础战力（攻+防中值口径）：C 攻 10–30/防 8–24 → 中值 36；按档倍率放大
    // UC ×1.6≈58 / R ×2.8≈101 / SR ×5=180 / SSR ×10=360 / UR ×20=720 / LR ×40=1440。
    // dev 内无逐类型攻防数据源（主合约与元数据均无），故用档位常量，见 play-v1-results.md。
    // tier 编码与主合约一致：0=C 1=UC 2=R 3=SR 4=SSR 5=UR 6=LR
    // 1155 id 段：C 100000+（45）/ UC 101000+（45）/ R 102000+（50）/ SR 103000+（40）
    // 法宝：SR 104000+（18）/ SSR 105000+（12）/ UR 106000+（10）

    // ---------- 碎片 ----------
    mapping(address => uint256) public shards; // 内部账本，非转让

    // ---------- 养成 ----------
    mapping(uint256 => uint8) public tokenLevel; // 721 tokenId -> 等级，上限 10

    // ---------- 阵营 ----------
    // 阵营编码：0=无阵营 1=阐 2=截 3=商 4=周。克制环：截克阐、阐克商、商克周、周克截。
    // 链上无逐类型阵营数据（定档表无此字段、typeIdx 指派顺序链上未定），故由 owner 按档一次性注入；
    // 未注入的档默认全员无阵营（不享克制加成）。见 play-v1-results.md。
    mapping(uint8 => mapping(uint8 => uint8)) public cardFaction; // tier -> typeIdx -> faction
    mapping(uint8 => bool) public factionInjected;

    // ---------- 721 持有登记 ----------
    // 721 合约无枚举接口；本合约登记它经手铸出的 721，并允许持有者自行登记开包所得 721。
    // powerOf 逐项核对当前 ownerOf（已转出/已烧毁的不计），登记本身不产生战力。
    mapping(address => uint256[]) private _user721;
    mapping(uint256 => address) public registered721Owner;

    // ---------- Boss ----------
    // bossId：0=巡山夜叉（小，门槛 400，每日 3 次，阵营无）/ 1=九龙岛四圣（大，1000，每日 3 次，截）
    //         2=万仙阵主（季终，2200，每日 1 次，截）
    mapping(address => mapping(uint8 => mapping(uint256 => uint8))) public bossAttempts; // 用户 -> boss -> UTC 日 -> 次数
    address public firstKiller; // 季终 Boss 全季首杀
    bool public firstKillPaid;

    // ---------- 锦标赛奖金账本 ----------
    // 奖金唯一来源：settle 时主合约自动转入的 BNB（receive 累计）。首杀格 20%，周榜格 80%。
    uint256 public tournamentReceived;
    uint256 public firstKillPaidTotal;
    uint256 public weekPaidTotal;

    struct Entry {
        address player;
        uint256 score;
    }
    mapping(uint256 => mapping(address => uint256)) public powerAtEntry; // 周 -> 用户 -> 报名时战力
    mapping(uint256 => mapping(address => bool)) public enteredWeek;
    mapping(uint256 => mapping(address => uint256)) public weekScore;
    mapping(uint256 => Entry[4]) public top4;
    mapping(uint256 => bool) public weekSettled;

    // ---------- 合成 ----------
    struct FuseCommit {
        address user;
        uint8 tier;
        uint64 commitBlock;
        bool claimed;
    }
    mapping(uint256 => FuseCommit) public fuseCommits; // 1155 合成
    uint256 public fuseNextId;
    mapping(uint256 => FuseCommit) public fabaoCommits; // 法宝熔铸
    uint256 public fabaoNextId;

    // ---------- 套卡合成 ----------
    // 八大门类 setId：0=阐教 1=截教 2=商 3=周 4=妖族 5=灵兽坐骑 6=散仙 7=神职
    mapping(uint8 => uint256[]) public setTypes;
    mapping(uint8 => bool) public setTypesInjected;
    uint256 public fuseSetCount;
    uint256 public constant FUSE_SET_CAP = 20;

    // ---------- 事件 ----------
    event TournamentReceived(address indexed from, uint256 amount, uint256 totalReceived);
    event TournamentSynced(uint256 totalReceived);
    event ShardsGranted(address indexed user, uint256 amount, uint256 balance);
    event ShardsSpent(address indexed user, uint256 amount, uint256 tokenId);
    event FactionsSet(uint8 indexed tier, uint256 count);
    event CardRegistered(address indexed user, uint256 indexed tokenId);
    event BossCleared(address indexed user, uint8 indexed bossId, uint256 power, uint256 shardsGranted);
    event FinalBossPrize(address indexed user, uint8 tier, uint256 id);
    event FirstKill(address indexed killer);
    event FirstKillPaid(address indexed killer, uint256 amount);
    event WeekEntered(uint256 indexed week, address indexed user, uint256 power);
    event ScoreSubmitted(uint256 indexed week, address indexed user, uint256 score);
    event WeekPrizePaid(uint256 indexed week, uint256 rank, address indexed player, uint256 amount);
    event WeekSettled(uint256 indexed week, uint256 weekPool);
    event LeveledUp(address indexed user, uint256 indexed tokenId, uint8 level);
    event CardBurnedForLevel(address indexed user, uint256 indexed burnedTokenId, uint256 indexed tokenId);
    event FuseCommitted(uint256 indexed fuseId, address indexed user, uint8 tier, uint256[3] cardIds);
    event FuseClaimed(uint256 indexed fuseId, address indexed user, uint8 tier, uint256 id);
    event FabaoCommitted(uint256 indexed fuseId, address indexed user, uint8 tier, uint256[3] cardIds);
    event FabaoClaimed(uint256 indexed fuseId, address indexed user, uint8 tier, uint256 cardId);
    event SetTypesSet(uint8 indexed setId, uint256[] cardIds);
    event SetFused(address indexed user, uint8 indexed setId, uint256 tokenId, uint256 totalFused);

    struct TeamCard {
        bool is721;
        uint256 id; // 1155 为 cardId，721 为 tokenId
    }

    constructor(address gacha_, address cards1155_, address cards721_) Ownable(msg.sender) {
        require(gacha_ != address(0) && cards1155_ != address(0) && cards721_ != address(0), "zero addr");
        gacha = IGachaPlay(gacha_);
        cards1155 = IERC1155Bal(cards1155_);
        cards721 = IERC721Attrs(cards721_);
    }

    modifier onlyLaunched() {
        require(gacha.phase() == 2, "not launched");
        _;
    }

    // ---------- 奖金入账 ----------
    receive() external payable {
        tournamentReceived += msg.value;
        emit TournamentReceived(msg.sender, msg.value, tournamentReceived);
    }

    /// @notice 对账：tournamentReceived = 当前余额 + 已付总额（receive 之外的到账也能由此对平）。
    function syncTournamentFund() external onlyOwner {
        tournamentReceived = address(this).balance + firstKillPaidTotal + weekPaidTotal;
        emit TournamentSynced(tournamentReceived);
    }

    function firstKillBudget() public view returns (uint256) {
        return (tournamentReceived * 20) / 100;
    }

    function weekBudget() public view returns (uint256) {
        return (tournamentReceived * 80) / 100;
    }

    function firstKillRemaining() public view returns (uint256) {
        uint256 b = firstKillBudget();
        return b > firstKillPaidTotal ? b - firstKillPaidTotal : 0;
    }

    function weekRemaining() public view returns (uint256) {
        uint256 b = weekBudget();
        return b > weekPaidTotal ? b - weekPaidTotal : 0;
    }

    // ---------- 碎片 ----------
    function balanceOfShard(address user) external view returns (uint256) {
        return shards[user];
    }

    function _addShards(address user, uint256 amount) internal {
        shards[user] += amount;
        emit ShardsGranted(user, amount, shards[user]);
    }

    // ---------- 阵营注入（每档一次性） ----------
    function setFactions(uint8 tier, uint8[] calldata typeIdxs, uint8[] calldata factions) external onlyOwner {
        require(tier <= 6, "bad tier");
        require(!factionInjected[tier], "faction set");
        require(typeIdxs.length == factions.length && typeIdxs.length > 0, "bad input");
        for (uint256 i = 0; i < typeIdxs.length; i++) {
            require(factions[i] <= 4, "bad faction");
            cardFaction[tier][typeIdxs[i]] = factions[i];
        }
        factionInjected[tier] = true;
        emit FactionsSet(tier, typeIdxs.length);
    }

    // ---------- 721 登记 ----------
    function register721(uint256 tokenId) external {
        require(cards721.ownerOf(tokenId) == msg.sender, "not owner");
        _register721(msg.sender, tokenId);
    }

    function register721Batch(uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(cards721.ownerOf(tokenIds[i]) == msg.sender, "not owner");
            _register721(msg.sender, tokenIds[i]);
        }
    }

    function _register721(address user, uint256 tokenId) internal {
        if (registered721Owner[tokenId] == user) return;
        registered721Owner[tokenId] = user;
        _user721[user].push(tokenId);
        emit CardRegistered(user, tokenId);
    }

    function registered721Of(address user) external view returns (uint256[] memory) {
        return _user721[user];
    }

    // ---------- 战力 ----------
    function _basePower(uint8 tier) internal pure returns (uint256) {
        if (tier == 0) return 36;
        if (tier == 1) return 58;
        if (tier == 2) return 101;
        if (tier == 3) return 180;
        if (tier == 4) return 360;
        if (tier == 5) return 720;
        return 1440;
    }

    function _base1155(uint8 tier) internal pure returns (uint256 base, uint16 count) {
        if (tier == 0) return (100000, 45);
        if (tier == 1) return (101000, 45);
        if (tier == 2) return (102000, 50);
        return (103000, 40);
    }

    /// @notice 持有法宝最高一件的加成：SR +5% / SSR +10% / UR +20%，封顶 +20%，不叠加。
    function fabaoBonusOf(address user) public view returns (uint256) {
        for (uint256 i = 0; i < 10; i++) {
            if (cards1155.balanceOf(user, 106000 + i) > 0) return 20;
        }
        for (uint256 i = 0; i < 12; i++) {
            if (cards1155.balanceOf(user, 105000 + i) > 0) return 10;
        }
        for (uint256 i = 0; i < 18; i++) {
            if (cards1155.balanceOf(user, 104000 + i) > 0) return 5;
        }
        return 0;
    }

    /// @dev 721 个体浮动：seed % 31 → 0..30，对应倍率 85%..115%（±15%）。
    function _seedMultiplier(uint256 seed) internal pure returns (uint256) {
        return 85 + (seed % 31);
    }

    /// @notice 持有总战力：1155 按档位常量 × 持有量；721 按档位常量 × 个体浮动 × 升星倍率；
    ///      最后按持有法宝最高一件加成。法宝卡本身不计基础战力。
    function powerOf(address user) public view returns (uint256) {
        uint256 total = 0;
        for (uint8 t = 0; t <= 3; t++) {
            (uint256 base, uint16 count) = _base1155(t);
            uint256 bp = _basePower(t);
            for (uint16 i = 0; i < count; i++) {
                uint256 bal = cards1155.balanceOf(user, base + i);
                if (bal > 0) total += bal * bp;
            }
        }
        uint256[] storage list = _user721[user];
        for (uint256 i = 0; i < list.length; i++) {
            uint256 tid = list[i];
            try cards721.ownerOf(tid) returns (address o) {
                if (o != user) continue;
            } catch {
                continue;
            }
            (uint8 tier, , uint256 seed) = cards721.attrs(tid);
            uint256 p = (_basePower(tier) * _seedMultiplier(seed)) / 100;
            p = (p * (100 + 8 * uint256(tokenLevel[tid]))) / 100;
            total += p;
        }
        uint256 bonus = fabaoBonusOf(user);
        if (bonus > 0) total = (total * (100 + bonus)) / 100;
        return total;
    }

    function _tierOf1155(uint256 cardId) internal pure returns (uint8 tier, uint8 typeIdx) {
        if (cardId >= 100000 && cardId < 100045) return (0, uint8(cardId - 100000));
        if (cardId >= 101000 && cardId < 101045) return (1, uint8(cardId - 101000));
        if (cardId >= 102000 && cardId < 102050) return (2, uint8(cardId - 102000));
        if (cardId >= 103000 && cardId < 103040) return (3, uint8(cardId - 103000));
        revert("not role card");
    }

    function _tierOfFabao(uint256 cardId) internal pure returns (uint8 tier, uint8 typeIdx) {
        if (cardId >= 104000 && cardId < 104018) return (3, uint8(cardId - 104000));
        if (cardId >= 105000 && cardId < 105012) return (4, uint8(cardId - 105000));
        if (cardId >= 106000 && cardId < 106010) return (5, uint8(cardId - 106000));
        revert("not fabao");
    }

    function _typeCount1155(uint8 tier) internal pure returns (uint16) {
        if (tier == 0) return 45;
        if (tier == 1) return 45;
        if (tier == 2) return 50;
        return 40;
    }

    function _fabaoCount(uint8 tier) internal pure returns (uint16) {
        if (tier == 3) return 18;
        if (tier == 4) return 12;
        return 10;
    }

    function _cardId1155(uint8 tier, uint16 typeIdx) internal pure returns (uint256) {
        if (tier == 0) return 100000 + typeIdx;
        if (tier == 1) return 101000 + typeIdx;
        if (tier == 2) return 102000 + typeIdx;
        return 103000 + typeIdx;
    }

    function _fabaoId(uint8 tier, uint16 typeIdx) internal pure returns (uint256) {
        if (tier == 3) return 104000 + typeIdx;
        if (tier == 4) return 105000 + typeIdx;
        return 106000 + typeIdx;
    }

    function _bossFaction(uint8 bossId) internal pure returns (uint8) {
        if (bossId == 0) return 0; // 巡山夜叉不入环，无克制
        return 2; // 九龙岛四圣、万仙阵主均为截教
    }

    /// @dev 克制环：截克阐、阐克商、商克周、周克截。cardF 克 bossF 时为真。
    function _counters(uint8 cardF, uint8 bossF) internal pure returns (bool) {
        if (cardF == 2 && bossF == 1) return true;
        if (cardF == 1 && bossF == 3) return true;
        if (cardF == 3 && bossF == 4) return true;
        if (cardF == 4 && bossF == 2) return true;
        return false;
    }

    /// @notice 队伍战力（至多 5 张）：逐卡验所有权；克制 Boss 阵营的卡 ×1.25；
    ///      最后按持有法宝最高一件加成（与 powerOf 同口径）。
    function teamPower(address user, TeamCard[] calldata team, uint8 bossId) public view returns (uint256) {
        require(team.length >= 1 && team.length <= 5, "team size");
        require(bossId <= 2, "bad boss");
        uint8 bossF = _bossFaction(bossId);
        uint256 total = 0;
        for (uint256 i = 0; i < team.length; i++) {
            uint256 p;
            uint8 f;
            if (team[i].is721) {
                require(cards721.ownerOf(team[i].id) == user, "not owner 721");
                (uint8 tier, uint8 typeIdx, uint256 seed) = cards721.attrs(team[i].id);
                p = (_basePower(tier) * _seedMultiplier(seed)) / 100;
                p = (p * (100 + 8 * uint256(tokenLevel[team[i].id]))) / 100;
                f = cardFaction[tier][typeIdx];
            } else {
                require(cards1155.balanceOf(user, team[i].id) >= 1, "not owner 1155");
                (uint8 tier, uint8 typeIdx) = _tierOf1155(team[i].id);
                p = _basePower(tier);
                f = cardFaction[tier][typeIdx];
            }
            if (bossF != 0 && f != 0 && _counters(f, bossF)) p = (p * 125) / 100;
            total += p;
        }
        uint256 bonus = fabaoBonusOf(user);
        if (bonus > 0) total = (total * (100 + bonus)) / 100;
        return total;
    }

    // ---------- Boss ----------
    function _bossThreshold(uint8 bossId) internal pure returns (uint256) {
        if (bossId == 0) return 400;
        if (bossId == 1) return 1000;
        return 2200;
    }

    function _bossDailyLimit(uint8 bossId) internal pure returns (uint8) {
        return bossId == 2 ? 1 : 3;
    }

    /// @notice 挑战 Boss。每日次数按成功通关计（失败交易整体回滚，不占次数）。
    ///      小 Boss：碎片×10＋免费包×1；大 Boss：付费包×1＋碎片×30；
    ///      季终 Boss：随机 SR/SSR 卡一张（85/15），另记全季首杀。
    function challengeBoss(uint8 bossId, TeamCard[] calldata team) external onlyLaunched nonReentrant {
        require(bossId <= 2, "bad boss");
        uint256 day = block.timestamp / DAY;
        require(bossAttempts[msg.sender][bossId][day] < _bossDailyLimit(bossId), "daily limit");
        uint256 power = teamPower(msg.sender, team, bossId);
        require(power >= _bossThreshold(bossId), "power too low");
        bossAttempts[msg.sender][bossId][day] += 1;

        if (bossId == 0) {
            _addShards(msg.sender, 10);
            gacha.mintPrizePack(msg.sender, false);
            emit BossCleared(msg.sender, 0, power, 10);
        } else if (bossId == 1) {
            gacha.mintPrizePack(msg.sender, true);
            _addShards(msg.sender, 30);
            emit BossCleared(msg.sender, 1, power, 30);
        } else {
            if (firstKiller == address(0)) {
                firstKiller = msg.sender;
                emit FirstKill(msg.sender);
            }
            uint256 r = uint256(
                keccak256(
                    abi.encodePacked(blockhash(block.number - 1), msg.sender, bossId, block.timestamp)
                )
            );
            if (r % 100 < 85) {
                uint256 typeIdx = uint256(keccak256(abi.encodePacked(r, "sr"))) % 40;
                uint256 cardId = 103000 + typeIdx;
                gacha.prizeMint1155(msg.sender, cardId, 1);
                emit FinalBossPrize(msg.sender, 3, cardId);
            } else {
                uint256 tokenId = gacha.prizeMint721(msg.sender, 4);
                _register721(msg.sender, tokenId);
                emit FinalBossPrize(msg.sender, 4, tokenId);
            }
            emit BossCleared(msg.sender, 2, power, 0);
        }
    }

    /// @notice 首杀奖金（onlyOwner）：amount==0 发首杀格全额，否则发指定额且不得超格余额；只发一次。
    function payFirstKill(uint256 amount) external onlyOwner nonReentrant {
        require(firstKiller != address(0), "no first kill");
        require(!firstKillPaid, "already paid");
        uint256 remaining = firstKillRemaining();
        require(remaining > 0, "no budget");
        uint256 pay = amount == 0 ? remaining : amount;
        require(pay <= remaining, "over budget");
        firstKillPaid = true;
        firstKillPaidTotal += pay;
        (bool ok, ) = firstKiller.call{value: pay}("");
        require(ok, "pay fail");
        emit FirstKillPaid(firstKiller, pay);
    }

    // ---------- 每周锦标赛 ----------
    function currentWeek() public view returns (uint256) {
        uint256 launchedAt = gacha.launchedAt();
        require(launchedAt > 0, "not launched");
        return (block.timestamp - launchedAt) / WEEK;
    }

    function enterWeek() external onlyLaunched {
        uint256 w = currentWeek();
        require(!enteredWeek[w][msg.sender], "entered");
        enteredWeek[w][msg.sender] = true;
        uint256 p = powerOf(msg.sender);
        powerAtEntry[w][msg.sender] = p;
        emit WeekEntered(w, msg.sender, p);
    }

    /// @notice 计权分 = min(报名时战力, 当前战力)；可重复提交刷新（防借卡刷榜口径）。
    function submitScore() external onlyLaunched {
        uint256 w = currentWeek();
        require(enteredWeek[w][msg.sender], "not entered");
        uint256 score = powerAtEntry[w][msg.sender];
        uint256 nowPower = powerOf(msg.sender);
        if (nowPower < score) score = nowPower;
        weekScore[w][msg.sender] = score;
        _updateTop4(w, msg.sender, score);
        emit ScoreSubmitted(w, msg.sender, score);
    }

    function _updateTop4(uint256 w, address player, uint256 score) internal {
        Entry[4] storage top = top4[w];
        for (uint256 i = 0; i < 4; i++) {
            if (top[i].player == player) {
                top[i].score = score;
                _sortTop4(w);
                return;
            }
        }
        for (uint256 i = 0; i < 4; i++) {
            if (top[i].player == address(0)) {
                top[i] = Entry(player, score);
                _sortTop4(w);
                return;
            }
        }
        uint256 lowest = 0;
        for (uint256 i = 1; i < 4; i++) {
            if (top[i].score < top[lowest].score) lowest = i;
        }
        if (score > top[lowest].score) {
            top[lowest] = Entry(player, score);
            _sortTop4(w);
        }
    }

    function _sortTop4(uint256 w) internal {
        Entry[4] storage top = top4[w];
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = i + 1; j < 4; j++) {
                bool swap = false;
                if (top[j].player != address(0) && (top[i].player == address(0) || top[j].score > top[i].score)) {
                    swap = true;
                }
                if (swap) {
                    Entry memory tmp = top[i];
                    top[i] = top[j];
                    top[j] = tmp;
                }
            }
        }
    }

    function getTop4(uint256 week)
        external
        view
        returns (address[4] memory players, uint256[4] memory scores)
    {
        for (uint256 i = 0; i < 4; i++) {
            players[i] = top4[week][i].player;
            scores[i] = top4[week][i].score;
        }
    }

    /// @notice 周结算（onlyOwner，周结束后调）：weekPool 不得超过周榜格剩余；按 top4 的
    ///      50/25/15/10 发 BNB；人少于 4 名按名次截断，未发部分留格（只计实际发出额）。
    function settleWeek(uint256 week, uint256 weekPool) external onlyOwner nonReentrant {
        require(week < currentWeek(), "week not over");
        require(!weekSettled[week], "settled");
        require(weekPool <= weekRemaining(), "over week budget");
        weekSettled[week] = true;
        uint256[4] memory pcts = [uint256(50), 25, 15, 10];
        uint256 paid = 0;
        for (uint256 i = 0; i < 4; i++) {
            address player = top4[week][i].player;
            if (player == address(0)) break;
            uint256 amt = (weekPool * pcts[i]) / 100;
            if (amt > 0) {
                (bool ok, ) = player.call{value: amt}("");
                require(ok, "pay fail");
                paid += amt;
            }
            emit WeekPrizePaid(week, i, player, amt);
        }
        weekPaidTotal += paid;
        emit WeekSettled(week, weekPool);
    }

    // ---------- 养成升星 ----------
    /// @notice 721 升星：等级上限 10，每级攻防 +8%（战力倍率 (100+8×等级)/100）。
    ///      成本二选一：烧同 tier+typeIdx 的另一枚 721，或碎片 50×(当前等级+1)。
    function levelUp721(uint256 tokenId, bool payByShards) external onlyLaunched nonReentrant {
        require(cards721.ownerOf(tokenId) == msg.sender, "not owner");
        uint8 lvl = tokenLevel[tokenId];
        require(lvl < 10, "max level");
        (uint8 tier, uint8 typeIdx, ) = cards721.attrs(tokenId);
        if (payByShards) {
            uint256 cost = 50 * (uint256(lvl) + 1);
            require(shards[msg.sender] >= cost, "not enough shards");
            shards[msg.sender] -= cost;
            emit ShardsSpent(msg.sender, cost, tokenId);
        } else {
            uint256 sacrifice = 0;
            uint256[] storage list = _user721[msg.sender];
            for (uint256 i = 0; i < list.length; i++) {
                uint256 cand = list[i];
                if (cand == tokenId) continue;
                try cards721.ownerOf(cand) returns (address o) {
                    if (o != msg.sender) continue;
                } catch {
                    continue;
                }
                (uint8 t2, uint8 ty2, ) = cards721.attrs(cand);
                if (t2 == tier && ty2 == typeIdx) {
                    sacrifice = cand;
                    break;
                }
            }
            require(sacrifice != 0, "no sacrifice");
            gacha.prizeBurn721(sacrifice);
            emit CardBurnedForLevel(msg.sender, sacrifice, tokenId);
        }
        tokenLevel[tokenId] = lvl + 1;
        emit LeveledUp(msg.sender, tokenId, lvl + 1);
    }

    // ---------- 合成熔铸：两段式 commit/claim（沿用开包结构） ----------
    function _fuseEntropy(uint64 commitBlock, uint256 fuseId, address user) internal view returns (uint256) {
        uint256 seedBlock = uint256(commitBlock) + 2;
        require(block.number > seedBlock, "seed not ready");
        bytes32 h = blockhash(seedBlock);
        if (h == bytes32(0)) {
            h = blockhash(block.number - 1); // 逾期回落（与开包同口径）
        }
        return uint256(keccak256(abi.encodePacked(h, fuseId, user)));
    }

    function _checkBurnAmounts(uint256[3] calldata cardIds) internal view {
        for (uint256 i = 0; i < 3; i++) {
            bool first = true;
            for (uint256 j = 0; j < i; j++) {
                if (cardIds[j] == cardIds[i]) first = false;
            }
            if (!first) continue;
            uint256 cnt = 0;
            for (uint256 j = 0; j < 3; j++) {
                if (cardIds[j] == cardIds[i]) cnt++;
            }
            require(cards1155.balanceOf(msg.sender, cardIds[i]) >= cnt, "insufficient cards");
        }
    }

    /// @notice 1155 合成：三张同档角色卡。commit 烧三张记区块；claim 按 70% 同档随机类型 /
    ///      30% 高一档随机类型。SR 升档出 SSR（721，经 prizeMint721；SSR 为 721，prizeMint1155 发不出），
    ///      其余档经 prizeMint1155。LR 不是 1155 输入，「LR 无高一档」在此无触发情形。
    function fuse1155Commit(uint256[3] calldata cardIds) external onlyLaunched nonReentrant returns (uint256 fuseId) {
        uint8 tier;
        for (uint256 i = 0; i < 3; i++) {
            (uint8 t, ) = _tierOf1155(cardIds[i]);
            if (i == 0) tier = t;
            else require(t == tier, "tier mismatch");
        }
        _checkBurnAmounts(cardIds);
        for (uint256 i = 0; i < 3; i++) {
            gacha.prizeBurn1155(msg.sender, cardIds[i], 1);
        }
        fuseId = fuseNextId++;
        fuseCommits[fuseId] = FuseCommit(msg.sender, tier, uint64(block.number), false);
        emit FuseCommitted(fuseId, msg.sender, tier, cardIds);
    }

    function fuse1155Claim(uint256 fuseId) external nonReentrant {
        FuseCommit storage c = fuseCommits[fuseId];
        require(c.user == msg.sender, "not owner");
        require(!c.claimed, "claimed");
        c.claimed = true;
        uint256 entropy = _fuseEntropy(c.commitBlock, fuseId, msg.sender);
        uint256 r = uint256(keccak256(abi.encodePacked(entropy, "fuse1155")));
        uint8 outTier = c.tier;
        if (r % 100 < 30) outTier = c.tier + 1;
        if (outTier == 4) {
            uint256 tokenId = gacha.prizeMint721(msg.sender, 4);
            _register721(msg.sender, tokenId);
            emit FuseClaimed(fuseId, msg.sender, 4, tokenId);
        } else {
            uint16 typeIdx = uint16(uint256(keccak256(abi.encodePacked(r, "type"))) % _typeCount1155(outTier));
            uint256 cardId = _cardId1155(outTier, typeIdx);
            gacha.prizeMint1155(msg.sender, cardId, 1);
            emit FuseClaimed(fuseId, msg.sender, outTier, cardId);
        }
    }

    // ---------- 套卡合成 ----------
    /// @notice 注入某门类的 SR cardId 列表（每门类一次性）。门类→SR 列表以定档表为准，部署后由 owner 注入。
    function setSetTypes(uint8 setId, uint256[] calldata cardIds) external onlyOwner {
        require(setId < 8, "bad set");
        require(!setTypesInjected[setId], "set");
        require(cardIds.length >= 1, "empty");
        for (uint256 i = 0; i < cardIds.length; i++) {
            (uint8 t, ) = _tierOf1155(cardIds[i]);
            require(t == 3, "must be SR");
        }
        setTypesInjected[setId] = true;
        setTypes[setId] = cardIds;
        emit SetTypesSet(setId, cardIds);
    }

    /// @notice 套卡合成：集齐该门类 SR 各一张烧整套，prizeMint721 出 UR；全季上限 20 张。
    function fuseSet(uint8 setId) external onlyLaunched nonReentrant {
        require(setId < 8, "bad set");
        require(setTypesInjected[setId], "no set");
        require(fuseSetCount < FUSE_SET_CAP, "set cap");
        uint256[] storage list = setTypes[setId];
        for (uint256 i = 0; i < list.length; i++) {
            require(cards1155.balanceOf(msg.sender, list[i]) >= 1, "missing set card");
        }
        for (uint256 i = 0; i < list.length; i++) {
            gacha.prizeBurn1155(msg.sender, list[i], 1);
        }
        fuseSetCount += 1;
        uint256 tokenId = gacha.prizeMint721(msg.sender, 5);
        _register721(msg.sender, tokenId);
        emit SetFused(msg.sender, setId, tokenId, fuseSetCount);
    }

    // ---------- 法宝熔铸 ----------
    /// @notice 法宝熔铸：三张同档法宝。commit 烧三张记区块；claim 必出高一档随机法宝。
    ///      UR 法宝无高一档，commit 即 revert。
    function fuseFabaoCommit(uint256[3] calldata cardIds) external onlyLaunched nonReentrant returns (uint256 fuseId) {
        uint8 tier;
        for (uint256 i = 0; i < 3; i++) {
            (uint8 t, ) = _tierOfFabao(cardIds[i]);
            if (i == 0) {
                tier = t;
                require(tier <= 4, "UR fabao cannot fuse");
            } else {
                require(t == tier, "tier mismatch");
            }
        }
        _checkBurnAmounts(cardIds);
        for (uint256 i = 0; i < 3; i++) {
            gacha.prizeBurn1155(msg.sender, cardIds[i], 1);
        }
        fuseId = fabaoNextId++;
        fabaoCommits[fuseId] = FuseCommit(msg.sender, tier, uint64(block.number), false);
        emit FabaoCommitted(fuseId, msg.sender, tier, cardIds);
    }

    function fuseFabaoClaim(uint256 fuseId) external nonReentrant {
        FuseCommit storage c = fabaoCommits[fuseId];
        require(c.user == msg.sender, "not owner");
        require(!c.claimed, "claimed");
        c.claimed = true;
        uint256 entropy = _fuseEntropy(c.commitBlock, fuseId, msg.sender);
        uint256 r = uint256(keccak256(abi.encodePacked(entropy, "fuseFabao")));
        uint8 outTier = c.tier + 1; // SR(3)->SSR(4)，SSR(4)->UR(5)
        uint16 typeIdx = uint16(uint256(keccak256(abi.encodePacked(r, "type"))) % _fabaoCount(outTier));
        uint256 cardId = _fabaoId(outTier, typeIdx);
        gacha.prizeMint1155(msg.sender, cardId, 1);
        emit FabaoClaimed(fuseId, msg.sender, outTier, cardId);
    }
}
