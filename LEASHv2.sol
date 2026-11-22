// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IERC20
 * @notice Minimal ERC-20 interface (https://eips.ethereum.org/EIPS/eip-20).
 */
interface IERC20 {
    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);

    function transfer(address to, uint256 value) external returns (bool);

    function approve(address spender, uint256 value) external returns (bool);

    function transferFrom(address from, address to, uint256 value) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
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
     *         `onlyOwner` functions (including the emergency pause) can no
     *         longer be called.
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
 * @title LeashV2 (DOGE KILLER)
 * @notice Fixed-supply ERC-20 token. This is a v2 of the original LEASH /
 *         UFragments (Ampleforth-style) contract with all rebase mechanics
 *         removed. The entire supply is minted once at deployment and cannot
 *         be minted or burned afterward.
 *
 * @dev Not upgradeable (constructor, no proxy initializer, no storage gaps).
 *      The owner retains an emergency pause over transfers and allowance updates.
 *      Recipients may not be the zero address or this contract.
 */
contract LeashV2 is IERC20, Ownable {
    // -------------------------------------------------------------------------
    // Token metadata. Change these constants to retitle or resize the token.
    // TOTAL_SUPPLY is 107,646 whole tokens with 18 decimals.
    // -------------------------------------------------------------------------
    string public constant name = "DOGE KILLER";
    string public constant symbol = "LEASH";
    uint8 public constant decimals = 18;

    /// @notice Fixed total supply: 107,646 tokens (18 decimals).
    uint256 public constant override totalSupply = 107_646 * 10 ** uint256(decimals);

    /// @notice Emitted when the owner pauses or unpauses ERC-20 operations.
    event LogTokenPaused(bool paused);

    /// @notice When true, transfers and allowance updates revert.
    bool public tokenPaused;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    /**
     * @dev Reverts when ERC-20 operations have been paused by the owner.
     */
    modifier whenTokenNotPaused() {
        require(!tokenPaused, "LeashV2: token paused");
        _;
    }

    /**
     * @dev Reverts if `to` is the zero address or this contract itself.
     */
    modifier validRecipient(address to) {
        require(to != address(0), "LeashV2: transfer to the zero address");
        require(to != address(this), "LeashV2: transfer to the token contract");
        _;
    }

    /**
     * @notice Deploy the token and mint the entire fixed supply to `initialOwner`,
     *         who also becomes the contract owner.
     * @param initialOwner Address that receives the full supply and ownership.
     *        Pass the deployer (`msg.sender`) or a treasury / multisig.
     */
    constructor(address initialOwner) Ownable(initialOwner) {
        _balances[initialOwner] = totalSupply;
        emit Transfer(address(0), initialOwner, totalSupply);
    }

    /**
     * @notice Pause or unpause ERC-20 transfers and allowance updates.
     * @param paused True to pause, false to resume.
     */
    function setTokenPaused(bool paused) external onlyOwner {
        tokenPaused = paused;
        emit LogTokenPaused(paused);
    }

    /**
     * @param account The address to query.
     * @return The token balance of `account`.
     */
    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    /**
     * @notice Transfer `value` tokens to `to`.
     * @param to The recipient. Cannot be the zero address or this contract.
     * @param value The amount to transfer, in the smallest unit (1e-18 tokens).
     * @return True on success.
     */
    function transfer(address to, uint256 value)
        public
        override
        validRecipient(to)
        whenTokenNotPaused
        returns (bool)
    {
        _balances[msg.sender] -= value;
        _balances[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    /**
     * @param tokenOwner The address that owns the tokens.
     * @param spender The address allowed to spend them.
     * @return The remaining allowance of `spender` over `tokenOwner`'s tokens.
     */
    function allowance(address tokenOwner, address spender)
        public
        view
        override
        returns (uint256)
    {
        return _allowances[tokenOwner][spender];
    }

    /**
     * @notice Transfer `value` tokens from `from` to `to` using the caller's allowance.
     * @param from The address to debit.
     * @param to The recipient. Cannot be the zero address or this contract.
     * @param value The amount to transfer, in the smallest unit (1e-18 tokens).
     * @return True on success.
     */
    function transferFrom(address from, address to, uint256 value)
        public
        override
        validRecipient(to)
        whenTokenNotPaused
        returns (bool)
    {
        _allowances[from][msg.sender] -= value;
        _balances[from] -= value;
        _balances[to] += value;
        emit Transfer(from, to, value);
        return true;
    }

    /**
     * @notice Approve `spender` to spend `value` tokens on behalf of the caller.
     * @dev Changing an allowance from a non-zero value with this method carries
     *      the well-known race where a spender may use both the old and the new
     *      allowance. Prefer `increaseAllowance` / `decreaseAllowance`.
     * @param spender The address which will spend the tokens.
     * @param value The amount approved, in the smallest unit (1e-18 tokens).
     * @return True on success.
     */
    function approve(address spender, uint256 value)
        public
        override
        whenTokenNotPaused
        returns (bool)
    {
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /**
     * @notice Increase the allowance granted to `spender` by `addedValue`.
     * @param spender The address which will spend the tokens.
     * @param addedValue The amount to add to the current allowance.
     * @return True on success.
     */
    function increaseAllowance(address spender, uint256 addedValue)
        public
        whenTokenNotPaused
        returns (bool)
    {
        uint256 newAllowance = _allowances[msg.sender][spender] + addedValue;
        _allowances[msg.sender][spender] = newAllowance;
        emit Approval(msg.sender, spender, newAllowance);
        return true;
    }

    /**
     * @notice Decrease the allowance granted to `spender` by `subtractedValue`.
     * @dev If `subtractedValue` is greater than or equal to the current allowance,
     *      the allowance is set to zero rather than reverting. This matches the
     *      original LEASH / UFragments behavior.
     * @param spender The address which will spend the tokens.
     * @param subtractedValue The amount to subtract from the current allowance.
     * @return True on success.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        whenTokenNotPaused
        returns (bool)
    {
        uint256 oldValue = _allowances[msg.sender][spender];
        uint256 newAllowance = subtractedValue >= oldValue ? 0 : oldValue - subtractedValue;
        _allowances[msg.sender][spender] = newAllowance;
        emit Approval(msg.sender, spender, newAllowance);
        return true;
    }
}

