# Fengshen Gacha （封神榜）

A fully on-chain gacha card game on BNB Smart Chain, gated by **Binance Agent ID**.
Holding an Agent ID is the entry ticket: only Agent ID holders can claim free packs,
which makes Agent ID the access-control layer of the game.

**Live site:** https://www.fengshengacha.dynv6.net/
**Season 1:** opened 2026-11-23 20:00 (UTC+8), minting window 3 days.

## How Agent ID is used

- `FengshenGacha.claimFreePack()` checks `agentIdRegistry.balanceOf(msg.sender) > 0`
  against the official Agent ID registry
  (`0x60b9262456de011f7d15a54cdd8c48baaa8b022f`) before minting a free pack.
- Per-Agent-ID quotas are enforced on-chain: max 2 free packs per day, max 6 per season,
  500 free packs in total. The 6th pack guarantees at least one SR-tier card.
- Paid packs are open to everyone, but the free tier — the game's main onboarding
  funnel — is exclusively for Agent ID holders.

## Contracts (BNB Smart Chain, all source-verified)

| Contract | Address |
|---|---|
| FengshenGacha (main) | `0x26EDA90e551E2Fc0564F6Cc746031a0F26D71968` |
| FengshenCards1155 (packs & regular cards) | `0x6de83f895b5d75f775a5164cda75c02a6b8ff17d` |
| FengshenCards721 (fabao cards) | `0x667bdf38a0188d321acc4156cc15fcc05141cf30` |
| FengshenPlay (gameplay layer) | `0x7baaf0f56604afd646c87e2449e0bf91f97eed2b` |

## Game economics (all enforced by the contract, no admin discretion)

- Paid pack price: 0.002 BNB. Season settlement is permissionless (`settle()`).
- If the launch thresholds are met (≥200 paid packs and ≥600 total packs), revenue is
  split automatically: 55% buyback pool / 15% issuer / 30% reserve (of which 60% funds
  the tournament contract, 40% is kept as season-2 reserve). Card transfers unlock and
  the buyback runs on weekly prices that never decrease.
- If the thresholds are not met, 70% of paid revenue becomes a fallback prize pool,
  drawn among paid participants (10 winners). No funds can be withdrawn by the owner
  in either branch — see [OWNER_PERMISSIONS.md](OWNER_PERMISSIONS.md).

## Risk notice

This is a game. Nothing in this repository or on the project site promises profit or
returns of any kind. Card values, if any, are determined solely by the on-chain
buyback formula and market trading after launch.

## License

MIT
