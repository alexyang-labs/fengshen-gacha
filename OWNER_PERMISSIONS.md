# Owner permissions — what the contract owner can and cannot do

Owner / treasury address: `0x0ea824abd8c140ed24fc0fffad061ef423d323cf`
(the same project wallet; it is also the treasury).

## The owner CAN

- `startSeason()` — start the minting window. One-shot: it can only succeed once,
  and the window length (3 days) is fixed by the contract.
- `setPlayContract(address)` — point the main contract at the gameplay contract,
  so the tournament share of the reserve can be routed automatically at settlement.
- `injectToTier(tier)` / `injectReserve()` — add the owner's own BNB into the
  buyback pool or the reserve. Money-in only: these functions accept funds, they
  cannot move any funds out.
- Trigger nothing else. Every other state transition is either permissionless
  (`settle()`, `drawWinners()` — anyone can call them once their conditions are met)
  or driven by players themselves (claim, buy, open, redeem, claim prize).

## The owner CANNOT

- Withdraw, transfer out, or redirect any funds held by the contracts. There is no
  owner withdrawal function at all. At settlement the contract itself splits the
  revenue by fixed percentages written in code (buyback 55% / issuer 15% / reserve 30%,
  or the 70% fallback prize pool if launch thresholds are missed).
- Change the pack price (a compile-time constant, 0.002 BNB), the launch thresholds
  (200 paid / 600 total), the free-pack quotas (2/day, 6/season, 500 total), the
  revenue split, or the prize distribution. All are constants or fixed formulas.
- Mint cards or packs outside the public claim/buy functions, pause the game,
  freeze or seize user assets, or alter pack contents after a pack is committed
  (pack randomness is derived from the commit block hash).
- Claim free packs or buy packs from the owner/treasury address — the contract
  explicitly blocks the owner and treasury from participating.
- Touch user balances via any privileged transfer path. Card contracts only allow
  transfers by holders themselves (and stay transfer-locked until the season
  launches, again by contract rule, not by admin action).

## Blacklist scope

The blacklist was fixed once, in the constructor, at deployment time. There is no
function to add or remove entries afterwards — not even for the owner. Its only
effect is participation eligibility: a blacklisted address cannot claim or buy
packs. It cannot move, freeze, or confiscate any assets an address already holds,
and the list is publicly readable on-chain.
