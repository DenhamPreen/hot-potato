/* HyperIndex handlers for HotPotato */
import { HotPotato } from "generated";

const KEEPER_REWARD_WEI = 20000000000000000n; // 2e16
const CREATOR_FEE_WEI = 100000000000000000n; // 1e17

function idOf(e: any) {
  return `${e.chainId}_${e.block.number}_${e.logIndex}`;
}

function contractId(e: any) {
  return e.srcAddress.toLowerCase();
}

async function getOrCreateContract(event: any, context: any) {
  const id = contractId(event);
  let c = await context.Contract.get(id);
  if (!c) {
    c = {
      id,
      address: id,
      chain_id: BigInt(event.chainId),
      created_at: BigInt(event.block.timestamp),
      created_tx_hash: event.transaction.hash.toLowerCase(),
      base_entry_price_wei: 0n,
      price_increase_multiplier_bps: 0n,
      round_loss_payout_percent_bps: 0n,
      keeper_reward_wei: BigInt(KEEPER_REWARD_WEI),
      creator_fee_wei: BigInt(CREATOR_FEE_WEI),
      creator_address: "0x0000000000000000000000000000000000000000",
      current_round_id: 1n,
      current_entry_price_wei: 0n,
      current_pot_wei: 0n,
      total_rounds: 0n,
      total_takes: 0n,
      total_settlements: 0n,
      total_claims: 0n,
      total_sponsors: 0n,
    };
    context.Contract.set(c);
  }
  return c;
}

async function getOrCreatePlayer(address: string, context: any) {
  const id = address.toLowerCase();
  let p = await context.Player.get(id);
  if (!p) {
    p = {
      id,
      address: id,
      total_plays: 0n,
      total_wins: 0n,
      total_losses: 0n,
      total_paid_wei: 0n,
      total_received_wei: 0n,
      first_active_at: undefined,
      last_active_at: undefined,
    };
    context.Player.set(p);
  }
  return p;
}

async function getOrCreateRound(contract_id: string, roundNumber: bigint, event: any, context: any) {
  const id = `${contract_id}-${roundNumber.toString()}`;
  let r = await context.Round.get(id);
  if (!r) {
    r = {
      id,
      contract_id,
      round_number: roundNumber,
      status: "ACTIVE",
      started_at: BigInt(event.block.timestamp),
      started_block: BigInt(event.block.number),
      ended_at: undefined,
      ended_block: undefined,
      num_participants: 0n,
      payout_pool_wei: 0n,
      per_share_wei: 0n,
      keeper_paid_wei: 0n,
      creator_paid_wei: 0n,
      pot_before_wei: 0n,
      pot_after_wei: 0n,
    };
    context.Round.set(r);
  }
  return r;
}

HotPotato.Take.handler(async ({ event, context }) => {
  const c = await getOrCreateContract(event, context);
  const contract_id = c.id;
  const roundNumber = BigInt(event.params.roundId.toString());
  let r = await getOrCreateRound(contract_id, roundNumber, event, context);

  const playerAddr = event.params.player.toLowerCase();
  let p = await getOrCreatePlayer(playerAddr, context);

  // Update player
  p = { ...p, total_plays: p.total_plays + 1n, total_paid_wei: p.total_paid_wei + BigInt(event.params.pricePaid.toString()), last_active_at: BigInt(event.block.timestamp), first_active_at: p.first_active_at ?? BigInt(event.block.timestamp) };
  context.Player.set(p);

  // Update round participants count
  r = { ...r, num_participants: r.num_participants + 1n };
  context.Round.set(r);

  // Round participation
  const rpId = `${r.id}-${playerAddr}`;
  context.RoundParticipation.set({
    id: rpId,
    contract_id,
    round_id: r.id,
    player_id: p.id,
    amount_paid_wei: BigInt(event.params.pricePaid.toString()),
    is_fiftieth_free: BigInt(event.params.pricePaid.toString()) === 0n,
    tx_hash: event.transaction.hash.toLowerCase(),
    block_number: BigInt(event.block.number),
    timestamp: BigInt(event.block.timestamp),
  });

  // Activity
  context.TakeActivity.set({
    id: idOf(event),
    type_: "TAKE",
    contract_id,
    round_id: r.id,
    tx_hash: event.transaction.hash.toLowerCase(),
    block_number: BigInt(event.block.number),
    timestamp: BigInt(event.block.timestamp),
    player_id: p.id,
    price_paid_wei: BigInt(event.params.pricePaid.toString()),
    target_block: BigInt(event.params.targetBlock.toString()),
  });

  // Update contract aggregates
  context.Contract.set({ ...c, total_takes: c.total_takes + 1n });
});

HotPotato.Settle.handler(async ({ event, context }) => {
  const c = await getOrCreateContract(event, context);
  const contract_id = c.id;
  const roundNumber = BigInt(event.params.roundId.toString());
  const r = await getOrCreateRound(contract_id, roundNumber, event, context);
  const playerAddr = event.params.player.toLowerCase();
  let p = await getOrCreatePlayer(playerAddr, context);

  // Update win/loss
  p = {
    ...p,
    total_wins: event.params.win ? p.total_wins + 1n : p.total_wins,
    total_losses: event.params.win ? p.total_losses : p.total_losses + 1n,
    last_active_at: BigInt(event.block.timestamp),
  };
  context.Player.set(p);

  // Settlement entity
  context.Settlement.set({
    id: idOf(event),
    contract_id,
    round_id: r.id,
    player_id: p.id,
    win: Boolean(event.params.win),
    randomness: BigInt(event.params.randomness.toString()),
    keeper_paid_wei: KEEPER_REWARD_WEI,
    creator_paid_wei: 0n,
    payout_pool_wei: 0n,
    per_share_wei: 0n,
    pot_after_wei: 0n,
    tx_hash: event.transaction.hash.toLowerCase(),
    block_number: BigInt(event.block.number),
    timestamp: BigInt(event.block.timestamp),
  });

  // Activity
  context.SettleActivity.set({
    id: `${idOf(event)}_act`,
    type_: "SETTLE",
    contract_id,
    round_id: r.id,
    tx_hash: event.transaction.hash.toLowerCase(),
    block_number: BigInt(event.block.number),
    timestamp: BigInt(event.block.timestamp),
    player_id: p.id,
    win: Boolean(event.params.win),
    randomness: BigInt(event.params.randomness.toString()),
    keeper_paid_wei: KEEPER_REWARD_WEI,
  });

  context.Contract.set({ ...c, total_settlements: c.total_settlements + 1n });
});

HotPotato.RoundEnded.handler(async ({ event, context }) => {
  const c = await getOrCreateContract(event, context);
  const contract_id = c.id;
  const roundNumber = BigInt(event.params.roundId.toString());
  let r = await getOrCreateRound(contract_id, roundNumber, event, context);

  const payout = BigInt(event.params.payoutAmount.toString());
  const potAfter = BigInt(event.params.potAfter.toString());
  const creatorPay = CREATOR_FEE_WEI; // approximate; capped in contract but not emitted
  const potBefore = potAfter + payout + creatorPay;

  r = {
    ...r,
    status: "FINALIZED",
    ended_at: BigInt(event.block.timestamp),
    ended_block: BigInt(event.block.number),
    payout_pool_wei: payout,
    per_share_wei: event.params.numEligible > 0n ? payout / BigInt(event.params.numEligible.toString()) : 0n,
    keeper_paid_wei: KEEPER_REWARD_WEI,
    creator_paid_wei: creatorPay,
    pot_before_wei: potBefore,
    pot_after_wei: potAfter,
  };
  context.Round.set(r);

  // Activity
  context.RoundEndedActivity.set({
    id: idOf(event),
    type_: "ROUND_ENDED",
    contract_id,
    round_id: r.id,
    tx_hash: event.transaction.hash.toLowerCase(),
    block_number: BigInt(event.block.number),
    timestamp: BigInt(event.block.timestamp),
    payout_amount_wei: payout,
    num_eligible: BigInt(event.params.numEligible.toString()),
    pot_after_wei: potAfter,
  });

  // Increment totals
  context.Contract.set({ ...c, total_rounds: c.total_rounds + 1n });
});

HotPotato.Claim.handler(async ({ event, context }) => {
  const c = await getOrCreateContract(event, context);
  const contract_id = c.id;
  const roundNumber = BigInt(event.params.roundId.toString());
  const r = await getOrCreateRound(contract_id, roundNumber, event, context);
  const player = await getOrCreatePlayer(event.params.player.toLowerCase(), context);

  // Claim entity
  context.Claim.set({
    id: idOf(event),
    contract_id,
    round_id: r.id,
    player_id: player.id,
    amount_wei: BigInt(event.params.amount.toString()),
    tx_hash: event.transaction.hash.toLowerCase(),
    block_number: BigInt(event.block.number),
    timestamp: BigInt(event.block.timestamp),
  });

  // Update player received
  context.Player.set({ ...player, total_received_wei: player.total_received_wei + BigInt(event.params.amount.toString()) });

  // Activity
  context.ClaimActivity.set({
    id: `${idOf(event)}_act`,
    type_: "CLAIM",
    contract_id,
    round_id: r.id,
    tx_hash: event.transaction.hash.toLowerCase(),
    block_number: BigInt(event.block.number),
    timestamp: BigInt(event.block.timestamp),
    player_id: player.id,
    amount_wei: BigInt(event.params.amount.toString()),
  });

  context.Contract.set({ ...c, total_claims: c.total_claims + 1n });
});

HotPotato.NewHolder.handler(async ({ event, context }) => {
  const c = await getOrCreateContract(event, context);
  const contract_id = c.id;
  const roundNumber = BigInt(event.params.roundId.toString());
  const r = await getOrCreateRound(contract_id, roundNumber, event, context);
  const holder = await getOrCreatePlayer(event.params.holder.toLowerCase(), context);

  context.NewHolderActivity.set({
    id: idOf(event),
    type_: "NEW_HOLDER",
    contract_id,
    round_id: r.id,
    tx_hash: event.transaction.hash.toLowerCase(),
    block_number: BigInt(event.block.number),
    timestamp: BigInt(event.block.timestamp),
    holder_id: holder.id,
    new_price_wei: BigInt(event.params.newPrice.toString()),
  });
});

HotPotato.PotUpdated.handler(async ({ event, context }) => {
  const c = await getOrCreateContract(event, context);
  const contract_id = c.id;

  context.Contract.set({ ...c, current_pot_wei: BigInt(event.params.newPot.toString()) });

  context.PotUpdatedActivity.set({
    id: idOf(event),
    type_: "POT_UPDATED",
    contract_id,
    round_id: undefined,
    tx_hash: event.transaction.hash.toLowerCase(),
    block_number: BigInt(event.block.number),
    timestamp: BigInt(event.block.timestamp),
    new_pot_wei: BigInt(event.params.newPot.toString()),
  });
});

HotPotato.SponsorUpdated.handler(async ({ event, context }) => {
  const c = await getOrCreateContract(event, context);
  const contract_id = c.id;
  const roundNumber = BigInt(event.params.roundId.toString());
  const r = await getOrCreateRound(contract_id, roundNumber, event, context);
  const sponsor = await getOrCreatePlayer(event.params.sponsor.toLowerCase(), context);

  // Sponsor entity instance (mark active)
  context.Sponsor.set({
    id: idOf(event),
    contract_id,
    round_id: r.id,
    sponsor_id: sponsor.id,
    amount_wei: BigInt(event.params.amount.toString()),
    message: event.params.message,
    active: true,
    was_replaced: false,
    refund_wei: 0n,
    created_tx_hash: event.transaction.hash.toLowerCase(),
    created_at: BigInt(event.block.timestamp),
  });

  // Activity
  context.SponsorUpdatedActivity.set({
    id: `${idOf(event)}_act`,
    type_: "SPONSOR_UPDATED",
    contract_id,
    round_id: r.id,
    tx_hash: event.transaction.hash.toLowerCase(),
    block_number: BigInt(event.block.number),
    timestamp: BigInt(event.block.timestamp),
    sponsor_id: sponsor.id,
    amount_wei: BigInt(event.params.amount.toString()),
    message: event.params.message,
  });

  context.Contract.set({ ...c, total_sponsors: c.total_sponsors + 1n });
});

HotPotato.SponsorReplaced.handler(async ({ event, context }) => {
  const c = await getOrCreateContract(event, context);
  const contract_id = c.id;
  const roundNumber = BigInt(event.params.roundId.toString());
  const r = await getOrCreateRound(contract_id, roundNumber, event, context);
  const previous = await getOrCreatePlayer(event.params.previousSponsor.toLowerCase(), context);

  context.SponsorReplacedActivity.set({
    id: idOf(event),
    type_: "SPONSOR_REPLACED",
    contract_id,
    round_id: r.id,
    tx_hash: event.transaction.hash.toLowerCase(),
    block_number: BigInt(event.block.number),
    timestamp: BigInt(event.block.timestamp),
    previous_sponsor_id: previous.id,
    refund_wei: BigInt(event.params.refundAmount.toString()),
  });
});

HotPotato.SponsorCleared.handler(async ({ event, context }) => {
  const c = await getOrCreateContract(event, context);
  const contract_id = c.id;
  const roundNumber = BigInt(event.params.roundId.toString());
  const r = await getOrCreateRound(contract_id, roundNumber, event, context);

  context.SponsorClearedActivity.set({
    id: idOf(event),
    type_: "SPONSOR_CLEARED",
    contract_id,
    round_id: r.id,
    tx_hash: event.transaction.hash.toLowerCase(),
    block_number: BigInt(event.block.number),
    timestamp: BigInt(event.block.timestamp),
  });
});
