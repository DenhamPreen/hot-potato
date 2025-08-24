// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/console2.sol";
import {BaseHotPotatoScript} from "script/utils/BaseHotPotatoScript.s.sol";
import {HotPotato} from "src/HotPotato.sol";

contract SponsorScript is BaseHotPotatoScript {
    function run() external {
        uint256 pk = resolveKey();
        HotPotato game = getHotPotato();

        uint256 amountWei = _envOrUint("SPONSOR_AMOUNT_WEI", 1 ether);
        string memory message = _envOrStr("SPONSOR_MESSAGE", "hot-potato!");

        vm.startBroadcast(pk);
        game.sponsorPot{value: amountWei}(message);
        vm.stopBroadcast();

        console2.log("Sponsor sent:", amountWei);
    }

    function _envOrStr(string memory key, string memory defVal) internal view returns (string memory) {
        try vm.envString(key) returns (string memory s) {
            return s;
        } catch {
            return defVal;
        }
    }
}


