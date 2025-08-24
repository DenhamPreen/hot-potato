// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/console2.sol";
import {BaseHotPotatoScript} from "script/utils/BaseHotPotatoScript.s.sol";
import {HotPotato} from "src/HotPotato.sol";

contract ClaimScript is BaseHotPotatoScript {
    function run() external {
        uint256 pk = resolveKey();
        HotPotato game = getHotPotato();

        uint256 roundId = _envOrUint("CLAIM_ROUND_ID", 1);

        vm.startBroadcast(pk);
        game.claim(roundId);
        vm.stopBroadcast();

        console2.log("Claimed round:", roundId);
    }
}


