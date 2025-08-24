// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/console2.sol";
import {BaseHotPotatoScript} from "script/utils/BaseHotPotatoScript.s.sol";
import {HotPotato} from "src/HotPotato.sol";

/// @notice Simulate a small game loop to generate indexable data
/// Env:
/// - CONTRACT_ADDRESS: deployed HotPotato
/// - NUM_PLAYERS: default 5
/// - NUM_ROUNDS: default 2
/// - SPONSOR_EVERY: default 3 (sponsor every N takes)
/// - TAKE_VALUE_OVERRIDE_WEI: optional override for take value
contract SimulateGame is BaseHotPotatoScript {
    function run() external {
        HotPotato game = getHotPotato();
        uint256 numPlayers = _envOrUint("NUM_PLAYERS", 5);
        uint256 numRounds = _envOrUint("NUM_ROUNDS", 2);
        uint256 sponsorEvery = _envOrUint("SPONSOR_EVERY", 3);

        // Derive a small set of accounts from mnemonic or use same key
        address[] memory players = new address[](numPlayers);
        uint256[] memory keys = new uint256[](numPlayers);
        for (uint256 i = 0; i < numPlayers; i++) {
            keys[i] = _deriveKeyIdx(i);
            players[i] = vm.addr(keys[i]);
        }

        for (uint256 r = 0; r < numRounds; r++) {
            for (uint256 i = 0; i < numPlayers; i++) {
                uint256 valueToSend = _takeValue(game);
                vm.startBroadcast(keys[i]);
                game.take{value: valueToSend}();
                vm.stopBroadcast();

                // Next block for settle
                vm.roll(block.number + 1);

                // Keeper settles (use player 0 as keeper for simplicity)
                vm.startBroadcast(keys[0]);
                game.settle();
                vm.stopBroadcast();

                if ((i + 1) % sponsorEvery == 0) {
                    // Sponsor small amount
                    vm.startBroadcast(keys[(i + 1) % numPlayers]);
                    try game.sponsorPot{value: 1 ether}("sim-sponsor") {
                    } catch {}
                    vm.stopBroadcast();
                }
            }
        }

        console2.log("Simulation complete.");
    }

    function _deriveKeyIdx(uint256 idx) internal view returns (uint256) {
        try vm.envString("MNEMONIC") returns (string memory mnem) {
            uint32 base = uint32(_envOrUint("SIM_BASE_INDEX", 0));
            return vm.deriveKey(mnem, uint32(base + idx));
        } catch {
            // Fall back to single key
            return resolveKey();
        }
    }

    function _takeValue(HotPotato game) internal view returns (uint256) {
        uint256 overrideVal = _envOrUint("TAKE_VALUE_OVERRIDE_WEI", type(uint256).max);
        if (overrideVal != type(uint256).max) return overrideVal;
        uint256 price = game.currentEntryPriceWei();
        // If 50th free is expected, allow 0; otherwise pay current price
        return price;
    }
}


