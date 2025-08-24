// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Script.sol";
import {HotPotato} from "src/HotPotato.sol";

abstract contract BaseHotPotatoScript is Script {
    function resolveKey() internal view returns (uint256) {
        try vm.envString("MNEMONIC") returns (string memory mnem) {
            uint32 index = uint32(_envOrUint("MNEMONIC_INDEX", 0));
            uint256 derivedKey = vm.deriveKey(mnem, index);
            vm.addr(derivedKey); // silence unused
            return derivedKey;
        } catch {
            return vm.envUint("MONAD_PRIVATE_KEY");
        }
    }

    function resolveKeeperKey() internal view returns (uint256) {
        try vm.envString("MNEMONIC") returns (string memory mnem) {
            uint32 index = uint32(_envOrUint("KEEPER_INDEX", 1));
            uint256 derivedKey = vm.deriveKey(mnem, index);
            vm.addr(derivedKey);
            return derivedKey;
        } catch {
            uint256 pk = vm.envOr("KEEPER_PRIVATE_KEY", uint256(0));
            return pk == 0 ? resolveKey() : pk;
        }
    }

    function getHotPotato() internal view returns (HotPotato) {
        address contractAddr = vm.envAddress("CONTRACT_ADDRESS");
        return HotPotato(payable(contractAddr));
    }

    function _envOrUint(string memory key, uint256 defaultValue) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return defaultValue;
        }
    }
}


