// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/console2.sol";
import {BaseHotPotatoScript} from "script/utils/BaseHotPotatoScript.s.sol";
import {HotPotato} from "src/HotPotato.sol";

contract SettleScript is BaseHotPotatoScript {
    function run() external {
        uint256 pk = resolveKeeperKey();
        HotPotato game = getHotPotato();

        vm.startBroadcast(pk);
        game.settle();
        vm.stopBroadcast();

        console2.log("Settle called by:", vm.addr(pk));
    }
}


