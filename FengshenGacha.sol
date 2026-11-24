// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./FengshenCards1155.sol";
import "./FengshenCards721.sol";

/// @title 封神榜 · Agent ID 抽卡 —— 第一季游戏主合约（BSC, chainId 56）
/// @notice 口径：主案《封神榜抽卡完整方案-1120》定版（2026-11-20）；
///         未过线兜底抽奖按附件《封神榜抽奖型方案-1120》第二、三、七节，
///         唯一口径修正：未领奖金 14 天后滚入二季储备桶（任务定版，覆盖附件「滚入下轮奖池」表述）。
///         回购口径：2026-11-21 定版「每周定价、只涨不跌」（《封神榜完整规则-1121》三之三），
///         替代此前实时浮动公式价；回购期 15 周，期满余池转二季储备。
/// @dev Agent ID 校验：SPACE ID Agent ID 注册表（BSC 主网 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F），
///      只读 balanceOf>0，构造参数传入（本地测试用 MockAgentID 顶替）。切勿与 ERC-8004 注册表混淆。
contract FengshenGacha is Ownable, ReentrancyGuard {
    // ---------- 定版参数（SETUP 写死，无改参函数） ----------
    uint256 public constant MINT_DURATION = 3 days; // 铸造期（用户 2026-11-20 定版，原 7 天作废）
    uint256 public constant PACK_PRICE = 0.002 ether;
    uint256 public constant FREE_DAILY_LIMIT = 2; // 每 ID 每日（定版）
    uint256 public constant FREE_PER_ID_CAP = 6; // 每 ID 每季（定版）
    uint256 public constant FREE_TOTAL_CAP = 500;
    uint256 public constant PAID_PER_ID_CAP = 100;
    uint256 public constant PAID_TOTAL_CAP = 1500;
    uint256 public constant LAUNCH_PAID_MIN = 200; // 开池线：付费包
    uint256 public constant LAUNCH_TOTAL_MIN = 600; // 开池线：总包
    uint256 public constant FABAO_CHANCE = 1200; // 第 5 张替换法宝概率 12%（万分比）
    uint256 public constant CLAIM_WINDOW = 14 days; // 兜底抽奖领奖期

    // 募资分桶（LAUNCHED）：回购 55 / 留成 15 / 储备 30
    // 回购档位分池权重：SR 25 / SSR 35 / UR 22 / LR 18
    // 兜底抽奖（DRAW）：奖池 70 / 平台费 30（2026-11-21 用户改定，原 80/20）；奖项占池 %：40,15,15,6,6,6,3,3,3,3（共 10 名）

    // tier 编码：0=C 1=UC 2=R 3=SR 4=SSR 5=UR 6=LR
    uint8 internal constant TIER_SR = 3;
    uint8 internal constant TIER_SSR = 4;
    uint8 internal constant TIER_UR = 5;
    uint8 internal constant TIER_LR = 6;

    // 1155 id 基址
    uint256 internal constant ID_FREE_PACK = 10000;
    uint256 internal constant ID_PAID_PACK = 20000;
    uint256 internal constant ID_C = 100000;
    uint256 internal constant ID_UC = 101000;
    uint256 internal constant ID_R = 102000;
    uint256 internal constant ID_SR = 103000;
    uint256 internal constant ID_FABAO_SR = 104000;
    uint256 internal constant ID_FABAO_SSR = 105000;
    uint256 internal constant ID_FABAO_UR = 106000;

    // 各档卡种数（名单定档表-1120）：C/UC 共用基层池 45 种
    uint16 internal constant TYPES_C = 45;
    uint16 internal constant TYPES_UC = 45;
    uint16 internal constant TYPES_R = 50;
    uint16 internal constant TYPES_SR = 40;
    uint16 internal constant TYPES_SSR = 24;
    uint16 internal constant TYPES_UR = 12;
    uint16 internal constant TYPES_LR = 5;
    // 法宝卡种数：SR 18 / SSR 12 / UR 10
    uint16 internal constant TYPES_FABAO_SR = 18;
    uint16 internal constant TYPES_FABAO_SSR = 12;
    uint16 internal constant TYPES_FABAO_UR = 10;

    enum Phase {
        SETUP,
        MINTING,
        LAUNCHED,
        DRAW,
        SEASON_END
    }

    Phase public phase;

    IERC721 public immutable agentIdRegistry;
    FengshenCards1155 public immutable cards1155;
    FengshenCards721 public immutable cards721;
    address public immutable treasury;
    uint256 public immutable pityPacks; // 付费保底：累计 N 包必出 SR+（定版 10，部署常量）

    uint256 public mintStart;
    uint256 public mintEnd;

    // ---------- 包与计数 ----------
    struct Pack {
        address buyer;
        uint64 commitBlock;
        bool isPaid;
        bool opened;
        bool sixthFree; // 免费第 6 包标记：保底 1 张 SR
    }

    mapping(uint256 => Pack) public packs; // key = 包的 1155 tokenId
    uint256 public freeTotal;
    uint256 public paidTotal;
    uint256 public paidRevenue;

    mapping(address => uint256) public freeClaimed;
    mapping(address => mapping(uint256 => uint256)) public freeClaimedOnDay;
    mapping(address => uint256) public paidBought;
    mapping(address => uint256) public paidPityCounter; // 连续未出 SR+ 的已开付费包数

    // ---------- LAUNCHED：回购 ----------
    // 档位索引：0=SR 1=SSR 2=UR 3=LR
    uint256[4] public tierPool;
    uint256[4] public tierMinted;
    uint256[4] public tierBurned;
    uint256 public reserveBalance; // 储备桶（锦标赛 60% + 二季储备 40%，账面）
    uint256 public season2Reserve; // 兜底抽奖未领奖金滚入处 + 储备桶二季部分（账面）

    // ---------- LAUNCHED：玩法层（2026-11-21 玩法合约 v1） ----------
    address public playContract; // 玩法合约（FengshenPlay），只设一次
    uint256 public tournamentDue; // 储备桶 60%（锦标赛奖池），settle 时记账
    bool public tournamentRouted; // 锦标赛奖池是否已划给玩法合约
    uint256 public prizePackTotal; // 玩法奖励包计数（包 id 30001+，与免费/付费包段不重叠）
    uint256 internal prizeNonce; // 玩法铸卡随机数 nonce

    // ---------- LAUNCHED：回购 v2（2026-11-21 定版：每周定价、只涨不跌） ----------
    uint256 public launchedAt; // settle 判定 LAUNCHED 时赋值 block.timestamp
    uint256[4] public tierPrice; // 每档当周价（wei），settle 时按公式初始化
    uint256 public priceWeek; // 已更新到的周序号，0 起
    bool public buybackSwept;
    uint256 public constant WEEK = 7 days;
    uint256 public constant REDEEM_SPAN = 105 days; // 15 周

    // ---------- DRAW：兜底抽奖 ----------
    uint256 public prizePool;
    uint256 public drawSeedBlock;
    uint256 public drawTime;
    bool public drawDone;
    uint256[10] public winningPackIds; // 中奖包 tokenId（按名次）
    mapping(uint256 => uint256) public prizeOf; // 包 tokenId -> 奖金 wei
    mapping(uint256 => bool) public prizeClaimed;
    bool public unclaimedSwept;

    // ---------- 防滥用 ----------
    mapping(address => bool) public isBlacklisted;

    // ---------- 事件 ----------
    event SeasonStarted(uint256 mintStart, uint256 mintEnd);
    event FreePackClaimed(address indexed user, uint256 indexed packId, uint256 userFreeCount);
    event PaidPacksBought(address indexed user, uint256 count, uint256 firstPackId);
    event PackOpened(
        address indexed user,
        uint256 indexed packId,
        uint8[5] tiers,
        uint16[5] typeIdxs,
        bool[5] isFabao,
        uint256[5] tokenIds
    );
    event Settled(bool launched, uint256 paidTotal_, uint256 totalPacks, uint256 paidRevenue_);
    event BuybackPoolFunded(uint256 total, uint256 sr, uint256 ssr, uint256 ur, uint256 lr);
    event Redeemed(address indexed user, uint8 tier, uint256 tokenId, uint256 amount, uint256 payout);
    event DrawCompleted(uint256 prizePool_, uint256[10] winningPackIds_);
    event PrizeClaimed(address indexed user, uint256 indexed packId, uint256 amount);
    event UnclaimedSwept(uint256 amount);
    event ReserveInjected(address indexed from, uint256 amount);
    event PriceUpdated(uint8 indexed tierIdx, uint256 indexed week, uint256 newPrice);
    event TierInjected(uint8 indexed tierIdx, uint256 amount);
    event BuybackSwept(uint256 total);
    event PlayContractSet(address indexed playContract);
    event TournamentFunded(address indexed playContract, uint256 amount);

    constructor(
        address agentIdRegistry_,
        address cards1155_,
        address cards721_,
        address treasury_,
        address[] memory blacklist_,
        uint256 pityPacks_
    ) Ownable(msg.sender) {
        require(agentIdRegistry_ != address(0), "registry zero");
        agentIdRegistry = IERC721(agentIdRegistry_);
        cards1155 = FengshenCards1155(cards1155_);
        cards721 = FengshenCards721(cards721_);
        treasury = treasury_ == address(0) ? msg.sender : treasury_;
        pityPacks = pityPacks_ == 0 ? 10 : pityPacks_;
        for (uint256 i = 0; i < blacklist_.length; i++) {
            isBlacklisted[blacklist_[i]] = true;
        }
        phase = Phase.SETUP;
    }

    // ---------- 内部校验 ----------
    function _hasAgentId(address user) internal view returns (bool) {
        return agentIdRegistry.balanceOf(user) > 0;
    }

    function _isBlocked(address user) internal view returns (bool) {
        return isBlacklisted[user] || user == owner() || user == treasury;
    }

    modifier inMinting() {
        require(phase == Phase.MINTING, "not minting");
        require(block.timestamp < mintEnd, "minting over");
        _;
    }

    // ---------- 赛季 ----------
    function startSeason() external onlyOwner {
        require(phase == Phase.SETUP, "already started");
        phase = Phase.MINTING;
        mintStart = block.timestamp;
        mintEnd = block.timestamp + MINT_DURATION;
        emit SeasonStarted(mintStart, mintEnd);
    }

    // ---------- 领/买包 ----------
    function claimFreePack() external inMinting {
        require(_hasAgentId(msg.sender), "no agent id");
        require(freeTotal < FREE_TOTAL_CAP, "free cap");
        require(freeClaimed[msg.sender] < FREE_PER_ID_CAP, "id free cap");
        uint256 dayIdx = (block.timestamp - mintStart) / 1 days;
        require(freeClaimedOnDay[msg.sender][dayIdx] < FREE_DAILY_LIMIT, "daily cap");

        freeClaimedOnDay[msg.sender][dayIdx] += 1;
        freeClaimed[msg.sender] += 1;
        freeTotal += 1;
        uint256 packId = ID_FREE_PACK + freeTotal;
        bool sixth = freeClaimed[msg.sender] == FREE_PER_ID_CAP;
        packs[packId] = Pack(msg.sender, uint64(block.number), false, false, sixth);
        cards1155.mint(msg.sender, packId, 1);
        emit FreePackClaimed(msg.sender, packId, freeClaimed[msg.sender]);
    }

    function buyPaidPacks(uint256 count) external payable inMinting nonReentrant {
        require(count >= 1, "count zero");
        require(!_isBlocked(msg.sender), "blocked");
        require(_hasAgentId(msg.sender), "no agent id");
        require(msg.value == count * PACK_PRICE, "wrong value");
        require(paidBought[msg.sender] + count <= PAID_PER_ID_CAP, "id paid cap");
        require(paidTotal + count <= PAID_TOTAL_CAP, "paid cap");

        uint256 firstPackId = ID_PAID_PACK + paidTotal + 1;
        for (uint256 i = 0; i < count; i++) {
            uint256 packId = ID_PAID_PACK + paidTotal + 1;
            packs[packId] = Pack(msg.sender, uint64(block.number), true, false, false);
            paidTotal += 1;
            cards1155.mint(msg.sender, packId, 1);
        }
        paidBought[msg.sender] += count;
        paidRevenue += msg.value;
        emit PaidPacksBought(msg.sender, count, firstPackId);
    }

    // ---------- 随机数 ----------
    /// @dev 两段式：entropy = blockhash(commitBlock+2)；超过 256 区块失效时按主案回落——取最近区块哈希。
    function _entropy(uint64 commitBlock, uint256 packId, address opener) internal view returns (uint256) {
        uint256 seedBlock = uint256(commitBlock) + 2;
        require(block.number > seedBlock, "seed not ready");
        bytes32 h = blockhash(seedBlock);
        if (h == bytes32(0)) {
            h = blockhash(block.number - 1); // 逾期回落规则（主案公示口径）
        }
        return uint256(keccak256(abi.encodePacked(h, packId, opener)));
    }

    function _rand(uint256 entropy, uint256 nonce) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(entropy, nonce)));
    }

    /// @dev 稀有度 roll（万分比）。免费：C6000 UC2700 R1000 SR250 SSR45 UR5 LR0
    ///      付费：C3800 UC3000 R1900 SR850 SSR350 UR85 LR15
    function _rollTier(uint256 r, bool paid) internal pure returns (uint8) {
        uint256 x = r % 10000;
        if (paid) {
            if (x < 3800) return 0;
            if (x < 6800) return 1;
            if (x < 8700) return 2;
            if (x < 9550) return 3;
            if (x < 9900) return 4;
            if (x < 9985) return 5;
            return 6;
        } else {
            if (x < 6000) return 0;
            if (x < 8700) return 1;
            if (x < 9700) return 2;
            if (x < 9950) return 3;
            if (x < 9995) return 4;
            return 5;
        }
    }

    function _typeCount(uint8 tier) internal pure returns (uint16) {
        if (tier == 0) return TYPES_C;
        if (tier == 1) return TYPES_UC;
        if (tier == 2) return TYPES_R;
        if (tier == 3) return TYPES_SR;
        if (tier == 4) return TYPES_SSR;
        if (tier == 5) return TYPES_UR;
        return TYPES_LR;
    }

    /// @dev 法宝内部分档（定档表口径定版：SR 70% / SSR 25% / UR 5%）。
    ///      档位必须用独立随机数 roll：入参 r 的 r%10000 已被 12% 替换判定占用（必然 <1200），
    ///      若复用它 roll 档位将永远落 SR 档（2026-11-21 部署前审核抓到的 bug，已修）。
    function _rollFabao(uint256 r) internal pure returns (uint8 tier, uint16 typeIdx) {
        uint256 x = _rand(r, 778) % 10000;
        uint256 t = _rand(r, 777) % 10000;
        if (x < 7000) {
            return (TIER_SR, uint16(t % TYPES_FABAO_SR));
        }
        if (x < 9500) {
            return (4, uint16(t % TYPES_FABAO_SSR));
        }
        return (TIER_UR, uint16(t % TYPES_FABAO_UR));
    }

    function _fabaoId(uint8 tier, uint16 typeIdx) internal pure returns (uint256) {
        if (tier == TIER_SR) return ID_FABAO_SR + typeIdx;
        if (tier == 4) return ID_FABAO_SSR + typeIdx;
        return ID_FABAO_UR + typeIdx;
    }

    function _cardId1155(uint8 tier, uint16 typeIdx) internal pure returns (uint256) {
        if (tier == 0) return ID_C + typeIdx;
        if (tier == 1) return ID_UC + typeIdx;
        if (tier == 2) return ID_R + typeIdx;
        return ID_SR + typeIdx;
    }

    // ---------- 开包 ----------
    function openPack(uint256 packId) external nonReentrant {
        require(phase != Phase.SETUP, "not started");
        Pack storage p = packs[packId];
        require(p.buyer != address(0), "no pack");
        require(!p.opened, "opened");
        require(cards1155.balanceOf(msg.sender, packId) == 1, "not holder");
        p.opened = true;

        uint256 entropy = _entropy(p.commitBlock, packId, msg.sender);
        cards1155.burn(msg.sender, packId, 1);

        uint8[5] memory tiers;
        uint16[5] memory typeIdxs;
        bool[5] memory isFabao;
        uint256[5] memory tokenIds;
        bool hasSR = false;
        bool hasSRPlus = false;

        for (uint256 i = 0; i < 5; i++) {
            uint256 r = _rand(entropy, i);
            if (i == 4 && r % 10000 < FABAO_CHANCE) {
                (uint8 ft, uint16 fidx) = _rollFabao(r);
                tiers[i] = ft;
                typeIdxs[i] = fidx;
                isFabao[i] = true;
                tokenIds[i] = _fabaoId(ft, fidx);
                continue;
            }
            uint8 tier = _rollTier(r, p.isPaid);
            uint16 tidx = uint16(_rand(r, 1000 + i) % _typeCount(tier));
            tiers[i] = tier;
            typeIdxs[i] = tidx;
            if (tier == TIER_SR) hasSR = true;
            if (tier >= TIER_SR) hasSRPlus = true;
        }

        // 保底改写第 4 张（index 3，永不被法宝替换的角色位）
        if (p.isPaid) {
            if (!hasSRPlus && paidPityCounter[msg.sender] >= pityPacks - 1) {
                // 在 SR+ 内按相对权重抽：SR 850 / SSR 350 / UR 85 / LR 15
                uint256 x = _rand(entropy, 4242) % 1300;
                uint8 ft = x < 850 ? TIER_SR : x < 1200 ? TIER_SSR : x < 1285 ? TIER_UR : TIER_LR;
                tiers[3] = ft;
                typeIdxs[3] = uint16(_rand(entropy, 4243) % _typeCount(ft));
                isFabao[3] = false;
                hasSRPlus = true;
                if (ft == TIER_SR) hasSR = true;
            }
            paidPityCounter[msg.sender] = hasSRPlus ? 0 : paidPityCounter[msg.sender] + 1;
        } else if (p.sixthFree && !hasSR) {
            tiers[3] = TIER_SR;
            typeIdxs[3] = uint16(_rand(entropy, 4343) % TYPES_SR);
            isFabao[3] = false;
            hasSR = true;
        }

        for (uint256 i = 0; i < 5; i++) {
            if (isFabao[i]) {
                cards1155.mint(msg.sender, tokenIds[i], 1);
            } else if (tiers[i] <= TIER_SR) {
                uint256 cid = _cardId1155(tiers[i], typeIdxs[i]);
                tokenIds[i] = cid;
                cards1155.mint(msg.sender, cid, 1);
                if (tiers[i] == TIER_SR) tierMinted[0] += 1;
            } else {
                uint256 nid = cards721.mint(msg.sender, tiers[i], uint8(typeIdxs[i]), _rand(entropy, 9000 + i));
                tokenIds[i] = nid;
                tierMinted[tiers[i] - 3] += 1; // SSR->1 UR->2 LR->3
            }
        }

        emit PackOpened(msg.sender, packId, tiers, typeIdxs, isFabao, tokenIds);
    }

    // ---------- 结算（任何人可触发，合约判定） ----------
    function settle() external nonReentrant {
        require(phase == Phase.MINTING, "not minting");
        require(block.timestamp >= mintEnd, "too early");
        uint256 totalPacksNow = paidTotal + freeTotal;
        bool launched = paidTotal >= LAUNCH_PAID_MIN && totalPacksNow >= LAUNCH_TOTAL_MIN;
        emit Settled(launched, paidTotal, totalPacksNow, paidRevenue);

        if (launched) {
            phase = Phase.LAUNCHED;
            launchedAt = block.timestamp;
            uint256 buybackTotal = (paidRevenue * 55) / 100;
            uint256 issuerAmt = (paidRevenue * 15) / 100;
            uint256 reserveAmt = paidRevenue - buybackTotal - issuerAmt;
            tierPool[0] = (buybackTotal * 25) / 100;
            tierPool[1] = (buybackTotal * 35) / 100;
            tierPool[2] = (buybackTotal * 22) / 100;
            tierPool[3] = buybackTotal - tierPool[0] - tierPool[1] - tierPool[2];
            // 回购 v2 起始价：每档按同一公式定价（不超封顶），流通为 0 的档价为 0
            for (uint256 i = 0; i < 4; i++) {
                tierPrice[i] = _candidatePrice(uint8(i));
            }
            priceWeek = 0;
            reserveBalance = reserveAmt;
            season2Reserve = (reserveAmt * 40) / 100; // 账面拆分：储备桶 40% 归二季（与锦标赛 60% 同在 reserveBalance 内记账）
            // 储备自动划转（2026-11-21 18:20 定版口径，替代一切 owner 提款/划款设想）：
            // tournamentDue = 储备桶 60%，playContract 已设时当场转给玩法合约，剩余 40%＋余数留作二季储备；
            // 未设时只记账，由 routeTournamentToPlay() 补划。主合约不设任何 owner 提款函数。
            tournamentDue = (reserveAmt * 60) / 100;
            if (playContract != address(0)) {
                tournamentRouted = true;
                reserveBalance -= tournamentDue;
                (bool okFund, ) = playContract.call{value: tournamentDue}("");
                require(okFund, "tournament fund fail");
                emit TournamentFunded(playContract, tournamentDue);
            }
            cards1155.setTransfersUnlocked(true);
            cards721.setTransfersUnlocked(true);
            (bool ok, ) = treasury.call{value: issuerAmt}("");
            require(ok, "issuer pay fail");
            emit BuybackPoolFunded(buybackTotal, tierPool[0], tierPool[1], tierPool[2], tierPool[3]);
        } else {
            phase = Phase.DRAW;
            prizePool = (paidRevenue * 70) / 100;
            uint256 platformFee = paidRevenue - prizePool;
            drawSeedBlock = block.number + 2;
            if (platformFee > 0) {
                (bool ok, ) = treasury.call{value: platformFee}("");
                require(ok, "fee pay fail");
            }
        }
    }

    // ---------- 兜底抽奖 ----------
    function drawWinners() external {
        require(phase == Phase.DRAW, "not draw");
        require(!drawDone, "drawn");
        require(block.number > drawSeedBlock, "seed not ready");
        bytes32 h = blockhash(drawSeedBlock);
        if (h == bytes32(0)) {
            h = blockhash(block.number - 1);
        }
        uint256 entropy = uint256(keccak256(abi.encodePacked(h, "FENGSHEN-DRAW")));
        drawDone = true;
        drawTime = block.timestamp;

        uint256 n = paidTotal < 10 ? paidTotal : 10;
        uint256[10] memory pcts = [uint256(40), 15, 15, 6, 6, 6, 3, 3, 3, 3];
        bool[] memory used = new bool[](paidTotal);
        uint256 nonce = 0;
        for (uint256 rank = 0; rank < n; rank++) {
            uint256 idx;
            do {
                idx = _rand(entropy, nonce++) % paidTotal;
            } while (used[idx]);
            used[idx] = true;
            uint256 packId = ID_PAID_PACK + idx + 1;
            winningPackIds[rank] = packId;
            prizeOf[packId] = (prizePool * pcts[rank]) / 100;
        }
        emit DrawCompleted(prizePool, winningPackIds);
    }

    function claimPrize(uint256 packId) external nonReentrant {
        require(phase == Phase.DRAW && drawDone, "no draw");
        require(block.timestamp <= drawTime + CLAIM_WINDOW, "claim over");
        uint256 amt = prizeOf[packId];
        require(amt > 0, "no prize");
        require(!prizeClaimed[packId], "claimed");
        require(packs[packId].buyer == msg.sender, "not buyer");
        prizeClaimed[packId] = true;
        (bool ok, ) = msg.sender.call{value: amt}("");
        require(ok, "pay fail");
        emit PrizeClaimed(msg.sender, packId, amt);
    }

    /// @notice 14 天未领奖金滚入二季储备桶（任务定版口径）
    function sweepUnclaimed() external {
        require(phase == Phase.DRAW && drawDone, "no draw");
        require(block.timestamp > drawTime + CLAIM_WINDOW, "too early");
        require(!unclaimedSwept, "swept");
        unclaimedSwept = true;
        uint256 sum = 0;
        for (uint256 rank = 0; rank < 10; rank++) {
            uint256 packId = winningPackIds[rank];
            if (packId != 0 && !prizeClaimed[packId]) {
                sum += prizeOf[packId];
                prizeOf[packId] = 0;
            }
        }
        season2Reserve += sum;
        emit UnclaimedSwept(sum);
    }

    // ---------- 回购 v2（LAUNCHED）：每周定价、只涨不跌 ----------
    /// @dev 各档封顶价：SR 0.0003 / SSR 0.0015 / UR 0.006 / LR 0.03 BNB
    function _tierCap(uint8 tierIdx) internal pure returns (uint256) {
        if (tierIdx == 0) return 0.0003 ether;
        if (tierIdx == 1) return 0.0015 ether;
        if (tierIdx == 2) return 0.006 ether;
        return 0.03 ether;
    }

    /// @dev 候选价 = 档位池 ÷ 流通存量 × 0.8，封顶钳制；流通为 0 时为 0。
    ///      流通量推导复用原 buybackPrice 的记账方式：tierMinted - tierBurned。
    function _candidatePrice(uint8 tierIdx) internal view returns (uint256) {
        uint256 supply = tierMinted[tierIdx] - tierBurned[tierIdx];
        if (supply == 0) return 0;
        uint256 p = (tierPool[tierIdx] * 8) / (supply * 10);
        uint256 cap = _tierCap(tierIdx);
        return p > cap ? cap : p;
    }

    /// @dev 周价懒更新：phase==LAUNCHED 且未过回购期时，若已进入新周，
    ///      逐档取候选价，高于存储价才采用（棘轮，只涨不跌），并封顶。
    function _updatePrices() internal {
        if (phase != Phase.LAUNCHED) return;
        if (block.timestamp >= launchedAt + REDEEM_SPAN) return;
        uint256 w = (block.timestamp - launchedAt) / WEEK;
        if (w <= priceWeek) return;
        for (uint256 i = 0; i < 4; i++) {
            uint256 candidate = _candidatePrice(uint8(i));
            if (candidate > tierPrice[i]) {
                tierPrice[i] = candidate;
                emit PriceUpdated(uint8(i), w, candidate);
            }
        }
        priceWeek = w;
    }

    /// @notice 任何人可调：推进周价（与赎回内的懒更新同一逻辑），方便官网/任何人触发。
    function updatePrices() external {
        _updatePrices();
    }

    /// @notice 当周存储价（赎回结算价）。旧实时浮动 buybackPrice 已删除，改由本 view 返回存储价。
    function storedTierPrice(uint8 tierIdx) external view returns (uint256) {
        require(tierIdx <= 3, "tier");
        return tierPrice[tierIdx];
    }

    function redeem1155(uint256 cardId, uint256 amount) external nonReentrant {
        require(phase == Phase.LAUNCHED, "not launched");
        require(block.timestamp < launchedAt + REDEEM_SPAN, "redeem closed");
        require(!_isBlocked(msg.sender), "blocked");
        require(cardId >= ID_SR && cardId < ID_SR + TYPES_SR, "not SR card");
        require(amount >= 1, "amount zero");
        _updatePrices();
        uint256 price = tierPrice[0];
        require(price > 0, "no price");
        uint256 payout = price * amount;
        require(tierPool[0] >= payout, "pool short");
        cards1155.burn(msg.sender, cardId, amount);
        tierBurned[0] += amount;
        tierPool[0] -= payout;
        (bool ok, ) = msg.sender.call{value: payout}("");
        require(ok, "pay fail");
        emit Redeemed(msg.sender, TIER_SR, cardId, amount, payout);
    }

    function redeem721(uint256 tokenId) external nonReentrant {
        require(phase == Phase.LAUNCHED, "not launched");
        require(block.timestamp < launchedAt + REDEEM_SPAN, "redeem closed");
        require(!_isBlocked(msg.sender), "blocked");
        require(cards721.ownerOf(tokenId) == msg.sender, "not owner");
        (uint8 tier, , ) = _attrOf(tokenId);
        require(tier >= TIER_SSR, "not high tier");
        uint256 tierIdx = tier - 3;
        _updatePrices();
        uint256 price = tierPrice[tierIdx];
        require(price > 0, "no price");
        require(tierPool[tierIdx] >= price, "pool short");
        cards721.burn(tokenId);
        tierBurned[tierIdx] += 1;
        tierPool[tierIdx] -= price;
        (bool ok, ) = msg.sender.call{value: price}("");
        require(ok, "pay fail");
        emit Redeemed(msg.sender, tier, tokenId, 1, price);
    }

    /// @notice 注水口（onlyOwner，只进不出）：向指定档位回购池注资，抬高之后算出的公式价。
    function injectToTier(uint8 tierIdx) external payable onlyOwner {
        require(tierIdx <= 3, "tier");
        require(phase == Phase.LAUNCHED, "not launched");
        require(block.timestamp < launchedAt + REDEEM_SPAN, "redeem closed");
        tierPool[tierIdx] += msg.value;
        emit TierInjected(tierIdx, msg.value);
    }

    /// @notice 期满清扫（任何人可调）：回购期满后，四档余池全部转入二季储备记账。
    function sweepBuybackLeftovers() external {
        require(phase == Phase.LAUNCHED, "not launched");
        require(block.timestamp >= launchedAt + REDEEM_SPAN, "too early");
        require(!buybackSwept, "swept");
        buybackSwept = true;
        uint256 total = 0;
        for (uint256 i = 0; i < 4; i++) {
            total += tierPool[i];
            season2Reserve += tierPool[i];
            tierPool[i] = 0;
        }
        emit BuybackSwept(total);
    }

    function _attrOf(uint256 tokenId) internal view returns (uint8 tier, uint8 typeIdx, uint256 seed) {
        return cards721.attrs(tokenId);
    }

    // ---------- owner 权力：仅触发结算（settle 已 permissionless）与注入（只进不出） ----------
    function injectReserve() external payable onlyOwner {
        reserveBalance += msg.value;
        emit ReserveInjected(msg.sender, msg.value);
    }

    // ---------- 玩法层（2026-11-21 v1）：转发与储备自动划转 ----------
    // 卡合约的 mint/burn 是 onlyGame（Game=主合约），玩法合约的一切铸造/烧毁必须经主合约转发。
    modifier onlyPlay() {
        require(msg.sender == playContract, "only play");
        _;
    }

    /// @notice 设玩法合约地址，只能设一次。正常流程在 SETUP/MINTING 设；
    ///      另允许 LAUNCHED 且锦标赛奖池尚未划转时补设——否则 settle 时 playContract 为 0 的
    ///      情形下 routeTournamentToPlay() 永远不可达（settle 后 phase 已是 LAUNCHED）。
    ///      偏离说明见 play-v1-results.md。
    function setPlayContract(address play_) external onlyOwner {
        require(playContract == address(0), "play set");
        require(play_ != address(0), "play zero");
        require(
            phase == Phase.SETUP ||
                phase == Phase.MINTING ||
                (phase == Phase.LAUNCHED && !tournamentRouted),
            "phase"
        );
        playContract = play_;
        emit PlayContractSet(play_);
    }

    function _isValidCardId(uint256 cardId) internal pure returns (bool) {
        if (cardId >= ID_C && cardId < ID_C + TYPES_C) return true;
        if (cardId >= ID_UC && cardId < ID_UC + TYPES_UC) return true;
        if (cardId >= ID_R && cardId < ID_R + TYPES_R) return true;
        if (cardId >= ID_SR && cardId < ID_SR + TYPES_SR) return true;
        if (cardId >= ID_FABAO_SR && cardId < ID_FABAO_SR + TYPES_FABAO_SR) return true;
        if (cardId >= ID_FABAO_SSR && cardId < ID_FABAO_SSR + TYPES_FABAO_SSR) return true;
        if (cardId >= ID_FABAO_UR && cardId < ID_FABAO_UR + TYPES_FABAO_UR) return true;
        return false;
    }

    /// @notice 玩法奖励铸 1155 卡（角色/法宝）。SR 角色卡同步 tierMinted（回购流通口径与开包一致）。
    function prizeMint1155(address to, uint256 cardId, uint256 amount) external onlyPlay {
        require(_isValidCardId(cardId), "bad card id");
        if (cardId >= ID_SR && cardId < ID_SR + TYPES_SR) tierMinted[0] += amount;
        cards1155.mint(to, cardId, amount);
    }

    /// @notice 玩法烧 1155 卡（合成/熔铸材料）。SR 角色卡同步 tierBurned。
    function prizeBurn1155(address from, uint256 cardId, uint256 amount) external onlyPlay {
        require(_isValidCardId(cardId), "bad card id");
        if (cardId >= ID_SR && cardId < ID_SR + TYPES_SR) tierBurned[0] += amount;
        cards1155.burn(from, cardId, amount);
    }

    /// @notice 玩法奖励铸 721 卡（SSR/UR/LR）。typeIdx 与 seed 由主合约按开包同规则派生
    ///      （上一区块哈希 ⊕ 收件地址 ⊕ 档位 ⊕ nonce），档内均匀抽取；同步 tierMinted。
    function prizeMint721(address to, uint8 tierIdx) external onlyPlay returns (uint256 tokenId) {
        require(tierIdx >= TIER_SSR && tierIdx <= TIER_LR, "bad tier");
        uint256 r = uint256(
            keccak256(abi.encodePacked(blockhash(block.number - 1), to, tierIdx, prizeNonce++))
        );
        uint16 typeIdx = uint16(r % _typeCount(tierIdx));
        tokenId = cards721.mint(to, tierIdx, uint8(typeIdx), r);
        tierMinted[tierIdx - 3] += 1;
    }

    /// @notice 玩法烧 721 卡（升星祭品）。同步 tierBurned。
    function prizeBurn721(uint256 tokenId) external onlyPlay {
        (uint8 tier, , ) = _attrOf(tokenId);
        require(tier >= TIER_SSR, "not high tier");
        cards721.burn(tokenId);
        tierBurned[tier - 3] += 1;
    }

    /// @notice 玩法奖励发一个未开的包（Boss 奖励）。复用建包路径：包 id 30001+ 独立段，
    ///      不计入免费/付费每季总量与个人上限；开包走同一 openPack 逻辑（保底计数等照常）。
    function mintPrizePack(address to, bool isPaid) external onlyPlay returns (uint256 packId) {
        packId = 30001 + prizePackTotal;
        prizePackTotal += 1;
        packs[packId] = Pack(to, uint64(block.number), isPaid, false, false);
        cards1155.mint(to, packId, 1);
    }

    /// @notice 补划锦标赛奖池（任何人可调）：settle 时 playContract 未设、只记账未转账时，
    ///      待 playContract 设好后由任何人触发一次；收款地址写死 playContract，不接受任何参数。
    function routeTournamentToPlay() external nonReentrant {
        require(phase == Phase.LAUNCHED, "not launched");
        require(!tournamentRouted, "routed");
        require(playContract != address(0), "no play");
        require(tournamentDue > 0, "no due");
        tournamentRouted = true;
        reserveBalance -= tournamentDue;
        (bool ok, ) = playContract.call{value: tournamentDue}("");
        require(ok, "route fail");
        emit TournamentFunded(playContract, tournamentDue);
    }

    // ---------- 视图 ----------
    function totalPacks() external view returns (uint256) {
        return paidTotal + freeTotal;
    }

    function packInfo(uint256 packId)
        external
        view
        returns (address buyer, uint64 commitBlock, bool isPaid, bool opened, bool sixthFree)
    {
        Pack storage p = packs[packId];
        return (p.buyer, p.commitBlock, p.isPaid, p.opened, p.sixthFree);
    }
}
