// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SuperIdentityToken} from "../src/SuperIdentityToken.sol";

/// @title Handler that drives SuperIdentityToken with random, bounded call sequences.
/// @dev Six actors with known private keys hold the whole supply between them. Every handler
///      function is bounded so that it never reverts unexpectedly: the happy paths update a ghost
///      model of what the token should hold, and the failure paths assert the exact revert and that
///      nothing moved. The invariant suite runs with `fail-on-revert = true`, so a revert the handler
///      did not expect is itself a failure.
contract SuperIdentityHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant ACTOR_COUNT = 6;

    SuperIdentityToken public immutable token;

    address[] public actors;
    mapping(address => uint256) internal keyOf;

    // Ghost model ---------------------------------------------------------------------------------
    mapping(address => uint256) public ghost_initial;
    mapping(address => uint256) public ghost_received;
    mapping(address => uint256) public ghost_sent;
    mapping(address => uint256) public ghost_balance;
    mapping(address => mapping(address => uint256)) public ghost_allowance;
    mapping(address => uint256) public ghost_nonce;
    uint256 public ghost_moved;
    mapping(bytes32 => uint256) public calls;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        token = new SuperIdentityToken();
        require(token.balanceOf(address(this)) == SUPPLY, "handler did not receive the supply");

        // Uneven initial allocation: actor i gets (i+1)/21 of the supply, the last one the remainder.
        uint256 handedOut;
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            uint256 key = 0x5109 + i;
            address actor = vm.addr(key);
            actors.push(actor);
            keyOf[actor] = key;
            uint256 amount = i + 1 == ACTOR_COUNT ? SUPPLY - handedOut : SUPPLY * (i + 1) / 21;
            handedOut += amount;
            require(token.transfer(actor, amount), "seeding transfer returned false");
            ghost_initial[actor] = amount;
            ghost_balance[actor] = amount;
        }
        require(token.balanceOf(address(this)) == 0, "handler kept part of the supply");
    }

    function actorCount() external pure returns (uint256) {
        return ACTOR_COUNT;
    }

    function _pick(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, ACTOR_COUNT - 1)];
    }

    function _pickOther(uint256 seed, address not) internal view returns (address) {
        uint256 i = bound(seed, 0, ACTOR_COUNT - 1);
        if (actors[i] == not) i = (i + 1) % ACTOR_COUNT;
        return actors[i];
    }

    function _count(bytes32 key) internal {
        calls[key]++;
    }

    function _recordMove(address from, address to, uint256 amount) internal {
        ghost_sent[from] += amount;
        ghost_received[to] += amount;
        ghost_balance[from] -= amount;
        ghost_balance[to] += amount;
        ghost_moved += amount;
    }

    function _sign(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(keyOf[owner], digest);
    }

    // ---------------------------------------------------------------------------------------------
    // transfer
    // ---------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        _count("transfer");
        address from = _pick(fromSeed);
        address to = _pick(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(from, to, amount);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");

        _recordMove(from, to, amount);
    }

    /// @dev Moves the whole balance so the zero-remaining edge is hit often, not only by chance.
    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        _count("transferAll");
        address from = _pick(fromSeed);
        address to = _pickOther(toSeed, from);
        uint256 amount = token.balanceOf(from);

        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transferAll returned false");
        assertEq(token.balanceOf(from), 0, "sender kept something after sending everything");

        _recordMove(from, to, amount);
    }

    function selfTransfer(uint256 seed, uint256 amount) external {
        _count("selfTransfer");
        address actor = _pick(seed);
        uint256 before = token.balanceOf(actor);
        amount = bound(amount, 0, before);

        vm.prank(actor);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(actor, actor, amount);
        assertTrue(token.transfer(actor, amount));
        assertEq(token.balanceOf(actor), before, "self-transfer changed the balance");

        _recordMove(actor, actor, amount);
    }

    function transferExceedingBalance(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        _count("transferExceedingBalance");
        address from = _pick(fromSeed);
        address to = _pick(toSeed);
        uint256 held = token.balanceOf(from);
        amount = bound(amount, held + 1, type(uint256).max);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientBalance.selector, from, held, amount));
        token.transfer(to, amount);

        assertEq(token.balanceOf(from), held, "a failed transfer changed the sender's balance");
        assertEq(token.balanceOf(to), toBefore, "a failed transfer changed the receiver's balance");
    }

    function transferToZeroAddress(uint256 fromSeed, uint256 amount) external {
        _count("transferToZeroAddress");
        address from = _pick(fromSeed);
        uint256 held = token.balanceOf(from);
        amount = bound(amount, 0, held);

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);

        assertEq(token.balanceOf(from), held, "a refused transfer changed the sender's balance");
        assertEq(token.balanceOf(address(0)), 0, "the zero address received tokens");
    }

    // ---------------------------------------------------------------------------------------------
    // approve / transferFrom
    // ---------------------------------------------------------------------------------------------

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        _count("approve");
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        if (infinite) amount = type(uint256).max;

        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(owner, spender, amount);
        assertTrue(token.approve(spender, amount), "approve returned false");

        ghost_allowance[owner][spender] = amount;
    }

    function approveZeroAddress(uint256 ownerSeed, uint256 amount) external {
        _count("approveZeroAddress");
        address owner = _pick(ownerSeed);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InvalidReceiver.selector, address(0)));
        token.approve(address(0), amount);
        assertEq(token.allowance(owner, address(0)), 0);
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        _count("transferFrom");
        address spender = _pick(spenderSeed);
        address owner = _pick(ownerSeed);
        address to = _pick(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        uint256 cap = allowed == type(uint256).max ? held : (allowed < held ? allowed : held);
        amount = bound(amount, 0, cap);

        vm.prank(spender);
        if (allowed != type(uint256).max) {
            vm.expectEmit(true, true, true, true, address(token));
            emit Approval(owner, spender, allowed - amount);
        }
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(owner, to, amount);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");

        if (allowed != type(uint256).max) {
            ghost_allowance[owner][spender] = allowed - amount;
            assertEq(token.allowance(owner, spender), allowed - amount, "allowance not decremented by amount");
        } else {
            assertEq(token.allowance(owner, spender), type(uint256).max, "infinite allowance was decremented");
        }
        _recordMove(owner, to, amount);
    }

    function transferFromExceedingAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount)
        external
    {
        _count("transferFromExceedingAllowance");
        address spender = _pick(spenderSeed);
        address owner = _pick(ownerSeed);
        address to = _pick(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) {
            // Pin a finite allowance so that there is something to exceed.
            allowed = bound(amount, 0, SUPPLY);
            vm.prank(owner);
            token.approve(spender, allowed);
            ghost_allowance[owner][spender] = allowed;
        }
        amount = bound(amount, allowed + 1, type(uint256).max);
        uint256 held = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(SuperIdentityToken.InsufficientAllowance.selector, spender, allowed, amount)
        );
        token.transferFrom(owner, to, amount);

        assertEq(token.allowance(owner, spender), allowed, "a failed transferFrom changed the allowance");
        assertEq(token.balanceOf(owner), held, "a failed transferFrom moved the owner's balance");
        assertEq(token.balanceOf(to), toBefore, "a failed transferFrom credited the receiver");
    }

    function transferFromExceedingBalance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount)
        external
    {
        _count("transferFromExceedingBalance");
        address spender = _pick(spenderSeed);
        address owner = _pick(ownerSeed);
        address to = _pick(toSeed);
        uint256 held = token.balanceOf(owner);
        amount = bound(amount, held + 1, type(uint256).max);
        // An infinite allowance does not help a spender past the owner's balance.
        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        ghost_allowance[owner][spender] = type(uint256).max;

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientBalance.selector, owner, held, amount));
        token.transferFrom(owner, to, amount);

        assertEq(token.balanceOf(owner), held);
        assertEq(token.allowance(owner, spender), type(uint256).max);
    }

    function transferFromWithoutApproval(uint256 spenderSeed, uint256 ownerSeed, uint256 amount) external {
        _count("transferFromWithoutApproval");
        address spender = _pick(spenderSeed);
        address owner = _pick(ownerSeed);
        // Revoke, then try to spend: the exact error names the zero allowance.
        vm.prank(owner);
        token.approve(spender, 0);
        ghost_allowance[owner][spender] = 0;
        amount = bound(amount, 1, type(uint256).max);
        uint256 held = token.balanceOf(owner);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientAllowance.selector, spender, 0, amount));
        token.transferFrom(owner, spender, amount);

        assertEq(token.balanceOf(owner), held);
    }

    // ---------------------------------------------------------------------------------------------
    // permit
    // ---------------------------------------------------------------------------------------------

    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 relayerSeed, uint256 value, uint256 ttl) external {
        _count("permit");
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        address relayer = _pick(relayerSeed);
        uint256 deadline = block.timestamp + bound(ttl, 0, 365 days);
        uint256 nonce = token.nonces(owner);
        (uint8 v, bytes32 r, bytes32 s) = _sign(owner, spender, value, nonce, deadline);

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(owner, spender, value);
        token.permit(owner, spender, value, deadline, v, r, s);

        assertEq(token.nonces(owner), nonce + 1, "permit did not consume exactly one nonce");
        assertEq(token.allowance(owner, spender), value, "permit set the wrong allowance");
        ghost_allowance[owner][spender] = value;
        ghost_nonce[owner] = nonce + 1;
    }

    function permitReplay(uint256 ownerSeed, uint256 spenderSeed, uint256 value, uint256 ttl) external {
        _count("permitReplay");
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        uint256 deadline = block.timestamp + bound(ttl, 0, 365 days);
        uint256 nonce = token.nonces(owner);
        (uint8 v, bytes32 r, bytes32 s) = _sign(owner, spender, value, nonce, deadline);

        token.permit(owner, spender, value, deadline, v, r, s);
        ghost_allowance[owner][spender] = value;
        ghost_nonce[owner] = nonce + 1;

        // The same signature a second time recovers to somebody else, because the nonce moved on.
        vm.expectPartialRevert(SuperIdentityToken.InvalidSignature.selector);
        token.permit(owner, spender, value, deadline, v, r, s);

        assertEq(token.nonces(owner), nonce + 1, "a replayed permit consumed a nonce");
        assertEq(token.allowance(owner, spender), value);
    }

    function permitExpired(uint256 ownerSeed, uint256 spenderSeed, uint256 value, uint256 age) external {
        _count("permitExpired");
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        uint256 deadline = block.timestamp - bound(age, 1, block.timestamp);
        uint256 nonce = token.nonces(owner);
        uint256 allowedBefore = token.allowance(owner, spender);
        (uint8 v, bytes32 r, bytes32 s) = _sign(owner, spender, value, nonce, deadline);

        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.PermitExpired.selector, deadline, block.timestamp));
        token.permit(owner, spender, value, deadline, v, r, s);

        assertEq(token.nonces(owner), nonce, "an expired permit consumed a nonce");
        assertEq(token.allowance(owner, spender), allowedBefore, "an expired permit changed the allowance");
    }

    function permitWrongSigner(uint256 ownerSeed, uint256 forgerSeed, uint256 spenderSeed, uint256 value) external {
        _count("permitWrongSigner");
        address owner = _pick(ownerSeed);
        address forger = _pickOther(forgerSeed, owner);
        address spender = _pick(spenderSeed);
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = token.nonces(owner);
        uint256 allowedBefore = token.allowance(owner, spender);
        // Signed by the forger over the owner's permit: recovers to the forger, not the owner.
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyOf[forger], digest);

        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InvalidSignature.selector, forger, owner));
        token.permit(owner, spender, value, deadline, v, r, s);

        assertEq(token.nonces(owner), nonce, "a forged permit consumed a nonce");
        assertEq(token.allowance(owner, spender), allowedBefore, "a forged permit changed the allowance");
    }

    function permitTampered(uint256 ownerSeed, uint256 spenderSeed, uint256 value, uint256 delta) external {
        _count("permitTampered");
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = token.nonces(owner);
        uint256 allowedBefore = token.allowance(owner, spender);
        (uint8 v, bytes32 r, bytes32 s) = _sign(owner, spender, value, nonce, deadline);
        uint256 tampered;
        unchecked {
            tampered = value + bound(delta, 1, type(uint256).max);
        }
        if (tampered == value) tampered = value ^ 1;

        vm.expectPartialRevert(SuperIdentityToken.InvalidSignature.selector);
        token.permit(owner, spender, tampered, deadline, v, r, s);

        assertEq(token.nonces(owner), nonce);
        assertEq(token.allowance(owner, spender), allowedBefore);
    }

    // ---------------------------------------------------------------------------------------------
    // Environment and strangers
    // ---------------------------------------------------------------------------------------------

    function warp(uint256 delta) external {
        _count("warp");
        vm.warp(block.timestamp + bound(delta, 0, 30 days));
    }

    function changeChainId(uint256 id) external {
        _count("changeChainId");
        vm.chainId(bound(id, 1, type(uint32).max));
    }

    /// @dev Any selector the token does not define, from anyone, must fail: there is no fallback and
    ///      no hidden privileged surface.
    function callUnknownSelector(uint256 callerSeed, bytes4 selector, uint256 a, uint256 b) external {
        _count("callUnknownSelector");
        bytes4[13] memory known = [
            token.name.selector,
            token.symbol.selector,
            token.decimals.selector,
            token.TOTAL_SUPPLY.selector,
            token.totalSupply.selector,
            token.balanceOf.selector,
            token.allowance.selector,
            token.nonces.selector,
            token.DOMAIN_SEPARATOR.selector,
            token.transfer.selector,
            token.approve.selector,
            token.transferFrom.selector,
            token.permit.selector
        ];
        for (uint256 i = 0; i < known.length; i++) {
            if (selector == known[i]) return;
        }
        address caller = _pick(callerSeed);
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodeWithSelector(selector, a, b));
        assertFalse(ok, "an undefined selector succeeded");
    }

    function sendEther(uint256 callerSeed, uint256 amount, bool toTransfer) external {
        _count("sendEther");
        address caller = _pick(callerSeed);
        amount = bound(amount, 1, 1_000 ether);
        vm.deal(caller, amount);
        bytes memory data = toTransfer ? abi.encodeCall(token.transfer, (caller, 0)) : bytes("");
        vm.prank(caller);
        (bool ok,) = address(token).call{value: amount}(data);
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract SuperIdentityTokenInvariantTest is StdInvariant, Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    SuperIdentityHandler handler;
    SuperIdentityToken token;

    function setUp() public {
        handler = new SuperIdentityHandler();
        token = handler.token();

        bytes4[] memory selectors = new bytes4[](19);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferAll.selector;
        selectors[2] = handler.selfTransfer.selector;
        selectors[3] = handler.transferExceedingBalance.selector;
        selectors[4] = handler.transferToZeroAddress.selector;
        selectors[5] = handler.approve.selector;
        selectors[6] = handler.approveZeroAddress.selector;
        selectors[7] = handler.transferFrom.selector;
        selectors[8] = handler.transferFromExceedingAllowance.selector;
        selectors[9] = handler.transferFromExceedingBalance.selector;
        selectors[10] = handler.transferFromWithoutApproval.selector;
        selectors[11] = handler.permit.selector;
        selectors[12] = handler.permitReplay.selector;
        selectors[13] = handler.permitExpired.selector;
        selectors[14] = handler.permitWrongSigner.selector;
        selectors[15] = handler.permitTampered.selector;
        selectors[16] = handler.warp.selector;
        selectors[17] = handler.callUnknownSelector.selector;
        selectors[18] = handler.sendEther.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The supply is fixed: no sequence of calls, from anyone, changes what totalSupply reports.
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY, "totalSupply changed");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    /// @dev Conservation: what the actors hold between them is exactly the supply. Nothing leaks to
    ///      the handler, the zero address or the token itself.
    function invariant_sumOfBalancesEqualsSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply(), "sum of balances drifted from the supply");
        assertEq(token.balanceOf(address(handler)), 0, "the handler holds tokens");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(token.balanceOf(address(token)), 0, "the token holds its own tokens");
    }

    /// @dev Each balance equals the model: initial allocation plus everything received minus
    ///      everything sent, and nobody has sent more than they ever held.
    function invariant_balancesMatchTheModel() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address actor = handler.actors(i);
            uint256 initial = handler.ghost_initial(actor);
            uint256 received = handler.ghost_received(actor);
            uint256 sent = handler.ghost_sent(actor);
            assertLe(sent, initial + received, "an actor sent more than it ever held");
            assertEq(token.balanceOf(actor), initial + received - sent, "balance disagrees with the ledger model");
            assertEq(token.balanceOf(actor), handler.ghost_balance(actor), "balance disagrees with the ghost balance");
            assertLe(token.balanceOf(actor), SUPPLY, "a balance exceeds the supply");
        }
    }

    /// @dev Every allowance is exactly what the last approve, permit or transferFrom left it at.
    function invariant_allowancesMatchTheModel() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < n; j++) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghost_allowance(owner, spender), "allowance drifted");
            }
        }
    }

    /// @dev A nonce counts successful permits only: failed permits consume nothing.
    function invariant_noncesCountSuccessfulPermits() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address actor = handler.actors(i);
            assertEq(token.nonces(actor), handler.ghost_nonce(actor), "nonce disagrees with successful permits");
        }
    }

    /// @dev The domain separator always describes the current chain and this contract.
    function invariant_domainSeparatorMatchesCurrentChain() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SuperIdentity"),
                keccak256("1"),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected, "domain separator does not match the chain");
    }

    function invariant_metadataNeverChanges() public view {
        assertEq(token.name(), "SuperIdentity");
        assertEq(token.symbol(), "SUPER");
        assertEq(token.decimals(), 18);
    }

    function invariant_tokenHoldsNoEther() public view {
        assertEq(address(token).balance, 0, "the token accumulated ether");
    }
}

/// @dev The same handler with the chain id allowed to change mid-sequence: permits signed under the
///      current chain id keep working and the separator follows the chain, without any other
///      invariant breaking.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail-on-revert = true
contract SuperIdentityTokenForkInvariantTest is StdInvariant, Test {
    SuperIdentityHandler handler;
    SuperIdentityToken token;

    function setUp() public {
        handler = new SuperIdentityHandler();
        token = handler.token();

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.changeChainId.selector;
        selectors[1] = handler.permit.selector;
        selectors[2] = handler.permitReplay.selector;
        selectors[3] = handler.permitWrongSigner.selector;
        selectors[4] = handler.transferFrom.selector;
        selectors[5] = handler.transfer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_domainSeparatorFollowsTheChainId() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SuperIdentity"),
                keccak256("1"),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }

    function invariant_supplyAndAllowancesSurviveForks() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address owner = handler.actors(i);
            sum += token.balanceOf(owner);
            assertEq(token.nonces(owner), handler.ghost_nonce(owner));
            for (uint256 j = 0; j < n; j++) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghost_allowance(owner, spender));
            }
        }
        assertEq(sum, token.totalSupply());
    }
}
