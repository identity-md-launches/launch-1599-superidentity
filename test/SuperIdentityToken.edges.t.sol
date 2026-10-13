// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {SuperIdentityToken} from "../src/SuperIdentityToken.sol";

/// @dev Deploys through CREATE2 the way the launch factory does, so the supply has to land on the
///      CREATE2 deployer and not on whoever called it.
contract Create2Deployer {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "create2 failed");
    }
}

/// @title Edge cases and failure paths beyond the base suite.
/// @dev Inputs the implementation might not have considered: zero, one wei, the whole supply, the
///      maximum, the same call twice, callers who are not who the code assumed, and permits at every
///      boundary of deadline, nonce, chain id and signature encoding.
/// forge-config: default.fuzz.runs = 1000
contract SuperIdentityTokenEdgesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    SuperIdentityToken token;
    address deployer;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 ownerKey = 0x0D15EA5E;
    address owner;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        deployer = address(this);
        token = new SuperIdentityToken();
        owner = vm.addr(ownerKey);
    }

    function _digest(address owner_, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner_,
                spender,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function _sign(uint256 key, address owner_, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        (v, r, s) = vm.sign(key, _digest(owner_, spender, value, nonce, deadline));
    }

    // ---------------------------------------------------------------------------------------------
    // Construction and the launch deployer
    // ---------------------------------------------------------------------------------------------

    function test_create2DeployerReceivesTheSupplyNotItsCaller() public {
        Create2Deployer factory = new Create2Deployer();
        address predicted = vm.computeCreate2Address(
            bytes32(uint256(7)), keccak256(type(SuperIdentityToken).creationCode), address(factory)
        );
        vm.expectEmit(true, true, true, true, predicted);
        emit Transfer(address(0), address(factory), SUPPLY);
        address deployed = factory.deploy(type(SuperIdentityToken).creationCode, bytes32(uint256(7)));
        assertEq(deployed, predicted, "CREATE2 address is not the predicted one");
        SuperIdentityToken launched = SuperIdentityToken(deployed);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(address(this)), 0);
        assertEq(launched.balanceOf(tx.origin), 0);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_creationCodeTakesNoConstructorArguments() public {
        // Appending arguments to the creation code must not change what is minted or to whom: a
        // deployer that passes stray data still gets exactly the supply.
        bytes memory code = abi.encodePacked(type(SuperIdentityToken).creationCode, abi.encode(alice, uint256(1)));
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        assertTrue(deployed != address(0), "deployment with stray arguments failed");
        assertEq(SuperIdentityToken(deployed).balanceOf(address(this)), SUPPLY);
        assertEq(SuperIdentityToken(deployed).balanceOf(alice), 0);
    }

    function test_twoDeploymentsAreIndependent() public {
        vm.prank(alice);
        SuperIdentityToken other = new SuperIdentityToken();
        assertEq(other.balanceOf(alice), SUPPLY);
        assertEq(other.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
        assertTrue(other.DOMAIN_SEPARATOR() != token.DOMAIN_SEPARATOR(), "two tokens share a domain separator");
    }

    // ---------------------------------------------------------------------------------------------
    // transfer edges
    // ---------------------------------------------------------------------------------------------

    function test_transferOfZeroEmitsTransferEvent() public {
        // ERC-20: transfers of 0 MUST be treated as normal transfers and fire the event.
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(deployer, alice, 0);
        assertTrue(token.transfer(alice, 0));
        vm.prank(bob); // even from an account that holds nothing
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(bob, alice, 0);
        assertTrue(token.transfer(alice, 0));
    }

    function test_transferOfOneWei() public {
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(deployer), SUPPLY - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientBalance.selector, alice, 1, 2));
        token.transfer(bob, 2);
    }

    function test_transferOfWholeSupplyAndNothingMore() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientBalance.selector, deployer, 0, 1));
        token.transfer(bob, 1);
        // And all the way back.
        vm.prank(alice);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferOfMaxUintRevertsWithoutWrapping() public {
        vm.expectRevert(
            abi.encodeWithSelector(SuperIdentityToken.InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(SuperIdentityToken.InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_selfTransferAboveBalanceReverts() public {
        token.transfer(alice, 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientBalance.selector, alice, 10, 11));
        token.transfer(alice, 11);
        assertEq(token.balanceOf(alice), 10);
    }

    function test_selfTransferOfWholeBalanceKeepsIt() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(deployer, deployer, SUPPLY);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferToTheTokenItselfIsAllowedAndUnrecoverable() public {
        // Documented behaviour: there is no admin to recover it. The transfer succeeds and the
        // tokens are stuck, which the README states. Verified here so nobody assumes otherwise.
        assertTrue(token.transfer(address(token), 5));
        assertEq(token.balanceOf(address(token)), 5);
        vm.prank(address(token));
        assertTrue(token.transfer(alice, 5)); // only the contract itself could, and it never calls out
        assertEq(token.balanceOf(alice), 5);
    }

    function test_zeroAddressTransferRevertsEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_sameTransferTwiceMovesTwice() public {
        token.transfer(alice, 7);
        token.transfer(alice, 7);
        assertEq(token.balanceOf(alice), 14);
        assertEq(token.balanceOf(deployer), SUPPLY - 14);
    }

    function test_callerCannotSpendSomebodyElsesBalanceViaTransfer() public {
        token.transfer(alice, 100);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientBalance.selector, bob, 0, 100));
        token.transfer(carol, 100);
        assertEq(token.balanceOf(alice), 100);
    }

    // ---------------------------------------------------------------------------------------------
    // approve / transferFrom edges
    // ---------------------------------------------------------------------------------------------

    function test_approveZeroEmitsAndClears() public {
        token.approve(alice, 5);
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(deployer, alice, 0);
        assertTrue(token.approve(alice, 0));
        assertEq(token.allowance(deployer, alice), 0);
    }

    function test_approveSelfAndTransferFromSelf() public {
        token.transfer(alice, 10);
        vm.startPrank(alice);
        token.approve(alice, 4);
        assertTrue(token.transferFrom(alice, bob, 4));
        assertEq(token.allowance(alice, alice), 0);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 4);
        assertEq(token.balanceOf(alice), 6);
    }

    function test_approveAboveSupplyIsAllowedButSpendingIsBoundedByBalance() public {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(bob, type(uint256).max - 1); // large but finite
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientBalance.selector, alice, 10, 11));
        token.transferFrom(alice, carol, 11);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 10));
        assertEq(token.allowance(alice, bob), type(uint256).max - 11, "a finite allowance was not decremented");
    }

    function test_transferFromExactAllowanceLeavesZeroAndEmitsApprovalZero() public {
        token.approve(alice, 9);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(deployer, alice, 0);
        assertTrue(token.transferFrom(deployer, bob, 9));
        assertEq(token.allowance(deployer, alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFromOfZeroWithNoAllowanceSucceeds() public {
        // Zero is within a zero allowance: the ERC-20 zero-transfer rule applies here too.
        vm.prank(bob);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(deployer, carol, 0);
        assertTrue(token.transferFrom(deployer, carol, 0));
        assertEq(token.allowance(deployer, bob), 0);
    }

    function test_infiniteAllowanceDoesNotEmitApprovalOnSpend() public {
        token.approve(alice, type(uint256).max);
        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 3);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "expected only the Transfer event");
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
    }

    function test_maxMinusOneAllowanceIsFiniteAndDecrements() public {
        token.approve(alice, type(uint256).max - 1);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, alice), type(uint256).max - 2);
    }

    function test_transferFromFromZeroAddressReverts() public {
        // Nobody can approve for the zero address, so the allowance check fails first.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), bob, 1);
    }

    function test_transferFromAllowanceIsPerSpender() public {
        token.approve(alice, 50);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, alice), 50, "another spender's failure touched the allowance");
    }

    function test_failedTransferFromLeavesAllowanceIntact() public {
        token.transfer(alice, 5);
        vm.prank(alice);
        token.approve(bob, 100);
        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(alice, carol, 6); // balance too low, allowance was enough
        assertEq(token.allowance(alice, bob), 100);
        assertEq(token.balanceOf(alice), 5);
    }

    // ---------------------------------------------------------------------------------------------
    // permit edges
    // ---------------------------------------------------------------------------------------------

    function test_permitAtExactDeadlineSucceeds() public {
        uint256 deadline = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 1, 0, deadline);
        token.permit(owner, bob, 1, deadline, v, r, s);
        assertEq(token.allowance(owner, bob), 1);
    }

    function test_permitOneSecondPastDeadlineReverts() public {
        uint256 deadline = block.timestamp + 10;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 1, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.PermitExpired.selector, deadline, deadline + 1));
        token.permit(owner, bob, 1, deadline, v, r, s);
        assertEq(token.nonces(owner), 0, "an expired permit consumed a nonce");
    }

    function test_permitWithMaxDeadlineNeverExpires() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 2, 0, type(uint256).max);
        vm.warp(type(uint64).max);
        token.permit(owner, bob, 2, type(uint256).max, v, r, s);
        assertEq(token.allowance(owner, bob), 2);
    }

    function test_permitOfZeroValueClearsAllowance() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 5, 0, block.timestamp + 1);
        token.permit(owner, bob, 5, block.timestamp + 1, v, r, s);
        (v, r, s) = _sign(ownerKey, owner, bob, 0, 1, block.timestamp + 1);
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(owner, bob, 0);
        token.permit(owner, bob, 0, block.timestamp + 1, v, r, s);
        assertEq(token.allowance(owner, bob), 0);
        assertEq(token.nonces(owner), 2);
    }

    function test_permitWithMaxValueGrantsInfiniteAllowance() public {
        token.transfer(owner, 10);
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, type(uint256).max, 0, block.timestamp + 1);
        token.permit(owner, bob, type(uint256).max, block.timestamp + 1, v, r, s);
        vm.prank(bob);
        token.transferFrom(owner, carol, 10);
        assertEq(token.allowance(owner, bob), type(uint256).max);
    }

    function test_permitToZeroSpenderRevertsAndKeepsNonce() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, address(0), 1, 0, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InvalidReceiver.selector, address(0)));
        token.permit(owner, address(0), 1, block.timestamp + 1, v, r, s);
        assertEq(token.nonces(owner), 0);
    }

    function test_permitForZeroOwnerReverts() public {
        // No key recovers to address(0); a garbage signature recovers to 0 and is refused.
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InvalidSignature.selector, address(0), address(0)));
        token.permit(address(0), bob, 1, block.timestamp + 1, 27, bytes32(0), bytes32(0));
        // And a valid signature from somebody cannot be presented as the zero owner's.
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, address(0), bob, 1, 0, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InvalidSignature.selector, owner, address(0)));
        token.permit(address(0), bob, 1, block.timestamp + 1, v, r, s);
    }

    function test_permitWithInvalidVReverts() public {
        (, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 1, 0, block.timestamp + 1);
        uint8[4] memory bad = [0, 1, 26, 29];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InvalidSignature.selector, address(0), owner));
            token.permit(owner, bob, 1, block.timestamp + 1, bad[i], r, s);
        }
        assertEq(token.nonces(owner), 0);
    }

    function test_permitWithZeroSignatureReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InvalidSignature.selector, address(0), owner));
        token.permit(owner, bob, 1, block.timestamp + 1, 27, bytes32(0), bytes32(0));
    }

    function test_permitWithSAboveHalfOrderRevertsEvenIfItWouldRecover() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 1, 0, block.timestamp + 1);
        // vm.sign returns low-s; the flipped encoding is a valid ECDSA signature the contract refuses.
        bytes32 sHigh = bytes32(SECP256K1_N - uint256(s));
        uint8 vFlipped = v == 27 ? 28 : 27;
        assertEq(ecrecover(_digest(owner, bob, 1, 0, block.timestamp + 1), vFlipped, r, sHigh), owner);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InvalidSignature.selector, address(0), owner));
        token.permit(owner, bob, 1, block.timestamp + 1, vFlipped, r, sHigh);
        // The boundary itself: s one above n/2 is refused, s == n/2 is passed on to ecrecover.
        bytes32 justAbove = bytes32(0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A1);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InvalidSignature.selector, address(0), owner));
        token.permit(owner, bob, 1, block.timestamp + 1, 27, r, justAbove);
    }

    function test_permitWrongSpenderWrongDeadlineWrongOwnerAllRevert() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 1, 0, deadline);
        vm.expectPartialRevert(SuperIdentityToken.InvalidSignature.selector);
        token.permit(owner, carol, 1, deadline, v, r, s);
        vm.expectPartialRevert(SuperIdentityToken.InvalidSignature.selector);
        token.permit(owner, bob, 1, deadline + 1, v, r, s);
        vm.expectPartialRevert(SuperIdentityToken.InvalidSignature.selector);
        token.permit(alice, bob, 1, deadline, v, r, s);
        assertEq(token.nonces(owner), 0);
        assertEq(token.nonces(alice), 0);
        assertEq(token.allowance(owner, bob), 0);
        // The untouched signature still works afterwards: failures consumed nothing.
        token.permit(owner, bob, 1, deadline, v, r, s);
        assertEq(token.allowance(owner, bob), 1);
    }

    function test_permitSignedWithFutureNonceFailsUntilItsTurn() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v1, bytes32 r1, bytes32 s1) = _sign(ownerKey, owner, bob, 11, 1, deadline);
        vm.expectPartialRevert(SuperIdentityToken.InvalidSignature.selector);
        token.permit(owner, bob, 11, deadline, v1, r1, s1);
        (uint8 v0, bytes32 r0, bytes32 s0) = _sign(ownerKey, owner, bob, 10, 0, deadline);
        token.permit(owner, bob, 10, deadline, v0, r0, s0);
        token.permit(owner, bob, 11, deadline, v1, r1, s1);
        assertEq(token.allowance(owner, bob), 11);
        assertEq(token.nonces(owner), 2);
    }

    function test_permitSignedOnAnotherChainIdIsRejectedHere() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 1, 0, deadline);
        vm.chainId(4663);
        vm.expectPartialRevert(SuperIdentityToken.InvalidSignature.selector);
        token.permit(owner, bob, 1, deadline, v, r, s);
        // Signed under the new chain id, it works, and the old one no longer does afterwards either.
        (v, r, s) = _sign(ownerKey, owner, bob, 1, 0, deadline);
        token.permit(owner, bob, 1, deadline, v, r, s);
        assertEq(token.allowance(owner, bob), 1);
    }

    function test_domainSeparatorReturnsToCachedValueWhenChainIdReturns() public {
        bytes32 cached = token.DOMAIN_SEPARATOR();
        uint256 original = block.chainid;
        vm.chainId(4663);
        bytes32 forked = token.DOMAIN_SEPARATOR();
        assertTrue(forked != cached);
        vm.chainId(original);
        assertEq(token.DOMAIN_SEPARATOR(), cached);
    }

    function test_permitDoesNotMoveTokens() public {
        token.transfer(owner, 10);
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 10, 0, block.timestamp + 1);
        token.permit(owner, bob, 10, block.timestamp + 1, v, r, s);
        assertEq(token.balanceOf(owner), 10);
        assertEq(token.balanceOf(bob), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Callers the code did not assume
    // ---------------------------------------------------------------------------------------------

    function test_nonPayableFunctionsRefuseEther() public {
        vm.deal(alice, 3 ether);
        bytes[4] memory data = [
            abi.encodeCall(token.transfer, (bob, 0)),
            abi.encodeCall(token.approve, (bob, 0)),
            abi.encodeCall(token.transferFrom, (alice, bob, 0)),
            abi.encodeCall(token.balanceOf, (bob))
        ];
        for (uint256 i = 0; i < data.length; i++) {
            vm.prank(alice);
            (bool ok,) = address(token).call{value: 1}(data[i]);
            assertFalse(ok, "a non-payable function accepted ether");
        }
        assertEq(address(token).balance, 0);
    }

    function test_unknownSelectorsRevert() public {
        bytes4[5] memory selectors =
            [bytes4(0x00000000), bytes4(0xffffffff), bytes4(0x12345678), bytes4(0xdeadbeef), bytes4(0x01020304)];
        for (uint256 i = 0; i < selectors.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], alice, SUPPLY));
            assertFalse(ok);
        }
        (bool okEmpty,) = address(token).call("");
        assertFalse(okEmpty, "empty calldata was accepted");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_tokenContractAsCallerHasNoSpecialPower() public {
        vm.startPrank(address(token));
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientBalance.selector, address(token), 0, 1));
        token.transfer(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientAllowance.selector, address(token), 0, 1));
        token.transferFrom(deployer, alice, 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz properties
    // ---------------------------------------------------------------------------------------------

    function testFuzz_roundTripTransferRestoresBalances(address a, uint256 amount) public {
        a = address(uint160(bound(uint256(uint160(a)), 1, type(uint160).max)));
        amount = bound(amount, 0, SUPPLY);
        uint256 deployerBefore = token.balanceOf(deployer);
        uint256 aBefore = token.balanceOf(a);
        token.transfer(a, amount);
        vm.prank(a);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), deployerBefore);
        assertEq(token.balanceOf(a), aBefore);
    }

    function testFuzz_splitTransfersEqualOneTransfer(uint256 total, uint256 first) public {
        total = bound(total, 0, SUPPLY);
        first = bound(first, 0, total);
        token.transfer(alice, first);
        token.transfer(alice, total - first);
        assertEq(token.balanceOf(alice), total);
        assertEq(token.balanceOf(deployer), SUPPLY - total);
    }

    function testFuzz_transferFromNeverExceedsMinOfBalanceAndAllowance(uint256 held, uint256 allowed, uint256 amount)
        public
    {
        held = bound(held, 0, SUPPLY);
        allowed = bound(allowed, 0, type(uint256).max);
        amount = bound(amount, 0, type(uint256).max);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        if (allowed != type(uint256).max && amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(SuperIdentityToken.InsufficientAllowance.selector, bob, allowed, amount)
            );
            token.transferFrom(alice, carol, amount);
        } else if (amount > held) {
            vm.expectRevert(
                abi.encodeWithSelector(SuperIdentityToken.InsufficientBalance.selector, alice, held, amount)
            );
            token.transferFrom(alice, carol, amount);
        } else {
            assertTrue(token.transferFrom(alice, carol, amount));
            assertEq(token.balanceOf(carol), amount);
            assertEq(token.balanceOf(alice), held - amount);
            assertEq(token.allowance(alice, bob), allowed == type(uint256).max ? type(uint256).max : allowed - amount);
        }
    }

    function testFuzz_approveIsIdempotentAndOverwrites(address spender, uint256 a, uint256 b) public {
        spender = address(uint160(bound(uint256(uint160(spender)), 1, type(uint160).max)));
        token.approve(spender, a);
        token.approve(spender, a);
        assertEq(token.allowance(deployer, spender), a);
        token.approve(spender, b);
        assertEq(token.allowance(deployer, spender), b);
    }

    function testFuzz_permitFromAnyKeySetsAllowanceForThatSignerOnly(
        uint256 key,
        address spender,
        uint256 value,
        uint256 ttl
    ) public {
        key = bound(key, 1, SECP256K1_N - 1);
        spender = address(uint160(bound(uint256(uint160(spender)), 1, type(uint160).max)));
        ttl = bound(ttl, 0, 1000 days);
        address signer = vm.addr(key);
        uint256 deadline = block.timestamp + ttl;
        (uint8 v, bytes32 r, bytes32 s) = _sign(key, signer, spender, value, 0, deadline);

        token.permit(signer, spender, value, deadline, v, r, s);
        assertEq(token.allowance(signer, spender), value);
        assertEq(token.nonces(signer), 1);

        // The same signature is useless for any other owner.
        vm.expectPartialRevert(SuperIdentityToken.InvalidSignature.selector);
        token.permit(alice, spender, value, deadline, v, r, s);
        assertEq(token.allowance(alice, spender), 0);
    }

    function testFuzz_permitExpiredByAnyMarginReverts(uint256 ttl, uint256 late) public {
        ttl = bound(ttl, 0, 1000 days);
        late = bound(late, 1, 1000 days);
        uint256 deadline = block.timestamp + ttl;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, bob, 1, 0, deadline);
        vm.warp(deadline + late);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.PermitExpired.selector, deadline, deadline + late));
        token.permit(owner, bob, 1, deadline, v, r, s);
        assertEq(token.nonces(owner), 0);
    }

    function testFuzz_randomSignatureNeverGrantsAllowance(bytes32 r, bytes32 s, uint8 v) public {
        // A random signature either fails to recover or recovers to a stranger; the owner's
        // allowance stays untouched either way and no nonce is consumed.
        vm.expectPartialRevert(SuperIdentityToken.InvalidSignature.selector);
        token.permit(owner, bob, 1, block.timestamp + 1, v, r, s);
        assertEq(token.allowance(owner, bob), 0);
        assertEq(token.nonces(owner), 0);
    }
}
