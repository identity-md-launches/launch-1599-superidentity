// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SuperIdentityToken} from "../src/SuperIdentityToken.sol";
import {DeployScript} from "../script/Deploy.s.sol";

/// @dev Stands in for the launch factory: deploys the token so the supply lands on it, then pays it
///      out the way the factory does (to the distributor, the pool and the requester).
contract FactoryProbe {
    SuperIdentityToken public token;

    function deployToken() external {
        token = new SuperIdentityToken();
    }

    function pay(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract SuperIdentityTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    SuperIdentityToken token;
    address deployer;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 signerKey = 0xA11CE;
    address signer;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        deployer = address(this);
        token = new SuperIdentityToken();
        signer = vm.addr(signerKey);
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "SuperIdentity");
        assertEq(token.symbol(), "SUPER");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function test_constructorMintsWholeSupplyToDeployerOnce() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        SuperIdentityToken fresh = new SuperIdentityToken();
        assertEq(fresh.balanceOf(alice), SUPPLY, "deployer did not receive the whole supply");
        assertEq(fresh.totalSupply(), SUPPLY);
        // The test contract deployed `token` in setUp, so it is that token's deployer.
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_whenTheFactoryDeploysTheFactoryHoldsTheSupply() public {
        FactoryProbe factory = new FactoryProbe();
        factory.deployToken();
        SuperIdentityToken launched = factory.token();
        assertEq(launched.balanceOf(address(factory)), SUPPLY, "the factory does not hold the whole supply");
        assertEq(launched.balanceOf(address(this)), 0, "the caller of the factory received tokens");
    }

    function test_launchFlowsMoveExactAmounts() public {
        FactoryProbe factory = new FactoryProbe();
        factory.deployToken();
        SuperIdentityToken launched = factory.token();

        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("poolManager");
        address requester = makeAddr("requester");
        uint256 swarm = SUPPLY * 1_000 / 10_000;
        uint256 pool = SUPPLY * 8_000 / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;

        assertTrue(factory.pay(distributor, swarm));
        assertTrue(factory.pay(poolManager, pool));
        assertTrue(factory.pay(requester, remainder));

        assertEq(launched.balanceOf(distributor), swarm, "swarm share arrived short");
        assertEq(launched.balanceOf(poolManager), pool, "pool share arrived short");
        assertEq(launched.balanceOf(requester), remainder, "remainder arrived short");
        assertEq(launched.balanceOf(address(factory)), 0, "the factory kept something back");

        // A claim out of the distributor arrives whole too.
        address claimant = makeAddr("claimant");
        vm.prank(distributor);
        assertTrue(launched.transfer(claimant, swarm));
        assertEq(launched.balanceOf(claimant), swarm);
        assertEq(launched.totalSupply(), SUPPLY, "the launch flows changed the supply");
    }

    // ---------------------------------------------------------------------------------------------
    // transfer
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesBalanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, alice, 100 ether);
        assertTrue(token.transfer(alice, 100 ether));
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferOfZeroSucceeds() public {
        assertTrue(token.transfer(alice, 0));
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        assertTrue(token.transfer(alice, 10 ether));
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        token.transfer(alice, 5 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(SuperIdentityToken.InsufficientBalance.selector, alice, 5 ether, 6 ether)
        );
        token.transfer(bob, 6 ether);
    }

    function test_transferFromEmptyAccountReverts() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientBalance.selector, bob, 0, 1));
        token.transfer(alice, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // approve / transferFrom
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, alice, 42 ether);
        assertTrue(token.approve(alice, 42 ether));
        assertEq(token.allowance(deployer, alice), 42 ether);
    }

    function test_approveOverwritesRatherThanAdds() public {
        token.approve(alice, 42 ether);
        token.approve(alice, 1 ether);
        assertEq(token.allowance(deployer, alice), 1 ether);
    }

    function test_approveZeroAddressSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InvalidReceiver.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 60 ether);

        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 20 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, carol, 40 ether);
        assertTrue(token.transferFrom(alice, carol, 40 ether));

        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.balanceOf(carol), 40 ether);
        assertEq(token.allowance(alice, bob), 20 ether);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(SuperIdentityToken.InsufficientAllowance.selector, bob, 10 ether, 11 ether)
        );
        token.transferFrom(alice, carol, 11 ether);
    }

    function test_transferFromWithoutApprovalReverts() public {
        token.transfer(alice, 100 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_transferFromRevertsWhenOwnerBalanceTooLow() public {
        token.transfer(alice, 5 ether);
        vm.prank(alice);
        token.approve(bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(SuperIdentityToken.InsufficientBalance.selector, alice, 5 ether, 6 ether)
        );
        token.transferFrom(alice, carol, 6 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, carol, 30 ether);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.balanceOf(carol), 30 ether);
    }

    function test_transferFromToZeroAddressReverts() public {
        token.approve(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // permit (EIP-2612)
    // ---------------------------------------------------------------------------------------------

    function _sign(uint256 key, address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
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
        (v, r, s) = vm.sign(key, digest);
    }

    function test_domainSeparatorMatchesEip712() public view {
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

    function test_domainSeparatorFollowsChainIdOnFork() public {
        bytes32 before = token.DOMAIN_SEPARATOR();
        vm.chainId(4663);
        assertTrue(token.DOMAIN_SEPARATOR() != before, "domain separator did not change with chain id");
    }

    function test_permitSetsAllowanceAndBumpsNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, 7 ether, 0, deadline);

        vm.expectEmit(true, true, true, true);
        emit Approval(signer, bob, 7 ether);
        vm.prank(carol); // anyone may submit the signed permit
        token.permit(signer, bob, 7 ether, deadline, v, r, s);

        assertEq(token.allowance(signer, bob), 7 ether);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitThenTransferFrom() public {
        token.transfer(signer, 10 ether);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, 10 ether, 0, deadline);
        token.permit(signer, bob, 10 ether, deadline, v, r, s);
        vm.prank(bob);
        token.transferFrom(signer, carol, 10 ether);
        assertEq(token.balanceOf(carol), 10 ether);
        assertEq(token.balanceOf(signer), 0);
    }

    function test_permitRevertsWhenExpired() public {
        uint256 deadline = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, 1 ether, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.PermitExpired.selector, deadline, deadline + 1));
        token.permit(signer, bob, 1 ether, deadline, v, r, s);
    }

    function test_permitRevertsOnWrongSigner() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(0xB0B, signer, bob, 1 ether, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InvalidSignature.selector, vm.addr(0xB0B), signer));
        token.permit(signer, bob, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 0);
    }

    function test_permitCannotBeReplayed() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, 1 ether, 0, deadline);
        token.permit(signer, bob, 1 ether, deadline, v, r, s);
        // Nonce is now 1, so the same signature recovers to a different address.
        vm.expectRevert();
        token.permit(signer, bob, 1 ether, deadline, v, r, s);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitRevertsOnTamperedValue() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, 1 ether, 0, deadline);
        vm.expectRevert();
        token.permit(signer, bob, 2 ether, deadline, v, r, s);
    }

    function test_permitRejectsMalleableSignature() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(signerKey, signer, bob, 1 ether, 0, deadline);
        // Flip to the high-s encoding of the same signature.
        bytes32 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sHigh = bytes32(uint256(n) - uint256(s));
        uint8 vFlipped = v == 27 ? 28 : 27;
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InvalidSignature.selector, address(0), signer));
        token.permit(signer, bob, 1 ether, deadline, vFlipped, r, sHigh);
    }

    // ---------------------------------------------------------------------------------------------
    // No privileged surface
    // ---------------------------------------------------------------------------------------------

    function test_noAdminCallIncreasesSupplyOrGrantsTokens() public {
        address attacker = makeAddr("attacker");
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            // From the deployer, the most plausible trusted address, too.
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        token.transfer(alice, 1_000 ether);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        // The deployer cannot pull from a holder without an allowance.
        vm.expectRevert();
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 1_000 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 500 ether));
        assertEq(token.balanceOf(bob), 500 ether);
    }

    function test_noEtherAccepted() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Bytecode properties the launch checks
    // ---------------------------------------------------------------------------------------------

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_creationCodeHasNoLinkPlaceholders() public pure {
        bytes memory code = type(SuperIdentityToken).creationCode;
        // An unlinked library leaves "__$" placeholders in the bytecode; there must be none.
        for (uint256 i = 0; i + 2 < code.length; i++) {
            assertFalse(code[i] == "_" && code[i + 1] == "_" && code[i + 2] == "$", "unlinked library placeholder");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Deploy script
    // ---------------------------------------------------------------------------------------------

    function test_deployScriptMintsToCaller() public {
        DeployScript script = new DeployScript();
        // `deploy` constructs the token from the script contract, so the script holds the supply.
        SuperIdentityToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
        assertEq(deployed.name(), "SuperIdentity");
        assertEq(deployed.symbol(), "SUPER");
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: conservation of supply
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer) + token.balanceOf(to), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        token.transfer(alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SuperIdentityToken.InsufficientBalance.selector, alice, held, amount));
        token.transfer(bob, amount);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        token.approve(alice, allowed);
        vm.prank(alice);
        if (amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(SuperIdentityToken.InsufficientAllowance.selector, alice, allowed, amount)
            );
            token.transferFrom(deployer, bob, amount);
        } else {
            token.transferFrom(deployer, bob, amount);
            assertEq(token.balanceOf(bob), amount);
            assertEq(token.allowance(deployer, alice), allowed - amount);
        }
    }
}
