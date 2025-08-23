// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title HotPotato - Simple on-chain Hot Potato game using native token
/// @notice Players pay to take the potato. Keeper settles using next blockhash.
/// On a loss, a portion of the pot is reserved for previous round holders to claim equally.
contract HotPotato {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error InvalidAmount(uint256 providedAmountWei, uint256 expectedAmountWeiOrMinWei);
    error PendingAttemptExists();
    error NoPendingAttempt();
    error TooSoonToSettle();
    error StaleBlockhash();
    error NothingToClaim();
    error AlreadyClaimed();
    error NotEligibleForRound();
    error AlreadyPlayedThisRound(uint256 roundId);
    error MaxParticipantsReached();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event Take(address indexed player, uint256 pricePaid, uint256 targetBlock, uint256 roundId);
    event Settle(address indexed player, bool win, uint256 randomness, uint256 roundId);
    event Claim(address indexed player, uint256 indexed roundId, uint256 amount);
    event NewHolder(address indexed holder, uint256 roundId, uint256 newPrice);
    event RoundEnded(uint256 indexed roundId, uint256 payoutAmount, uint256 numEligible, uint256 potAfter);
    event PotUpdated(uint256 newPot);
    event SponsorUpdated(address indexed sponsor, uint256 amount, string message, uint256 roundId);
    event SponsorReplaced(address indexed previousSponsor, uint256 refundAmount, uint256 roundId);
    event SponsorCleared(uint256 indexed roundId);

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------
    struct PendingAttempt {
        address playerAddress;
        uint256 amountPaidWei;
        uint256 settlementTargetBlockNumber; // next block to derive randomness from
        uint256 createdInRoundId;            // round at time of attempt
        bool exists;
    }

    struct RoundInfo {
        uint256 totalPayoutAmountWei;   // total amount reserved for equal claims by eligible holders
        uint256 totalNumEligibleHolders;    // number of unique holders in that round
        bool isFinalized;         // round has ended via a loss
    }

    struct SponsorInfo {
        address sponsorAddress;
        uint256 sponsoredAmountWei; // amount currently sponsoring this round
        string sponsorMessage;
    }

    // ---------------------------------------------------------------------
    // Storage (immutable configuration)
    // ---------------------------------------------------------------------
    uint256 public immutable baseEntryPriceWei;                 // base price to play (in wei)
    uint256 public immutable priceIncreaseMultiplierBps;        // price multiplier per successful catch (e.g., 12000 = 1.2x)
    // Full pot after fees is distributed on loss (100%)

    // ---------------------------------------------------------------------
    // Storage (mutable game state)
    // ---------------------------------------------------------------------
    uint256 public currentEntryPriceWei;          // current price to play
    address public currentHolderAddress;         // current potato holder (last successful catcher)
    uint256 public currentRoundId;               // incremented when a round ends (on a loss)
    uint256 public potBalanceWei;                // liquid pot available (excludes amounts reserved for claims)
    uint256 public totalReservedForClaimsWei;    // total amount reserved for claims across finalized rounds

    PendingAttempt public pendingAttempt;        // only one pending attempt at a time

    // Eligibility for equal-share claim when a round ends (unique holders per round)
    mapping(uint256 => mapping(address => bool)) public didHoldInRound; // roundId => (player => held?)
    mapping(uint256 => uint256) public uniqueHoldersCountInRound;       // roundId => count of unique holders
    mapping(uint256 => mapping(address => bool)) public hasPlayedInRound; // roundId => (address => played?)
    mapping(uint256 => address[]) public participantsByRound;             // roundId => participants list

    // Claim tracking
    mapping(uint256 => RoundInfo) public roundIdToRoundInfo;                     // roundId => RoundInfo
    mapping(uint256 => mapping(address => bool)) public hasClaimedForRound;     // roundId => (player => claimed?)

    // Sponsor state (per current round)
    SponsorInfo public currentRoundSponsorInfo;
    uint256 public sponsorReservedWei; // reserved portion of pot for potential refund to current sponsor

    // ---------------------------------------------------------------------
    // Reentrancy Guard
    // ---------------------------------------------------------------------
    uint256 private constant REENTRANCY_NOT_ENTERED = 1;
    uint256 private constant REENTRANCY_ENTERED = 2;
    uint256 private reentrancyStatus = REENTRANCY_NOT_ENTERED;
    uint256 private constant KEEPER_REWARD_WEI = 2e16; // 0.02 native token
    uint256 private constant CREATOR_FEE_WEI = 1e17;   // 0.1 native token

    modifier nonReentrant() {
        require(reentrancyStatus != REENTRANCY_ENTERED, "REENTRANCY");
        reentrancyStatus = REENTRANCY_ENTERED;
        _;
        reentrancyStatus = REENTRANCY_NOT_ENTERED;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(
        uint256 baseEntryPriceWei_,
        uint256 priceIncreaseMultiplierBps_,
        address creatorAddress_
    ) {
        require(baseEntryPriceWei_ >= 1e18, "basePrice<1ETH");
        require(priceIncreaseMultiplierBps_ >= 10000, "multiplier<1x");
        require(creatorAddress_ != address(0), "creator=0");

        baseEntryPriceWei = baseEntryPriceWei_;
        priceIncreaseMultiplierBps = priceIncreaseMultiplierBps_;

        currentEntryPriceWei = baseEntryPriceWei_;
        currentRoundId = 1; // start from round 1
        creatorAddress = creatorAddress_;
    }

    // ---------------------------------------------------------------------
    // External/Public Functions
    // ---------------------------------------------------------------------

    /// @notice Pay to take the potato. One pending attempt at a time.
    function take() external payable nonReentrant {
        if (pendingAttempt.exists) revert PendingAttemptExists();
        uint256 participantsCount = participantsByRound[currentRoundId].length;
        if (participantsCount >= 50) revert MaxParticipantsReached();
        bool isFiftiethParticipant = (participantsCount == 49);
        uint256 requiredPaymentWei = isFiftiethParticipant ? 0 : currentEntryPriceWei;
        if (msg.value != requiredPaymentWei) revert InvalidAmount(msg.value, requiredPaymentWei);
        if (hasPlayedInRound[currentRoundId][msg.sender]) revert AlreadyPlayedThisRound(currentRoundId);

        // Register participation
        hasPlayedInRound[currentRoundId][msg.sender] = true;
        participantsByRound[currentRoundId].push(msg.sender);

        // Add payment to the pot immediately if any.
        if (msg.value > 0) {
            potBalanceWei += msg.value;
            emit PotUpdated(potBalanceWei);
        }

        uint256 target = block.number + 1;
        pendingAttempt = PendingAttempt({
            playerAddress: msg.sender,
            amountPaidWei: msg.value,
            settlementTargetBlockNumber: target,
            createdInRoundId: currentRoundId,
            exists: true
        });

        emit Take(msg.sender, msg.value, target, currentRoundId);
    }

    /// @notice Settle the pending attempt using the next blockhash.
    /// Keeper receives a reward equal to 1e17, paid from the pot.
    function settle() external nonReentrant {
        PendingAttempt memory localPendingAttempt = pendingAttempt;
        if (!localPendingAttempt.exists) revert NoPendingAttempt();
        if (block.number < localPendingAttempt.settlementTargetBlockNumber) revert TooSoonToSettle();

        bytes32 settlementBlockhash = blockhash(localPendingAttempt.settlementTargetBlockNumber);
        if (settlementBlockhash == bytes32(0)) revert StaleBlockhash();

        // Pay keeper reward from pot first
        uint256 keeperReward = KEEPER_REWARD_WEI;
        if (keeperReward > 0) {
            uint256 available = _availablePot();
            uint256 payAmount = keeperReward <= available ? keeperReward : available;
            if (payAmount > 0) {
                potBalanceWei -= payAmount;
                (bool ok,) = payable(msg.sender).call{value: payAmount}("");
                require(ok, "keeper pay failed");
            }
        }

        // Random outcome derived from next blockhash, player, and round
        uint256 randomness = uint256(keccak256(abi.encode(settlementBlockhash, localPendingAttempt.playerAddress, localPendingAttempt.createdInRoundId)));
        bool win;
        if (participantsByRound[currentRoundId].length >= 50) {
            win = false; // force loss once 50 participants have joined
        } else {
            // 80% win probability
            win = (randomness % 10) < 8;
        }

        // Clear pending before any external calls after this point
        delete pendingAttempt;

        if (win) {
            _onWin(localPendingAttempt.playerAddress);
            // If this win made the participants reach 50, end the round now
            if (participantsByRound[currentRoundId].length >= 50) {
                _onLose();
            }
        } else {
            _onLose();
        }

        emit Settle(localPendingAttempt.playerAddress, win, randomness, localPendingAttempt.createdInRoundId);
    }

    /// @notice Claim equal-share payout for a finalized round if you were a holder in that round.
    function claim(uint256 roundId) external nonReentrant {
        RoundInfo memory info = roundIdToRoundInfo[roundId];
        if (!info.isFinalized) revert NothingToClaim();
        if (!didHoldInRound[roundId][msg.sender]) revert NotEligibleForRound();
        if (hasClaimedForRound[roundId][msg.sender]) revert AlreadyClaimed();

        uint256 share = info.totalNumEligibleHolders == 0 ? 0 : info.totalPayoutAmountWei / info.totalNumEligibleHolders;
        if (share == 0) revert NothingToClaim();

        hasClaimedForRound[roundId][msg.sender] = true;

        // Pay from reserved claims pool
        require(totalReservedForClaimsWei >= share, "reserve underflow");
        totalReservedForClaimsWei -= share;

        (bool ok,) = payable(msg.sender).call{value: share}("");
        require(ok, "claim transfer failed");

        emit Claim(msg.sender, roundId, share);
    }

    // ---------------------------------------------------------------------
    // Internal logic
    // ---------------------------------------------------------------------
    function _onWin(address player) internal {
        // Update holder set for current round (unique addresses only)
        if (!didHoldInRound[currentRoundId][player]) {
            didHoldInRound[currentRoundId][player] = true;
            uniqueHoldersCountInRound[currentRoundId] += 1;
        }

        currentHolderAddress = player;
        currentEntryPriceWei = _mulDivUp(currentEntryPriceWei, priceIncreaseMultiplierBps, 10000);
        emit NewHolder(player, currentRoundId, currentEntryPriceWei);
        emit PotUpdated(potBalanceWei);
    }

    function _onLose() internal {
        // Pay creator fee first from available pot
        uint256 availableBeforeFees = _availablePot();
        uint256 creatorPay = CREATOR_FEE_WEI <= availableBeforeFees ? CREATOR_FEE_WEI : availableBeforeFees;
        if (creatorPay > 0) {
            potBalanceWei -= creatorPay;
            (bool creatorPaid,) = payable(creatorAddress).call{value: creatorPay}("");
            require(creatorPaid, "creator pay failed");
        }

        // Compute payout pool for participants of the concluding round from remaining pot
        uint256 numEligible = participantsByRound[currentRoundId].length;
        uint256 payoutPool = 0;
        if (numEligible > 0) {
            uint256 availableAfterFees = _availablePot();
            payoutPool = availableAfterFees; // 100% of available after fees
            if (payoutPool > 0) {
                potBalanceWei -= payoutPool;
                uint256 perAddressShare = payoutPool / numEligible;
                if (perAddressShare > 0) {
                    address[] storage participants = participantsByRound[currentRoundId];
                    uint256 participantsLength = participants.length;
                    for (uint256 participantIndex = 0; participantIndex < participantsLength; participantIndex++) {
                        (bool paid,) = payable(participants[participantIndex]).call{value: perAddressShare}("");
                        require(paid, "participant pay failed");
                    }
                }
            }
        }

        // Finalize round
        roundIdToRoundInfo[currentRoundId] = RoundInfo({
            totalPayoutAmountWei: payoutPool,
            totalNumEligibleHolders: numEligible,
            isFinalized: true
        });

        emit RoundEnded(currentRoundId, payoutPool, numEligible, potBalanceWei);
        emit PotUpdated(potBalanceWei);

        // Clear sponsor for the ended round (funds remain in pot; reserved portion is released)
        if (sponsorReservedWei > 0 || currentRoundSponsorInfo.sponsorAddress != address(0)) {
            sponsorReservedWei = 0;
            delete currentRoundSponsorInfo;
            emit SponsorCleared(currentRoundId);
        }

        // Start new round
        currentRoundId += 1;
        currentHolderAddress = address(0);
        currentEntryPriceWei = baseEntryPriceWei;
    }

    // ---------------------------------------------------------------------
    // Creator controls
    // ---------------------------------------------------------------------
    address public creatorAddress;

    modifier onlyCreator() {
        require(msg.sender == creatorAddress, "not-creator");
        _;
    }

    function updateCreatorAddress(address newCreatorAddress) external onlyCreator {
        require(newCreatorAddress != address(0), "creator=0");
        creatorAddress = newCreatorAddress;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------
    function hasPending() external view returns (bool) {
        return pendingAttempt.exists;
    }

    function pendingTargetBlock() external view returns (uint256) {
        return pendingAttempt.settlementTargetBlockNumber;
    }

    /// @notice Returns the currently available pot excluding any sponsor-reserved amount.
    function availablePot() external view returns (uint256) {
        return _availablePot();
    }

    /// @notice Get the active sponsor details for the current round.
    function getSponsor() external view returns (address sponsor, uint256 amount, string memory message) {
        SponsorInfo memory s = currentRoundSponsorInfo;
        return (s.sponsorAddress, s.sponsoredAmountWei, s.sponsorMessage);
    }

    // ---------------------------------------------------------------------
    // Receive / Fallback
    // ---------------------------------------------------------------------
    receive() external payable {
        potBalanceWei += msg.value;
        emit PotUpdated(potBalanceWei);
    }

    fallback() external payable {
        potBalanceWei += msg.value;
        emit PotUpdated(potBalanceWei);
    }

    // ---------------------------------------------------------------------
    // Utils
    // ---------------------------------------------------------------------
    function _mulDivUp(uint256 x, uint256 n, uint256 d) internal pure returns (uint256) {
        // ceil(x * n / d)
        unchecked {
            uint256 prod = x * n;
            // The -1 ensures we round up the division by subtracting 1 from the divisor
            // For example, if prod=10 and d=3:
            // Without -1: 10/3 = 3
            // With -1: (10+3-1)/3 = 12/3 = 4
            return prod == 0 ? 0 : (prod + d - 1) / d;
        }
    }

    function _availablePot() internal view returns (uint256) {
        uint256 p = potBalanceWei;
        uint256 r = sponsorReservedWei;
        return p > r ? (p - r) : 0;
    }

    // ---------------------------------------------------------------------
    // Sponsor logic
    // ---------------------------------------------------------------------
    /// @notice Sponsor the current round's pot with a message. Replaces the previous sponsor if paying
    /// at least 20% more than the previous sponsor amount. The previous sponsor is refunded their amount.
    /// Sponsorship resets (message cleared and reserved released) when a round ends on loss.
    function sponsorPot(string calldata message_) external payable nonReentrant {
        if (msg.value < 1e18) revert InvalidAmount(msg.value, 1e18);

        SponsorInfo memory s = currentRoundSponsorInfo;

        if (s.sponsorAddress == address(0)) {
            // First sponsor in this round
            potBalanceWei += msg.value;
            sponsorReservedWei += msg.value;
            currentRoundSponsorInfo = SponsorInfo({
                sponsorAddress: msg.sender,
                sponsoredAmountWei: msg.value,
                sponsorMessage: message_
            });
            emit PotUpdated(potBalanceWei);
            emit SponsorUpdated(msg.sender, msg.value, message_, currentRoundId);
            return;
        }

        // Must pay at least 20% more than previous amount
        uint256 minNext = _mulDivUp(s.sponsoredAmountWei, 12000, 10000);
        if (msg.value < minNext) revert InvalidAmount(msg.value, minNext);

        // Add new sponsor funds first to ensure liquidity for refund
        potBalanceWei += msg.value;
        sponsorReservedWei += msg.value;
        emit PotUpdated(potBalanceWei);

        // Refund previous sponsor their full amount and release their reserved portion
        sponsorReservedWei -= s.sponsoredAmountWei;
        potBalanceWei -= s.sponsoredAmountWei;
        (bool ok,) = payable(s.sponsorAddress).call{value: s.sponsoredAmountWei}("");
        require(ok, "sponsor refund failed");
        emit SponsorReplaced(s.sponsorAddress, s.sponsoredAmountWei, currentRoundId);

        // Set new sponsor
        currentRoundSponsorInfo = SponsorInfo({
            sponsorAddress: msg.sender,
            sponsoredAmountWei: msg.value,
            sponsorMessage: message_
        });
        emit SponsorUpdated(msg.sender, msg.value, message_, currentRoundId);
    }
}


