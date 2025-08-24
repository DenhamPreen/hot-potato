// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {HotPotato} from "../src/HotPotato.sol";

contract HotPotatoIntegrationTest is Test {
    using stdStorage for StdStorage;

    HotPotato internal game;
    address internal creator;
    address internal keeper;

    uint256 internal constant BASE_PRICE = 1 ether;
    uint256 internal constant MULT_BPS = 12000; // 1.2x
    uint256 internal constant KEEPER_REWARD = 2e16; // from contract
    uint256 internal constant CREATOR_FEE = 1e17;   // from contract

    function setUp() public {
        address deployer = makeAddr("deployer");
        creator = makeAddr("creator");
        keeper = makeAddr("keeper");
        vm.deal(deployer, 1000 ether);
        vm.deal(creator, 0);
        vm.deal(keeper, 0);

        vm.prank(deployer);
        game = new HotPotato(BASE_PRICE, MULT_BPS, creator, KEEPER_REWARD, CREATOR_FEE);
    }

    function _clearPending() internal {
        uint256 slot = stdstore.target(address(game)).sig("hasPending()").find();
        vm.store(address(game), bytes32(slot), bytes32(uint256(0)));
    }

    /// @notice End-to-end full round: 49 paid entries + 50th free triggers forced loss and distributions
    function testFullRoundForcedLossAndDistribution() public {
        uint256 roundId = game.currentRoundId();

        // Create 49 paid participants
        address[] memory participants = new address[](50);
        for (uint256 i = 0; i < 49; i++) {
            address player = makeAddr(string(abi.encodePacked("p", i)));
            participants[i] = player;
            vm.deal(player, 10 ether);
            vm.prank(player);
            game.take{value: BASE_PRICE}();
            _clearPending();
        }

        // Pot should be 49 ether before settlement
        assertEq(game.availablePot(), 49 ether);

        // 50th participant joins for free
        address p50 = makeAddr("p49");
        participants[49] = p50;
        vm.deal(p50, 10 ether);
        vm.prank(p50);
        game.take{value: 0}();

        // Record balances before settlement
        uint256 creatorBalBefore = creator.balance;
        uint256[50] memory balancesBefore;
        for (uint256 j = 0; j < 50; j++) {
            balancesBefore[j] = participants[j].balance;
        }

        // Mine next block and settle via keeper
        vm.roll(block.number + 2);
        uint256 keeperBalBefore = keeper.balance;
        vm.prank(keeper);
        game.settle();

        // Keeper should be paid
        assertEq(keeper.balance - keeperBalBefore, KEEPER_REWARD);

        // Round should advance and price reset
        assertEq(game.currentRoundId(), roundId + 1);
        assertEq(game.currentEntryPriceWei(), game.baseEntryPriceWei());

        // Compute expected distributions
        // Start with 49 ether; keeper paid first
        uint256 potAfterKeeper = 49 ether > KEEPER_REWARD ? (49 ether - KEEPER_REWARD) : 0;
        uint256 creatorPay = potAfterKeeper > 0 ? (CREATOR_FEE <= potAfterKeeper ? CREATOR_FEE : potAfterKeeper) : 0;
        uint256 potAfterCreator = potAfterKeeper - creatorPay;
        uint256 payoutPool = potAfterCreator; // 100% distributed after fees
        uint256 perShare = payoutPool / 50;

        // Creator should be paid
        assertEq(creator.balance - creatorBalBefore, creatorPay);

        // Each participant should have received perShare
        for (uint256 j2 = 0; j2 < 50; j2++) {
            assertEq(participants[j2].balance - balancesBefore[j2], perShare);
        }

        // Remaining pot should be what's left after payout
        uint256 expectedRemaining = potAfterCreator - payoutPool;
        assertEq(game.availablePot(), expectedRemaining);
    }
}


