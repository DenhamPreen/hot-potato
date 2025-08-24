### Hot Potato Contracts (Foundry)

This folder contains the Solidity contracts and scripts for a simple on-chain "Hot Potato" game using the native token. Players pay to take the potato; a keeper (or anyone) settles each attempt using the previous blockhash of the executing transaction (two blocks after take()). On a loss, the contract pays an equal share to all participants of the round directly during settlement (push payouts with failure skips). On a win, the player becomes the new holder and the entry price increases by 1.2×.

Key properties:

- **Base price**: initial entry price (e.g., 1 MON on Monad testnet)
- **Price multiplier**: 1.2× (configurable via bps)
- **Keeper reward**: constant `0.02` native (2e16 wei) paid from the pot on every settlement

#### Contract

- `src/HotPotato.sol` implements:
  - `take()` — pay current price to attempt taking the potato (one pending at a time)
  - `settle()` — keeper settles using the previous blockhash; pays keeper and distributes per-head equal shares to participants (transfer failures are skipped)
  - Events: `Take`, `Settle`, `NewHolder`, `RoundEnded`, `PotUpdated`, `SponsorUpdated`

Economics summary:

- Every `take()` adds the entry payment to the pot immediately.
- On `settle()`:
  - Keeper is paid a fixed reward from the available pot (non-blocking on failure).
  - If win: player becomes the new holder, next price = ceil(currentPrice × 1.2).
  - If loss: round ends and equal per-head payouts are attempted to all participants of the round. Individual transfer failures are skipped and the loop continues; skipped amounts remain in the pot. Price resets to base and holder clears.

### Prerequisites

- Foundry installed (`forge`, `cast`): see `https://book.getfoundry.sh/getting-started/installation`

### Setup

```bash
cd contracts
forge install foundry-rs/forge-std
cp .env.example .env
# Edit .env with your Monad testnet RPC and private key
```

### Build

```bash
forge build
```

### Test

```bash
forge test -vvv
```

### Deploy (Monad testnet)

Configure `foundry.toml` and `.env`:

- `foundry.toml` defines rpc endpoint alias `monad_testnet = ${MONAD_RPC_URL}`
- `.env` should define `MONAD_RPC_URL` and `MONAD_PRIVATE_KEY`

Run deployment script:

```bash
forge script script/DeployHotPotato.s.sol \
  --rpc-url monad_testnet \
  --broadcast \
  --verify --verifier none \
  -vvvv
```

Environment variables (with defaults):

- `BASE_PRICE_WEI` (default `1e18`)
- `MULTIPLIER_BPS` (default `12000` = 1.2×)
- `PAYOUT_BPS` (default `5000` = 50%)
  (Keeper reward is fixed; no env var)

### Notes

- Settlement requires calling `settle()` after the target block is mined and within 256 blocks (blockhash availability window). This is ideal for an Envio HyperIndex keeper to automate.
- Randomness uses the previous blockhash at settlement. While callers can time submission, opposing incentives mitigate manipulation-by-inaction: losers want to settle quickly to receive payouts; winners want to settle quickly to lock in holder status and price increase.
- All accounting guards against reentrancy, and transfers use `call`.

### Further work

- Could make the win / lose probability a function of the sponsored pot balance. Ie the larger the sponsored pot, the higher the lose probability.
