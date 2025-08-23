// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {HotPotato} from "src/HotPotato.sol";

/// @notice Deployment script for Monad testnet (or any EVM chain via --rpc-url)
/// Env vars:
/// - MONAD_PRIVATE_KEY: deployer private key (uint)
/// - BASE_PRICE_WEI: base price in wei (default: 1e18)
/// - MULTIPLIER_BPS: price multiplier in bps (default: 12000)
contract DeployHotPotato is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("MONAD_PRIVATE_KEY");

        uint256 basePriceWei = _envOrUint("BASE_PRICE_WEI", 1 ether);
        uint256 multiplierBps = _envOrUint("MULTIPLIER_BPS", 12000);

        address creatorAddress = _envOrAddress("CREATOR_ADDRESS", vm.addr(deployerKey));
        vm.startBroadcast(deployerKey);
        HotPotato hotPotato = new HotPotato(basePriceWei, multiplierBps, creatorAddress);
        vm.stopBroadcast();

        console2.log("HotPotato deployed at:", address(hotPotato));
        console2.log("Base price (wei):", basePriceWei);
        console2.log("Multiplier (bps):", multiplierBps);
        console2.log("Creator:", creatorAddress);
    }

    function _envOrUint(string memory key, uint256 defaultValue) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return defaultValue;
        }
    }

    function _envOrAddress(string memory key, address defaultValue) internal view returns (address) {
        try vm.envAddress(key) returns (address a) {
            return a;
        } catch {
            return defaultValue;
        }
    }
}


