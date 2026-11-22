LEASH v2 (DOGE KILLER) + LeashMigrator

A fixed-supply replacement for legacy LEASH v1, plus a one-way migration contract that burns v1 and pays out v2 at a live, floating ratio.
Looking for the ownerless, two-way option that keeps v1 locked instead of burning it? See README-WrappedLeash.md.

Why
LEASH v1 (0x27C70Cd1946795B66be9d954418546998b546634 on Ethereum) is an Ampleforth-style rebasing token (UFragments, Solidity 0.4.24). Repeated rebases have inflated its total supply to roughly 803,760,032,105,055,242.2456 LEASH. That number can still change, because the rebase path is still live.
LEASH v2 gets rid of rebasing entirely. It has a fixed supply of 107,646 tokens, and the migrator lets every v1 holder swap their share of v1 for the same share of v2.

Contracts
File	Contract	Purpose
LeashV2.sol	LeashV2	Fixed-supply ERC-20, "DOGE KILLER" / LEASH, 18 decimals
LeashMigrator.sol	LeashMigrator	Burns v1 to 0x…dEaD and pays v2 at the live ratio

Both target Solidity ^0.8.20 (built and tested with solc 0.8.38), are self-contained (no imports), and are not upgradeable (no proxy).

LeashV2
    • Supply: 107_646 * 10**18, all minted once in the constructor to initialOwner. There is no mint and no burn.
    • No rebase: your balance changes only when you transfer.
    • Owner powers: an emergency setTokenPaused(bool) that halts transfer, transferFrom, approve, and the allowance helpers. That's the only power. Ownership can be transferred or renounced with renounceOwnership(), and once it's renounced the pause can never be used again.
    • Recipient checks: you can't send to address(0) or to the token contract itself.
    • Allowances: approve, increaseAllowance, and decreaseAllowance. Like v1, decreaseAllowance floors at zero instead of reverting.

LeashMigrator
The ratio (read live on every swap)
v2Out = v1In × v2.totalSupply() ÷ v1.totalSupply()
The entire current v1 supply is always worth the entire v2 supply. Nothing is hardcoded: if v1 is rebased again, the next swap automatically uses the new supply.
    • A rebase up between swaps means less v2 for the same number of v1 units. The holder's share is still the same, because their v1 balance grew too.
    • A rebase down works the other way.
    • The math uses 512-bit mulDiv, so it can't overflow even if v1's supply grows far beyond today's. Any result that rounds down to 0 v2 is rejected.
At today's v1 supply, 100 v1 is worth about 0.0000000000134 v2.
How a swap works
    1. The holder calls v1.approve(migrator, amount).
    2. The holder calls migrate(amount), or migrateAll() to swap their whole balance.
    3. The migrator sends the v1 straight from the holder to 0x000000000000000000000000000000000000dEaD. It never holds v1.
    4. It measures what actually arrived at DEAD (the balance delta), which absorbs v1's internal rounding.
    5. It pays quote(delta) v2 out of its pre-funded balance, and reverts if it's underfunded.
    6. It records the swap and emits Migrated(user, v1In, v2Out, v1TotalSupply, v1Circulating).
On-chain reporting
v1 has no burn function. Sending tokens to DEAD doesn't lower v1.totalSupply(), and the only thing that changes it is a rebase, which scales everyone (including DEAD). So the migrator publishes the figures dashboards and indexers should use instead:
View	Meaning
v1CirculatingSupply()	v1.totalSupply() − v1.balanceOf(DEAD), the effective v1 supply
totalV1Burned / totalV2Distributed	Running totals through the migrator
v1BurnedOf(addr) / v2ReceivedOf(addr)	Totals for each wallet
quote(v1Amount)	v2 you'd get right now
currentRatio()	(v2.totalSupply(), v1.totalSupply()), the live numerator and denominator
Migrated event	v1 in, v2 out, and v1 total and circulating supply after each swap

Admin controls (owner)
Function	What it can and can't do
setMigrationPaused(bool)	Stops new swaps. It can't move funds.
setMigrationDeadline(ts)	Sets an end date. It must be in the future and can only be extended, never shortened. 0 (the default) means no deadline.
recoverUnclaimedV2(to)	Sends leftover v2 only after a deadline has been set and reached. A pause alone can't be used to drain it.

The owner cannot change the ratio, pull any v1 (the contract never holds it), or take v2 before the deadline.

Deployment
1. Deploy LeashV2(initialOwner)                      // full 107,646 minted to initialOwner
2. Deploy LeashMigrator(v1, address(LeashV2), owner) // v1 = 0x27C70Cd1946795B66be9d954418546998b546634
3. initialOwner transfers the migration allocation of v2 to the migrator
4. (optional) setMigrationDeadline(...)
5. (optional) renounce ownership of LeashV2 to permanently remove its pause
Fund the migrator with the full 107,646 if every v1 holder should be able to migrate. With less funding, swaps start reverting with underfunded once it runs out.

Caveats
    • Burning is one-way. v1 sent to DEAD can't come back. If you want a reversible option, use the wrapper.
    • v1 pause. v1's code has a tokenPaused switch that would block transferFrom. On-chain, v1's owner() is 0x0 (renounced), so nobody can flip it anymore.
    • v1 rebases are still possible. v1's monetary policy (0xEff020b07a292baad7A948897c87F99e4Fe6636B) has its owner renounced, but its market oracle (0x8a920C8565783c3aE4aA236e92A5227c4A3eeDcB) still has an owner (0x01e0C58EebE0e8B8435458B191a9bb049DC5c50b) and a single price provider. The live ratio means a rebase can't make the swap unfair. It only changes the unit counts.
    • Trust in v2's owner. Until LeashV2 ownership is renounced, its owner can pause v2 transfers. The migrator's owner can pause swaps and, after a deadline, recover unclaimed v2.

Tests
Foundry. forge test runs:
Suite	Tests
test/LeashV2.t.sol	5
test/LeashMigrator.t.sol	18 (mock rebasing v1: live ratio, rebases up and down, dust, underfunding, deadline rules, reentrancy)
test/LeashMigrator.realv1.t.sol	4 (against the actual compiled v1 UFragments bytecode, test/fixtures/UFragments.bin)

forge build
forge test -vv
License
MIT
