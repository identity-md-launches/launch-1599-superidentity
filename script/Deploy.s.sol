// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SuperIdentityToken} from "../src/SuperIdentityToken.sol";

/// @title Deploy script for SuperIdentity (SUPER)
/// @notice Reference only. On IdentityMD the ProjectFactory deploys the token from its built
///         bytecode and the whole supply is minted to the factory; this script is for a local or
///         test deployment by anyone else. The token takes no constructor arguments, so the only
///         "configuration" is who broadcasts: that account receives the whole supply.
contract DeployScript is Script {
    /// @notice Deploys the token. Whoever calls this (the broadcaster) receives the whole supply.
    /// @dev Kept argument-free and pure of environment reads so tests can call it directly.
    function deploy() public returns (SuperIdentityToken token) {
        token = new SuperIdentityToken();
    }

    /// @notice Entry point for `forge script`: broadcasts a single deployment from the configured
    ///         signer. Reads no environment variables itself.
    function run() external returns (SuperIdentityToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
