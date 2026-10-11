# STUDENT-QUESTIONS.md — Discussion questions (submit with your repo)

Answer directly under each question. 150–300 words each — **reasoning over length**.

---

## A. Permission design

**A1.** The vault holds `MINTER_ROLE`, so it can `burn` any user's balance. Explain why that is a risk, then write out how you would change `Vault` and `SimpleStablecoin` to remove it.

> Your answer:
The vault can destroy any user's sUSD without their consent. That is a risk, a bug or a compromised vault key would let someone burn balances while the collateral stays locked in the vault. The victim loses the coin and cannot redeem (test_Ex4_VaultHoldsTheKey_CanBurnAnyonesBalance shows collateral > supply afterwards).
Increase permission restrictions, separate "who may mint" from "who may burn". In SimpleStablecoin keep mint() under MINTER_ROLE, but replace burn(address,uint256) with OpenZeppelin's ERC20Burnable: burn(amount) burns only the caller's own coins, and burnFrom(account, amount) works only after the account has approved the caller (it spends the allowance). In Vault.redeem() the user first approves the vault, then the vault calls stable.burnFrom(msg.sender, amount). Now the vault can burn only what a user explicitly allowed. Trade-off: redeem needs one extra approve transaction.

<br><br><br>

**A2.** In this contract `DEFAULT_ADMIN_ROLE`, `MINTER_ROLE` and `PAUSER_ROLE` all go to the same address. How would you split them in production, and who holds each?

> Your answer: 
Split them by risk. DEFAULT_ADMIN_ROLE (grants and revokes roles) goes to a multisig (e.g. a 3-of-5 Safe) behind a 24–48 hour timelock, so any role change is public before it takes effect; it is used rarely. MINTER_ROLE goes only to the Vault contract and to no human, so new coins can only appear through the collateral-backed deposit path; the deployer must renounce its own MINTER_ROLE after setup. PAUSER_ROLE goes to a small operations/guardian multisig that can react within minutes. Pausing needs no timelock because it is an emergency brake, and it is safe to delegate because it can only stop the system, not create coins or move funds. Principles: least privilege, separation of duties, and no single key able to both create money and change who is allowed to.
<br><br><br>

---

## B. Pausing and redemption

**B1.** `_update` is the single entry point for every balance change, so `pause()` freezes transfers, minting and redemption together. If you wanted "pause transfers but **allow redemption**", how would you change it? Give the approach — full code not required.

> Your answer:
Right now whenNotPaused sits inside _update, and every balance change (transfer, mint and burn) goes through it, so redeem, which burns, is frozen too. To pause transfers but keep redemption working, I would remove whenNotPaused from _update and check the kind of movement instead. In OpenZeppelin v5 a mint has from == address(0) and a burn has to == address(0). So inside _update: if paused() and from != address(0) and to != address(0), revert EnforcedPause(). Only ordinary transfers are blocked; burns pass, so redeem() still works. Because minting is no longer blocked by _update, add the whenNotPaused modifier directly to mint() so no new coins appear during a pause. Result: during an incident users can still exit to collateral, but coins cannot circulate. Trade-off: if the incident is a theft, the thief could still redeem, so a real system would combine this with a blacklist or an emergency redeem cap.
<br><br><br>

**B2.** In 2008, when a money-market fund "broke the buck", redemptions were frozen for days. In 2023 USDC depegged to $0.87 after a reserve bank failed, but redemptions were **not** shut. Compare the two responses — what does closing the redemption channel, or leaving it open, do to a stablecoin?

> Your answer:
Both episodes were about whether holders could exit at $1. In 2008 a money-market fund fell below $1 (it "broke the buck") and redemptions were frozen for days. Since nobody could redeem, nobody could be sure of getting $1 back, so a small loss turned into a panic across the whole industry and needed government intervention. In 2023 USDC fell to about $0.87 when part of its reserve was stuck at a failed bank, but redemptions stayed open, so the issuer's promise stayed credible and the price recovered within days once the reserve was secured. The redemption channel is the peg's anchor: while it is open, a coin trading below $1 can be bought and redeemed for $1, and that arbitrage pulls the price back. Closing it removes the anchor, so the price reflects fear rather than the reserve, and a solvency problem becomes a liquidity run. Leaving it open costs the issuer a rush of redemptions, but with real reserves it is what rebuilds trust.
<br><br><br>

---

## C. Depeg analysis

**C1.** Under what conditions does this coin depeg? Distinguish at least two classes of cause, and say how each one shows up in the invariant `totalCollateral() >= totalSupply()`.

> Your answer:
The coin depegs whenever holders can no longer count on exchanging one sUSD for one dollar. There are two different classes of cause. (1) Solvency, not enough collateral: coins were minted without collateral (a stolen or bribed MINTER_ROLE, a vault bug), or the collateral itself lost value or disappeared (the reserve bank fails, the issuer moves the reserve). Here the invariant totalCollateral() >= totalSupply() is directly broken; the extra coins are backed by nothing and are worth less than $1 (Ex3). (2) Liquidity, redemption is blocked: the pause switch is on, redeem() reverts, or the collateral token blacklists the vault. Here the invariant still holds, because every coin is covered, but nobody can cash it in, so it trades below $1 anyway (Ex4.3). They are not the same problem: the first is detected by the invariant, the second is invisible to it, which is why a passing invariant is necessary but not sufficient. A third, quieter source is an accounting error such as the 6-vs-18 decimals trap (Ex2): nothing reverts and the invariant holds, but amounts are wrong by 10^12.
<br><br><br>

**C2.** Suppose an attacker bribes their way to `MINTER_ROLE`, mints 1,000,000 sUSD out of nothing and redeems it all. Describe the flow of funds, and name the step that could have stopped them.

> Your answer:
Flow: (1) the attacker bribes the holder of DEFAULT_ADMIN_ROLE (or of a minter key), who calls grantRole(MINTER_ROLE, attacker). (2) The attacker calls stable.mint(attacker, 1,000,000e6): 1,000,000 sUSD appear while the vault's collateral does not change, so totalSupply >> totalCollateral. (3) The attacker calls vault.redeem(amount): it burns the fake sUSD and sends real USDC out of the vault, up to the vault's whole balance. (4) The vault is empty; honest users still hold sUSD, but it is now backed by nothing, and the last to redeem get nothing. The step that could have stopped it is step 1: no single person should be able to hand out MINTER_ROLE. Keep the admin role in a multisig with a timelock, give MINTER_ROLE only to the Vault, and monitor RoleGranted events. Second lines of defence are an emergency pause by PAUSER_ROLE (it would block the redeem in step 3) and a cap on how much can be minted per day. test_Extra_BriberyAttack_DrainsVault reproduces this flow.
<br><br><br>

---

## D. Toward RWA

**D1.** Right now the collateral is `MockUSDC` and `totalCollateral()` just reads an on-chain balance — simple and reliable. If the collateral were **US Treasuries**, could this invariant still be written that way? What new problems appear?

> Your answer:
: a false report breaks the peg and the chain cannot detect it (Tether's operator paid a US$41M penalty for a false statement about its reserves). (2) Valuation: a bill is worth its market price plus accrued interest, not exactly par, so we need a price, a haircut and a freshness check on the report. (3) Liquidity and timing: redeeming means selling bills, which settle in about a day and only in market hours, while the chain runs 24/7. (4) Legal: who owns the bills, is the custodian bankruptcy-remote, and who is allowed to redeem (KYC).
<br><br><br>

**D2.** If the collateral were **a building**, how would you put it inside this vault? Which off-chain roles or legal structures would you have to introduce?

> Your answer:
A building cannot be deposited into a smart contract; the contract can only hold a token that represents a legal claim on it. I would build a chain of off-chain structures: a legal entity (an SPV) that owns the title; a trustee or custodian holding the deed for token holders; an independent appraiser who values the building at regular intervals; a property manager who collects rent and pays costs; and an auditor and legal opinion confirming that the token is an enforceable claim. The SPV issues a share token (ERC-20 or NFT) with transfer restrictions (a KYC whitelist), because it is a security. The vault accepts that token as collateral, takes its value from an oracle fed by the appraiser, and lends only a conservative fraction (a low loan-to-value, e.g. 50–60%) because a building is illiquid, indivisible and priced by opinion. Liquidation would be a foreclosure and sale taking months, so redemption cannot be instant and the invariant must be written against a haircut valuation.
<br><br><br>

---

## E. Tests (Tier 1 required — this is Ex4)

Turn the red tests green in `test/exercises/01_LoopTasks.t.sol` to cover the scenarios below, and write your test function names here:

| Scenario | Your test function name |
|---|---|
| Minting by a non-minter reverts | |
| Transfers revert while paused | |
| **Redemption** reverts while paused | |
| An attacker cannot burn someone else's balance | |
| ...but the vault holding `MINTER_ROLE` can | |

That last pair is meant to be read together: the guard is written correctly, but the key was handed to the vault. Keep it in mind when you answer A1.

Now write one more scenario you consider **most likely to be attacked**, and say why you picked it:

> Your answer:
The scenario most likely to be attacked is a compromised or bribed DEFAULT_ADMIN_ROLE holder granting MINTER_ROLE to an attacker, who then mints from nothing and redeems against the vault (test_Extra_BriberyAttack_DrainsVault). I picked it because the code guards are correct but all trust sits in one key: the constructor gives all roles to one address, and attacking a person (phishing, bribery, key theft) is far cheaper than finding a bug in audited OpenZeppelin code. It is also the exact path of Ex3, and the vault's redeem() turns the fake coins into real money, so the damage is permanent.
