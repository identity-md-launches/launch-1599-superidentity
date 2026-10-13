// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title SuperIdentity (SUPER)
/// @notice A fixed-supply ERC-20. The whole supply, 1,000,000,000 SUPER with 18 decimals, is minted
///         once to the deployer in the constructor. There is no owner, no minter, no pause, no
///         blacklist, no fee on transfer and no upgrade path: after construction the contract has
///         no privileged functions at all, so the supply can never grow and nobody but a holder (or
///         a spender the holder approved) can move a holder's balance.
/// @dev Self-contained implementation of EIP-20 with the EIP-2612 `permit` extension, so that
///      holders can approve by signature. It deliberately vendors no library: the bytecode is small,
///      has no linked libraries and contains no DELEGATECALL, CALLCODE or SELFDESTRUCT.
contract SuperIdentityToken {
    // ---------------------------------------------------------------------------------------------
    // Metadata
    // ---------------------------------------------------------------------------------------------

    string public constant name = "SuperIdentity";
    string public constant symbol = "SUPER";
    uint8 public constant decimals = 18;

    /// @notice The total supply, fixed forever at construction: 1,000,000,000 * 10^18 minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    /// @notice The sender's balance is smaller than the amount being transferred.
    error InsufficientBalance(address sender, uint256 balance, uint256 needed);
    /// @notice The spender's allowance from `owner` is smaller than the amount being spent.
    error InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    /// @notice Transfers to and approvals of the zero address are refused.
    error InvalidReceiver(address receiver);
    /// @notice Transfers from and approvals from the zero address are refused.
    error InvalidSender(address sender);
    /// @notice The permit's deadline has passed.
    error PermitExpired(uint256 deadline, uint256 blockTimestamp);
    /// @notice The permit's signature does not recover to the owner.
    error InvalidSignature(address recovered, address owner);

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;
    /// @notice EIP-2612 nonces, consumed one per successful `permit`.
    mapping(address owner => uint256) public nonces;

    // ---------------------------------------------------------------------------------------------
    // EIP-712 / EIP-2612
    // ---------------------------------------------------------------------------------------------

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant NAME_HASH = keccak256(bytes("SuperIdentity"));
    bytes32 private constant VERSION_HASH = keccak256(bytes("1"));

    uint256 private immutable _initialChainId;
    bytes32 private immutable _initialDomainSeparator;

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    /// @notice Mints the whole fixed supply to the deployer (`msg.sender`), once.
    /// @dev Takes no arguments and calls no other contract, so it deploys on an empty chain. On the
    ///      IdentityMD launch the deployer is the ProjectFactory, which then pays the supply out.
    constructor() {
        _initialChainId = block.chainid;
        _initialDomainSeparator = _computeDomainSeparator();

        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-20
    // ---------------------------------------------------------------------------------------------

    /// @notice The total supply. Constant: nothing mints after construction and nothing burns.
    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @notice Moves `amount` from the caller to `to`.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to exactly `amount`.
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Moves `amount` from `from` to `to` using the caller's allowance from `from`.
    /// @dev An allowance of `type(uint256).max` is treated as infinite and is not decremented.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // EIP-2612
    // ---------------------------------------------------------------------------------------------

    /// @notice The EIP-712 domain separator, recomputed if the chain id changes (a fork).
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _initialChainId ? _initialDomainSeparator : _computeDomainSeparator();
    }

    /// @notice Sets `owner`'s allowance for `spender` to `value` from a signature by `owner`.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        if (block.timestamp > deadline) revert PermitExpired(deadline, block.timestamp);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));

        // Reject malleable high-s signatures so each permit has exactly one valid encoding.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidSignature(address(0), owner);
        }
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != owner) revert InvalidSignature(recovered, owner);

        _approve(owner, spender, value);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0)) revert InvalidSender(address(0));
        if (to == address(0)) revert InvalidReceiver(address(0));

        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            // Cannot underflow: checked above. Cannot overflow: the sum of all balances is TOTAL_SUPPLY.
            balanceOf[from] = fromBalance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        if (owner == address(0)) revert InvalidSender(address(0));
        if (spender == address(0)) revert InvalidReceiver(address(0));
        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 current = allowance[owner][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert InsufficientAllowance(spender, current, amount);
        unchecked {
            allowance[owner][spender] = current - amount;
        }
        emit Approval(owner, spender, current - amount);
    }

    function _computeDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }
}
