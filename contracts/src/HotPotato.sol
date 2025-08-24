// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

/// @title HotPotato - Simple on-chain Hot Potato game using native token
/// @notice Players pay to take the potato. A keeper (or anyone) settles using the previous
/// blockhash of the executing transaction, two blocks after take() to avoid the previous
/// blockhash being known at submission time. On a loss, the contract attempts to pay an
/// equal share to all participants of the round. Any individual transfer failure is skipped
/// and the loop continues; skipped amounts remain in the pot.
///
/// Randomness manipulability rationale: the outcome uses the previous blockhash at the time of
/// settlement, so a caller can time their submission. However, opposing incentives mitigate
/// manipulation-by-inaction: if the outcome is a loss, other participants are incentivized to
/// settle immediately to receive their share; if the outcome is a win, the current player is
/// incentivized to settle immediately to become holder and increase price. This discourages
/// delaying settlement to influence outcomes via inaction.
contract HotPotato {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error InvalidAmount(uint256 providedAmountWei, uint256 expectedAmountWeiOrMinWei);
    error PendingAttemptExists();
    error NoPendingAttempt();
    error TooSoonToSettle();
    error StaleBlockhash();
    error AlreadyPlayedThisRound(uint256 roundId);
    error MaxParticipantsReached();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event Take(address indexed player, uint256 pricePaid, uint256 targetBlock, uint256 roundId);
    event Settle(address indexed player, bool win, uint256 randomness, uint256 roundId);
    event NewHolder(address indexed holder, uint256 roundId, uint256 newPrice);
    event RoundEnded(uint256 indexed roundId, uint256 payoutAmount, uint256 numEligible, uint256 potAfter);
    event PotUpdated(uint256 newPot);
    event SponsorUpdated(address indexed sponsor, uint256 amount, string message, uint256 roundId);
    event SponsorReplaced(address indexed previousSponsor, uint256 refundAmount, uint256 roundId);
    event SponsorCleared(uint256 indexed roundId);
    event ParticipantPayoutFailed(address indexed participant, uint256 amount, uint256 roundId);
    event SponsorRefundFailed(address indexed previousSponsor, uint256 amount, uint256 roundId);

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------
    struct PendingAttempt {
        address playerAddress;
        uint256 amountPaidWei;
        uint256 settlementTargetBlockNumber; // block when take() happened; settle allowed from (this + 2)
        uint256 createdInRoundId;            // round at time of attempt
        bool exists;
    }

    // (Removed legacy claim-based RoundInfo)

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
    uint256 public potBalanceWei;                // liquid pot available (excludes amounts reserved for sponsor refunds)

    PendingAttempt public pendingAttempt;        // only one pending attempt at a time

    // Participation tracking
    mapping(uint256 => mapping(address => bool)) public hasPlayedInRound; // roundId => (address => played?)
    mapping(uint256 => address[]) public participantsByRound;             // roundId => participants list

    // Sponsor state (per current round)
    SponsorInfo public currentRoundSponsorInfo;
    uint256 public sponsorReservedWei; // reserved portion of pot for potential refund to current sponsor

    // ---------------------------------------------------------------------
    // Reentrancy Guard
    // ---------------------------------------------------------------------
    uint256 private constant REENTRANCY_NOT_ENTERED = 1;
    uint256 private constant REENTRANCY_ENTERED = 2;
    uint256 private reentrancyStatus = REENTRANCY_NOT_ENTERED;
    uint256 public immutable keeperRewardWei; // can be 0 for testing
    uint256 public immutable creatorFeeWei;   // can be 0 for testing
    uint256 private constant MAX_SPONSOR_MESSAGE_LENGTH = 256;

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
        address creatorAddress_,
        uint256 keeperRewardWei_,
        uint256 creatorFeeWei_
    ) {
        require(baseEntryPriceWei_ > 0, "basePrice=0");
        require(priceIncreaseMultiplierBps_ >= 10000, "multiplier<1x");
        require(creatorAddress_ != address(0), "creator=0");

        baseEntryPriceWei = baseEntryPriceWei_;
        priceIncreaseMultiplierBps = priceIncreaseMultiplierBps_;
        keeperRewardWei = keeperRewardWei_;
        creatorFeeWei = creatorFeeWei_;

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
        if (msg.value < requiredPaymentWei) revert InvalidAmount(msg.value, requiredPaymentWei);
        if (hasPlayedInRound[currentRoundId][msg.sender]) revert AlreadyPlayedThisRound(currentRoundId);

        // Register participation
        hasPlayedInRound[currentRoundId][msg.sender] = true;
        participantsByRound[currentRoundId].push(msg.sender);

        // Add payment to the pot immediately if any.
        if (msg.value > 0) {
            potBalanceWei += msg.value;
            emit PotUpdated(potBalanceWei);
        }

        uint256 target = block.number;
        pendingAttempt = PendingAttempt({
            playerAddress: msg.sender,
            amountPaidWei: msg.value,
            settlementTargetBlockNumber: target,
            createdInRoundId: currentRoundId,
            exists: true
        });

        emit Take(msg.sender, msg.value, target, currentRoundId);
    }

    /// @notice Settle the pending attempt using the previous blockhash.
    /// Keeper receives a reward equal to 1e17, paid from the pot.
    function settle() external nonReentrant {
        PendingAttempt memory localPendingAttempt = pendingAttempt;
        if (!localPendingAttempt.exists) revert NoPendingAttempt();
        // require at least 2 blocks since take() so previous blockhash is unknown at tx submission
        if (block.number < (localPendingAttempt.settlementTargetBlockNumber + 2)) revert TooSoonToSettle();

        // use previous blockhash to avoid binding to a single target block and avoid 256-block staleness
        bytes32 settlementBlockhash = blockhash(block.number - 1);
        if (settlementBlockhash == bytes32(0)) revert StaleBlockhash();

        // Pay keeper reward from pot first (non-blocking on failure)
        uint256 keeperReward = keeperRewardWei;
        if (keeperReward > 0) {
            uint256 available = _availablePot();
            uint256 payAmount = keeperReward <= available ? keeperReward : available;
            if (payAmount > 0) {
                (bool ok,) = payable(msg.sender).call{value: payAmount}("");
                if (ok) {
                    potBalanceWei -= payAmount;
                }
            }
        }

        // Random outcome derived from previous blockhash, player, and round
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

    // (Legacy claim function removed; distribution occurs during settle())    

    // ---------------------------------------------------------------------
    // Internal logic
    // ---------------------------------------------------------------------
    function _onWin(address player) internal {
        currentHolderAddress = player;
        currentEntryPriceWei = _mulDivUp(currentEntryPriceWei, priceIncreaseMultiplierBps, 10000);
        emit NewHolder(player, currentRoundId, currentEntryPriceWei);
        emit PotUpdated(potBalanceWei);
    }

    function _onLose() internal {
        // Pay creator fee first from available pot (non-blocking on failure)
        uint256 availableBeforeFees = _availablePot();
        uint256 creatorPay = creatorFeeWei <= availableBeforeFees ? creatorFeeWei : availableBeforeFees;
        if (creatorPay > 0) {
            (bool creatorPaid,) = payable(creatorAddress).call{value: creatorPay}("");
            if (creatorPaid) {
                potBalanceWei -= creatorPay;
            }
        }

        // Compute payout pool for participants based on current contract balance after fees.
        uint256 numEligible = participantsByRound[currentRoundId].length;
        uint256 payoutPool = 0;
        if (numEligible > 0) {
            uint256 balanceAfterFees = address(this).balance;
            if (balanceAfterFees > 0) {
                uint256 perAddressShare = balanceAfterFees / numEligible;
                if (perAddressShare > 0) {
                    uint256 paidTotal = 0;
                    address[] storage participants = participantsByRound[currentRoundId];
                    uint256 participantsLength = participants.length;
                    for (uint256 participantIndex = 0; participantIndex < participantsLength; participantIndex++) {
                        (bool paid,) = payable(participants[participantIndex]).call{value: perAddressShare}("");
                        if (paid) {
                            paidTotal += perAddressShare;
                        } else {
                            emit ParticipantPayoutFailed(participants[participantIndex], perAddressShare, currentRoundId);
                        }
                    }
                    if (paidTotal > 0) {
                        if (potBalanceWei >= paidTotal) {
                            potBalanceWei -= paidTotal;
                        } else {
                            potBalanceWei = 0;
                        }
                    }
                    payoutPool = paidTotal; // actual amount distributed (remainder stays in contract)
                }
            }
        }

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
        // ceil(x * n / d) with overflow guard and cap at type(uint256).max
        unchecked {
            if (x == 0 || n == 0) return 0;
            // Overflow guard: if x > max / n then cap
            uint256 max = type(uint256).max;
            if (x > max / n) {
                return max;
            }
            uint256 prod = x * n;
            uint256 result = (prod + d - 1) / d;
            // Cap in case of round-up overflow (defensive)
            if (result > max) return max;
            return result;
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
        require(bytes(message_).length <= MAX_SPONSOR_MESSAGE_LENGTH, "msg too long");

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

        // Refund previous sponsor their full amount and release their reserved portion (non-blocking)
        sponsorReservedWei -= s.sponsoredAmountWei;
        (bool ok,) = payable(s.sponsorAddress).call{value: s.sponsoredAmountWei}("");
        if (ok) {
            // Align internal accounting only if transfer succeeded
            if (potBalanceWei >= s.sponsoredAmountWei) {
                potBalanceWei -= s.sponsoredAmountWei;
            } else {
                potBalanceWei = 0;
            }
        } else {
            emit SponsorRefundFailed(s.sponsorAddress, s.sponsoredAmountWei, currentRoundId);
        }
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


