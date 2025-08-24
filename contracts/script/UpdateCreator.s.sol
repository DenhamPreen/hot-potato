// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/console2.sol";
import {BaseHotPotatoScript} from "script/utils/BaseHotPotatoScript.s.sol";
import {HotPotato} from "src/HotPotato.sol";

contract UpdateCreatorScript is BaseHotPotatoScript {
    function run() external {
        uint256 pk = resolveKey();
        HotPotato game = getHotPotato();

        address newCreator = vm.envAddress("NEW_CREATOR_ADDRESS");

        vm.startBroadcast(pk);
        game.updateCreatorAddress(newCreator);
        vm.stopBroadcast();

        console2.log("Creator updated to:", newCreator);
    }
}


