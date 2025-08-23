// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {HotPotato} from "../src/HotPotato.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract HotPotatoTest is Test {
    using stdStorage for StdStorage;
    HotPotato internal game;
    address internal deployer;
    address internal creator;
    address internal keeper;

    uint256 internal constant BASE_PRICE = 1 ether;
    uint256 internal constant MULT_BPS = 12000; // 1.2x
    uint256 internal constant PAYOUT_BPS = 5000; // 50%

    function setUp() public {
        deployer = makeAddr("deployer");
        creator = makeAddr("creator");
        keeper = makeAddr("keeper");
        vm.deal(deployer, 1000 ether);
        vm.deal(creator, 0);
        vm.deal(keeper, 0);

        vm.prank(deployer);
        game = new HotPotato(BASE_PRICE, MULT_BPS, PAYOUT_BPS, creator);

        // Seed contract pot without triggering receive()
        vm.deal(address(game), 10 ether);
    }

    // ------------------------------ Helpers ------------------------------
    function _clearPendingExists() internal {
        // Use stdstore to locate the storage slot used by hasPending() and zero it
        uint256 slot = stdstore.target(address(game)).sig("hasPending()").find();
        vm.store(address(game), bytes32(slot), bytes32(uint256(0)));
    }

    function _addParticipantWithoutSettling(address player, uint256 index) internal {
        vm.deal(player, 10 ether);
        vm.prank(player);
        uint256 valueToSend = (index == 49) ? 0 : BASE_PRICE;
        game.take{value: valueToSend}();
        _clearPendingExists();
    }

    // ---------------------------- Constructor ----------------------------
    function testConstructorInitialState() public {
        assertEq(game.baseEntryPriceWei(), BASE_PRICE);
        assertEq(game.priceIncreaseMultiplierBps(), MULT_BPS);
        assertEq(game.roundLossPayoutPercentBps(), PAYOUT_BPS);
        assertEq(game.currentEntryPriceWei(), BASE_PRICE);
        assertEq(game.currentRoundId(), 1);
        assertEq(game.creatorAddress(), creator);
    }

    function testConstructorRevertsOnBadParams() public {
        vm.expectRevert(bytes("basePrice<1ETH"));
        new HotPotato(0.5 ether, MULT_BPS, PAYOUT_BPS, creator);

        vm.expectRevert(bytes("multiplier<1x"));
        new HotPotato(BASE_PRICE, 9999, PAYOUT_BPS, creator);

        vm.expectRevert(bytes("payout>100%"));
        new HotPotato(BASE_PRICE, MULT_BPS, 10001, creator);

        vm.expectRevert(bytes("creator=0"));
        new HotPotato(BASE_PRICE, MULT_BPS, PAYOUT_BPS, address(0));
    }

    // ------------------------------- take() ------------------------------
    function testTakeSuccessSetsPendingAndPotAndParticipant() public {
        address player = makeAddr("player1");
        vm.deal(player, 10 ether);

        vm.prank(player);
        game.take{value: BASE_PRICE}();

        // pending attempt exists
        assertTrue(game.hasPending());

        // available pot increased by BASE_PRICE (seeded pot not counted in accounting)
        assertEq(game.availablePot(), BASE_PRICE);

        // clear pending (simulate post-settlement but same round)
        _clearPendingExists();
        // now same player trying again should revert due to single-play restriction
        vm.expectRevert(abi.encodeWithSelector(HotPotato.AlreadyPlayedThisRound.selector, game.currentRoundId()));
        vm.prank(player);
        game.take{value: BASE_PRICE}();
    }

    function testTakeRevertsIfPendingExists() public {
        address p1 = makeAddr("p1");
        address p2 = makeAddr("p2");
        vm.deal(p1, 10 ether);
        vm.deal(p2, 10 ether);

        vm.prank(p1);
        game.take{value: BASE_PRICE}();

        vm.expectRevert(HotPotato.PendingAttemptExists.selector);
        vm.prank(p2);
        game.take{value: BASE_PRICE}();
    }

    function testTakeRevertsIfWrongAmount() public {
        address p = makeAddr("p");
        vm.deal(p, 10 ether);

        vm.expectRevert(abi.encodeWithSelector(HotPotato.InvalidAmount.selector, BASE_PRICE - 1, BASE_PRICE));
        vm.prank(p);
        game.take{value: BASE_PRICE - 1}();
    }

    function testTakeRevertsAtMaxParticipants() public {
        // Fill to 50 participants by clearing pending between takes
        for (uint256 i = 0; i < 50; i++) {
            _addParticipantWithoutSettling(makeAddr(string(abi.encodePacked("u", i))), i);
        }
        // Now with 50 participants, new takes should revert
        address p = makeAddr("p");
        vm.deal(p, 10 ether);
        vm.expectRevert(HotPotato.MaxParticipantsReached.selector);
        vm.prank(p);
        game.take{value: BASE_PRICE}();
    }

    // ------------------------------ settle() -----------------------------
    function testSettleTooSoonReverts() public {
        address p = makeAddr("p");
        vm.deal(p, 10 ether);
        vm.prank(p);
        game.take{value: BASE_PRICE}();

        // target is current+1, still too soon
        vm.expectRevert(HotPotato.TooSoonToSettle.selector);
        vm.prank(keeper);
        game.settle();
    }

    function testSettlePaysKeeperReward() public {
        address p = makeAddr("p");
        vm.deal(p, 10 ether);
        vm.prank(p);
        game.take{value: BASE_PRICE}();

        uint256 keeperBalBefore = keeper.balance;

        // mine the next block and one more to ensure settlement
        vm.roll(block.number + 2);

        vm.prank(keeper);
        game.settle();

        // Keeper should receive 2e16 (or less if pot insufficient)
        assertEq(keeper.balance - keeperBalBefore, 2e16);
    }

    function testSettleWinOrLoseTransitions() public {
        address p = makeAddr("p");
        vm.deal(p, 10 ether);
        vm.prank(p);
        game.take{value: BASE_PRICE}();

        uint256 roundBefore = game.currentRoundId();
        uint256 priceBefore = game.currentEntryPriceWei();

        vm.roll(block.number + 2);
        vm.prank(keeper);
        game.settle();

        // Either win: price increased and same round; or loss: round advanced and price reset
        uint256 roundAfter = game.currentRoundId();
        uint256 priceAfter = game.currentEntryPriceWei();

        bool won = (roundAfter == roundBefore && priceAfter > priceBefore);
        bool lost = (roundAfter == roundBefore + 1 && priceAfter == game.baseEntryPriceWei());
        assertTrue(won || lost);
    }

    // -------- Forced loss at 50 participants and distribution ----------
    function testForcedLossAt50ParticipantsDistributesAndResets() public {
        // Fill to 49 participants (clearing pending) then add 50th to create pending and settle
        for (uint256 i = 0; i < 49; i++) {
            _addParticipantWithoutSettling(makeAddr(string(abi.encodePacked("u", i))), i);
        }
        address p50 = makeAddr("u50");
        vm.deal(p50, 10 ether);
        // 50th participant should not pay base fee
        vm.prank(p50);
        game.take{value: 0}();

        // Mine next block and settle (should force loss at 50)
        vm.roll(block.number + 2);
        uint256 creatorBalBefore = creator.balance;
        vm.prank(keeper);
        game.settle();

        // Round should have advanced and price reset
        assertEq(game.currentRoundId(), 2);
        assertEq(game.currentEntryPriceWei(), game.baseEntryPriceWei());

        // Creator should be paid (up to 1e17)
        assertTrue(creator.balance > creatorBalBefore);
    }

    // ---------------------------- Sponsor Logic --------------------------
    function testSponsorFirstAndReplaceAndClearOnLoss() public {
        address s1 = makeAddr("s1");
        address s2 = makeAddr("s2");
        vm.deal(s1, 10 ether);
        vm.deal(s2, 10 ether);

        // First sponsor
        vm.prank(s1);
        game.sponsorPot{value: 1 ether}("hello");
        (address spAddr, uint256 amt, string memory msg1) = game.getSponsor();
        assertEq(spAddr, s1);
        assertEq(amt, 1 ether);
        assertEq(keccak256(bytes(msg1)), keccak256("hello"));

        // Replace requires >= 1.2x
        vm.expectRevert(abi.encodeWithSelector(HotPotato.InvalidAmount.selector, 1.19 ether, 1.2 ether));
        vm.prank(s2);
        game.sponsorPot{value: 1.19 ether}("nope");

        // Replace works
        vm.prank(s2);
        game.sponsorPot{value: 1.2 ether}("new");
        (spAddr, amt, ) = game.getSponsor();
        assertEq(spAddr, s2);
        assertEq(amt, 1.2 ether);

        // Force loss by building up to 50 participants and then settling
        for (uint256 i = 0; i < 49; i++) {
            _addParticipantWithoutSettling(makeAddr(string(abi.encodePacked("s", i))), i);
        }
        address px = makeAddr("px");
        vm.deal(px, 10 ether);
        // 50th participant should not pay base fee
        vm.prank(px);
        game.take{value: 0}();
        vm.roll(block.number + 2);
        vm.prank(keeper);
        game.settle();

        // sponsor cleared
        (spAddr, amt, ) = game.getSponsor();
        assertEq(spAddr, address(0));
        assertEq(amt, 0);
    }

    // ---------------------------- Creator controls -----------------------
    function testOnlyCreatorCanUpdate() public {
        address newCreator = makeAddr("newCreator");
        vm.prank(deployer);
        vm.expectRevert(bytes("not-creator"));
        game.updateCreatorAddress(newCreator);

        vm.prank(creator);
        game.updateCreatorAddress(newCreator);
        assertEq(game.creatorAddress(), newCreator);
    }

    // ------------------------------ Misc Views ---------------------------
    function testAvailablePotExcludesSponsorReserved() public {
        address s1 = makeAddr("s1");
        vm.deal(s1, 10 ether);
        uint256 before = game.availablePot();
        vm.prank(s1);
        game.sponsorPot{value: 2 ether}("msg");
        uint256 afterPot = game.availablePot();
        // available pot excludes sponsorReserved; should remain unchanged
        assertEq(afterPot, before);
    }

    function testReceiveAndFallbackIncreasePot() public {
        uint256 before = game.availablePot();
        // receive()
        (bool ok1,) = address(game).call{value: 0.5 ether}("");
        require(ok1, "recv call failed");
        // fallback() by sending non-empty calldata
        (bool ok2,) = address(game).call{value: 0.25 ether}(bytes("x"));
        require(ok2, "fallback call failed");
        assertEq(game.availablePot(), before + 0.75 ether);
    }

    function testPendingTargetBlockGetter() public {
        address p = makeAddr("p");
        vm.deal(p, 10 ether);
        vm.prank(p);
        game.take{value: BASE_PRICE}();
        uint256 tgt = game.pendingTargetBlock();
        assertEq(tgt, block.number + 1);
    }
}


