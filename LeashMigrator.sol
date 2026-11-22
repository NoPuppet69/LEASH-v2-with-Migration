// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IERC20Minimal
 * @notice Minimal ERC-20 interface used by the migrator (separate name so it
 *         does not clash with `IERC20` in `LeashV2.sol` when both are compiled
 *         in the same Foundry project).
 */
interface IERC20Minimal {
    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);

    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/**
 * @title Ownable
 * @notice Basic access control with a single owner. The owner can transfer or
 *         renounce ownership. Renouncing leaves the contract without an owner,
 *         after which `onlyOwner` functions can no longer be called.
 */
contract Ownable {
    address private _owner;

    event OwnershipRenounced(address indexed previousOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Sets `initialOwner` as the owner. Reverts if it is the zero address.
     */
    constructor(address initialOwner) {
        require(initialOwner != address(0), "Ownable: owner is the zero address");
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    /**
     * @return The address of the current owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(isOwner(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @return True if `msg.sender` is the owner.
     */
    function isOwner() public view returns (bool) {
        return msg.sender == _owner;
    }

    /**
     * @notice Relinquish ownership. The contract is left without an owner, so
     *         `onlyOwner` functions can no longer be called.
     */
    function renounceOwnership() public onlyOwner {
        emit OwnershipRenounced(_owner);
        _owner = address(0);
    }

    /**
     * @notice Transfer ownership to `newOwner`.
     * @param newOwner The address that will become the new owner. Cannot be the zero address.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

/**
 * @title LeashMigrator
 * @notice One-way swap of v1 LEASH (the 0.4.24 UFragments / Ampleforth-style
 *         rebasing token) for fixed-supply LeashV2. v1 tokens are sent to the
 *         canonical dead address; v2 is paid from this contract's pre-funded
 *         balance at a live ratio of the entire v2 supply to the current v1
 *         `totalSupply()`.
 *
 * @dev Deployment (typical):
 *      1. Deploy `LeashV2` with the project owner as `initialOwner`.
 *      2. Deploy `LeashMigrator(v1, v2, owner)`.
 *      3. Owner transfers the v2 supply (or the portion allocated to the
 *         migration) to this contract.
 *      4. Holders `approve` this contract to spend their v1, then call
 *         `migrate` or `migrateAll`.
 *
 *      Ratio (always read live; never stored):
 *          v2Out = v1In * v2.totalSupply() / v1.totalSupply()
 *      So the whole current v1 supply is worth the whole v2 supply (107,646
 *      tokens, 18 decimals). A live read keeps the swap fair if v1 is rebased
 *      again. v1 was maliciously rebased up and, at the time this contract was
 *      written, `v1.totalSupply()` was
 *      803,760,032,105,055,242.245609937123889209 LEASH
 *      (803760032105055242245609937123889209 in base units). That figure is
 *      documentation only — the contract does not hardcode it.
 *
 *      Overflow / precision:
 *      Payouts use 512-bit `mulDiv` (OpenZeppelin-style) so `v1In * v2Supply`
 *      cannot silently overflow a `uint256`. At the supply above, even a naive
 *      `v1In * 107646e18` with `v1In` equal to the full v1 supply is ~8.66e58,
 *      which already fits in `uint256` (~1.16e77). `mulDiv` keeps that safe if
 *      v1 is rebased higher still. Very small `v1In` values floor to 0 v2 and
 *      are rejected.
 *
 *      "Burning" v1 and why `v1.totalSupply()` cannot drop:
 *      v1 has no burn function. Sending tokens to `DEAD` does not change
 *      `totalSupply()`. The only way v1's official supply changes is `rebase`,
 *      and rebase scales *every* holder (including `DEAD`) proportionally, so
 *      it is not a substitute for a burn. This contract therefore tracks
 *      `totalV1Burned` / `totalV2Distributed` (and per-user amounts) and
 *      exposes `v1CirculatingSupply() = v1.totalSupply() - v1.balanceOf(DEAD)`
 *      as the effective supply indexers and dashboards should use.
 *
 *      If v1 later rebases, `DEAD`'s balance scales with everyone else and the
 *      circulating figure remains consistent. The live ratio also keeps
 *      remaining payouts conserving v2: remaining circulating * v2Supply /
 *      v1.totalSupply() still equals the v2 left for migrants, because `DEAD`
 *      is scaled too.
 *
 *      Caveats:
 *      - The v1 owner can pause v1 (`tokenPaused`), which blocks `transferFrom`
 *        and therefore blocks migrations until v1 is unpaused.
 *      - A rebase *up* between two swaps reduces the v2 paid for the same v1
 *        input; a rebase *down* increases it.
 *      - This contract never holds v1 (it is transferred straight to `DEAD`).
 *        The owner cannot pull v1 or change the ratio. Unclaimed v2 can be
 *        recovered only after a deadline that the owner has set and that has
 *        been reached. Pause stops new migrations but is not by itself enough
 *        to recover v2 (so a pause cannot be used to drain the treasury mid-
 *        migration).
 */
contract LeashMigrator is Ownable {
    /// @notice Canonical burn address. v1 `validRecipient` allows it (it only
    ///         rejects the zero address and the v1 token contract itself).
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice v1 LEASH (UFragments). Immutable; the ratio is not stored.
    IERC20Minimal public immutable v1;

    /// @notice Fixed-supply LeashV2.
    IERC20Minimal public immutable v2;

    /// @notice Snapshot of `v2.totalSupply()` taken at deploy (107,646e18 for
    ///         LeashV2). Used as the numerator of the live conversion. Not an
    ///         exchange-rate cache: the denominator is always `v1.totalSupply()`.
    uint256 public immutable v2TotalSupply;

    /// @notice Cumulative v1 actually received by `DEAD` through this contract.
    uint256 public totalV1Burned;

    /// @notice Cumulative v2 paid out to migrants.
    uint256 public totalV2Distributed;

    /// @notice v1 burned via this contract, per user (actual `DEAD` balance delta).
    mapping(address => uint256) public v1BurnedOf;

    /// @notice v2 received via this contract, per user.
    mapping(address => uint256) public v2ReceivedOf;

    /// @notice When true, `migrate` / `migrateAll` revert.
    bool public migrationPaused;

    /// @notice Unix timestamp after which migration ends. Zero means no deadline.
    uint256 public migrationDeadline;

    bool private _entered;

    event Migrated(
        address indexed user,
        uint256 v1In,
        uint256 v2Out,
        uint256 v1TotalSupply,
        uint256 v1Circulating
    );
    event MigrationPaused(bool paused);
    event MigrationDeadlineSet(uint256 deadline);
    event UnclaimedV2Recovered(address indexed to, uint256 amount);

    modifier nonReentrant() {
        require(!_entered, "LeashMigrator: reentrant");
        _entered = true;
        _;
        _entered = false;
    }

    modifier whenMigrationOpen() {
        require(!migrationPaused, "LeashMigrator: paused");
        require(
            migrationDeadline == 0 || block.timestamp < migrationDeadline,
            "LeashMigrator: migration ended"
        );
        _;
    }

    /**
     * @param v1_ v1 LEASH token.
     * @param v2_ LeashV2 token. Its `totalSupply()` is recorded as the
     *        conversion numerator and must be non-zero.
     * @param initialOwner Admin who can pause and set the recovery deadline.
     */
    constructor(address v1_, address v2_, address initialOwner) Ownable(initialOwner) {
        require(v1_ != address(0) && v2_ != address(0), "LeashMigrator: zero token");
        require(v1_ != v2_, "LeashMigrator: tokens are the same");
        require(v1_ != DEAD && v2_ != DEAD, "LeashMigrator: token is DEAD");

        uint256 v2Supply = IERC20Minimal(v2_).totalSupply();
        require(v2Supply != 0, "LeashMigrator: v2 supply is zero");

        v1 = IERC20Minimal(v1_);
        v2 = IERC20Minimal(v2_);
        v2TotalSupply = v2Supply;
    }

    /**
     * @notice v2 that `v1Amount` of v1 would currently buy, using a live
     *         `v1.totalSupply()` read. Floors to zero for dust inputs.
     * @param v1Amount Amount of v1, in base units (18 decimals).
     * @return v2Out Amount of v2, in base units.
     */
    function quote(uint256 v1Amount) public view returns (uint256 v2Out) {
        uint256 v1Supply = v1.totalSupply();
        require(v1Supply != 0, "LeashMigrator: v1 supply is zero");
        v2Out = _mulDiv(v1Amount, v2TotalSupply, v1Supply);
    }

    /**
     * @notice Current conversion components: `v2Out = v1In * v2Numerator / v1Denominator`.
     *         `v1Denominator` is read live; it is not stored.
     * @return v2Numerator Fixed v2 total supply (immutable).
     * @return v1Denominator Live `v1.totalSupply()`.
     */
    function currentRatio() public view returns (uint256 v2Numerator, uint256 v1Denominator) {
        v2Numerator = v2TotalSupply;
        v1Denominator = v1.totalSupply();
    }

    /**
     * @notice Effective v1 supply not sitting in `DEAD`.
     *         `v1.totalSupply()` itself is unchanged by migrations (see contract NatSpec).
     */
    function v1CirculatingSupply() public view returns (uint256) {
        return v1.totalSupply() - v1.balanceOf(DEAD);
    }

    /**
     * @notice Swap `amount` of v1 for v2. Pulls v1 from the caller to `DEAD`
     *         (the caller must have approved this contract). The payout is
     *         based on the actual increase in `DEAD`'s v1 balance, so v1 gon
     *         rounding cannot over-credit the user.
     * @param amount Requested v1 amount, in base units.
     * @return v2Out v2 paid to the caller.
     */
    function migrate(uint256 amount) public nonReentrant whenMigrationOpen returns (uint256 v2Out) {
        v2Out = _migrate(msg.sender, amount);
    }

    /**
     * @notice Swap the caller's entire v1 balance.
     */
    function migrateAll() external nonReentrant whenMigrationOpen returns (uint256 v2Out) {
        v2Out = _migrate(msg.sender, v1.balanceOf(msg.sender));
    }

    /**
     * @notice Pause or unpause migrations. Does not by itself unlock unclaimed v2.
     */
    function setMigrationPaused(bool paused) external onlyOwner {
        migrationPaused = paused;
        emit MigrationPaused(paused);
    }

    /**
     * @notice Set or extend the migration deadline. `newDeadline` must be in
     *         the future. Once set, the deadline can only be moved later, never
     *         shortened. A zero deadline (the default) means migration stays
     *         open until a deadline is set and then reached.
     */
    function setMigrationDeadline(uint256 newDeadline) external onlyOwner {
        require(newDeadline > block.timestamp, "LeashMigrator: deadline not in the future");
        require(newDeadline >= migrationDeadline, "LeashMigrator: deadline can only be extended");
        migrationDeadline = newDeadline;
        emit MigrationDeadlineSet(newDeadline);
    }

    /**
     * @notice Send leftover v2 to `to` after the migration deadline has passed.
     *         Reverts if no deadline was set or it has not yet been reached.
     *         This is the only v2 recovery path; there is no path to recover v1
     *         because this contract never holds it, and the owner cannot change
     *         the conversion ratio.
     */
    function recoverUnclaimedV2(address to) external onlyOwner {
        require(migrationDeadline != 0, "LeashMigrator: no deadline set");
        require(block.timestamp >= migrationDeadline, "LeashMigrator: deadline not reached");
        require(to != address(0) && to != address(v2), "LeashMigrator: invalid recipient");

        uint256 amount = v2.balanceOf(address(this));
        require(amount != 0, "LeashMigrator: nothing to recover");
        require(v2.transfer(to, amount), "LeashMigrator: v2 transfer failed");
        emit UnclaimedV2Recovered(to, amount);
    }

    /**
     * @dev Pull `amount` of v1 from `user` to `DEAD`, measure the actual
     *      `DEAD` delta, pay `quote(delta)` v2, and record / emit the swap.
     */
    function _migrate(address user, uint256 amount) private returns (uint256 v2Out) {
        require(amount != 0, "LeashMigrator: zero amount");

        uint256 deadBefore = v1.balanceOf(DEAD);
        require(v1.transferFrom(user, DEAD, amount), "LeashMigrator: v1 transfer failed");
        uint256 v1In = v1.balanceOf(DEAD) - deadBefore;
        require(v1In != 0, "LeashMigrator: zero v1 received");

        v2Out = quote(v1In);
        require(v2Out != 0, "LeashMigrator: zero v2 output");
        require(v2.balanceOf(address(this)) >= v2Out, "LeashMigrator: underfunded");
        require(v2.transfer(user, v2Out), "LeashMigrator: v2 transfer failed");

        totalV1Burned += v1In;
        totalV2Distributed += v2Out;
        v1BurnedOf[user] += v1In;
        v2ReceivedOf[user] += v2Out;

        uint256 v1Supply = v1.totalSupply();
        uint256 circulating = v1Supply - v1.balanceOf(DEAD);
        emit Migrated(user, v1In, v2Out, v1Supply, circulating);
    }

    /**
     * @notice `floor(x * y / d)` with 512-bit intermediate precision.
     *         Reverts if `d == 0` or the result does not fit in a `uint256`.
     * @dev Algorithm from OpenZeppelin Contracts `Math.mulDiv` (MIT license):
     *      reconstruct the 512-bit product via CRT, then divide.
     */
    function _mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0 = x * y;
            uint256 prod1;
            assembly {
                let mm := mulmod(x, y, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                require(d != 0, "LeashMigrator: div by zero");
                return prod0 / d;
            }

            require(d > prod1, "LeashMigrator: mulDiv overflow");

            uint256 remainder;
            assembly {
                remainder := mulmod(x, y, d)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = d & (0 - d);
            assembly {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }

            prod0 |= prod1 * twos;

            uint256 inverse = (3 * d) ^ 2;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;

            result = prod0 * inverse;
        }
    }
}
