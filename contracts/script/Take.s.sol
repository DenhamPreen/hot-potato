// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/console2.sol";
import {BaseHotPotatoScript} from "script/utils/BaseHotPotatoScript.s.sol";
import {HotPotato} from "src/HotPotato.sol";

contract TakeScript is BaseHotPotatoScript {
    function run() external {
        uint256 pk = resolveKey();
        HotPotato game = getHotPotato();

        uint256 valueToSend = _envOrUint("TAKE_VALUE_WEI", game.currentEntryPriceWei());
        vm.startBroadcast(pk);
        game.take{value: valueToSend}();
        vm.stopBroadcast();

        console2.log("Take sent with value:", valueToSend);
    }
}


