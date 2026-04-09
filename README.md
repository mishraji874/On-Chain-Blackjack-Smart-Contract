# On-Chain Blackjack (Foundry)

A minimal, well-tested on-chain implementation of Blackjack (21) written in Solidity and built with Foundry.  
This repository implements the game logic, payout rules, timeout handling, and a small deploy script and test suite using Foundry's `forge` tooling and `forge-std` utilities.

This README explains the project structure, design, how to build/test locally, and how to deploy and interact with the contract.

---

## Table of contents

- [Highlights](#highlights)
- [Contracts and important symbols](#contracts-and-important-symbols)
- [Game flow & rules](#game-flow--rules)
- [Repository layout](#repository-layout)
- [Requirements](#requirements)
- [Setup and quick start](#setup-and-quick-start)
- [Building, formatting & snapshots](#building-formatting--snapshots)
- [Running tests](#running-tests)
- [Deploying](#deploying)
- [Interacting with a deployed contract](#interacting-with-a-deployed-contract)
- [Security considerations](#security-considerations)
- [Contributing](#contributing)
- [License & contact](#license--contact)

---

## Highlights

- Fully on-chain Blackjack game with deterministic card drawing controlled by contract state.
- Well-covered unit tests and fuzz tests using Foundry (`forge`).
- Timeout handling to let anyone finalize stalled games.
- Owner-managed house bankroll with owner withdrawal function.
- Uses `forge-std` for testing utilities.

---

## Contracts and important symbols

Main contract:
- `src/OnChainBlackjack.sol`

Key data structures / enums:
- `GameState` — tracks game lifecycle (e.g., PlayerTurn, DealerTurn, Finished).
- `GameResult` — final result (`PlayerWin`, `DealerWin`, `Push`, `None`).
- `Card` — internal representation of a playing card.
- `Game` — struct containing bet, players' hands, dealer hand, last action block, state, result, etc.

Important external-facing functions:
- `startGame` — starts a game; pay the bet using `msg.value`.
- `hit` — player requests a new card.
- `stand` — player stands and triggers dealer play resolution.
- `dealerNextMove` — advances the dealer's play (anyone can call when it's dealer turn).
- `timeoutPlayer` — anyone can call to timeout a player who hasn't acted within the allowed window.
- `getGame`, `getPlayerHand`, `getDealerHand` — read helpers.
- `blocksUntilTimeout` — helper to see how many blocks remain before player timeout.
- `withdrawHouse` — owner function to withdraw house funds.
- `receive()` — contract accepts ETH.

Events:
- `GameStarted`, `PlayerHit`, `PlayerStood`, `DealerHit`, `GameEnded`, `PlayerTimedOut`

Errors (reverts) you may encounter:
- `AlreadyInGame`, `NotInGame`, `BetOutOfRange`, `NotPlayerTurn`, `NotDealerTurn`, `GameNotActive`, `NotYourGame`, `TransferFailed`

This README assumes you will read `src/OnChainBlackjack.sol` for full behavior details and event signatures.

---

## Game flow & rules (summary)

1. Player calls `startGame` and sends a bet (via `msg.value`) within allowed min/max.
2. Contract deals two cards each to player and dealer.
   - If player's initial hand is a natural blackjack, the game resolves immediately.
3. Player's turn:
   - Player may `hit` to draw a card. If they bust (>21), the dealer wins and the game resolves.
   - Player may `stand` to end their turn; then dealer plays.
   - If player doesn't act within the configured timeout window, anyone can call `timeoutPlayer` and move the flow to dealer turn or resolve.
4. Dealer's play:
   - Dealer draws (via `dealerNextMove`) until reaching the contract's stop condition (e.g., 17+, or 21).
   - Dealer busts => player wins; otherwise, scores are compared and payouts resolved.
5. Payouts:
   - Player win: receives `2x` bet (principal + winnings) or payout formula implemented by contract.
   - Push: player gets bet back.
   - Dealer win: house keeps funds.
6. House bank:
   - The contract owner can withdraw accumulated house funds using `withdrawHouse`.

The tests implement edge, fuzz, and invariants for these flows—see `test/OnChainBlackjack.t.sol`.

---

## Repository layout

- `src/OnChainBlackjack.sol` — main game contract.
- `test/OnChainBlackjack.t.sol` — full test suite with harness utilities and many unit/fuzz tests.
- `script/DeployOnChainBlackjack.s.sol` — Foundry deploy script (check the script file for the exact script class name to run).
- `lib/forge-std` — local copy of `forge-std` used by tests.
- `foundry.toml` — Foundry configuration.

---

## Requirements

- Foundry toolchain (includes `forge`, `cast`, `anvil`)
  - Install via Foundry installer (see "Setup and quick start").
- Git (to clone repo and submodules if needed).
- A JSON-RPC endpoint (public testnet/mainnet or local Anvil) and a private key if you want to deploy to a live or test network.
- Optional: `node`/`npm` only if you want to use JS tooling, but not required for this repo.

---

## Setup and quick start

1. Install Foundry (if not installed). The official/install method:

   - Follow Foundry's installation instructions (the canonical method is to run Foundry's install script, then run `foundryup` to ensure latest).
   - After installation, ensure `forge`, `cast`, and `anvil` are on your PATH.

2. Clone repository (example):

   - `https://github.com/mishraji874/On-Chain-Blackjack-Smart-Contract.git`

3. Install dependencies (if using submodules):

   - This repo includes a `lib/forge-std` directory. If using `git` submodules, run:
     - `git submodule update --init --recursive`
   - Otherwise, this repository already contains `lib/forge-std`.

4. Build:

   - `forge build`

5. Start a local node for testing/development (optional):

   - `anvil` (runs an ephemeral local node, default port 8545)

---

## Building, formatting & snapshots

- Build: `forge build`
- Format: `forge fmt`
- Gas snapshots: `forge snapshot`

---

## Running tests

Unit tests and fuzz tests are written using Foundry's `forge` test framework.

- Run full test suite:
  - `forge test`
- Run tests with verbose output:
  - `forge test -vvvv`
- Run a specific test file:
  - `forge test --match-path test/OnChainBlackjack.t.sol`

Notes:
- Tests use `forge-std` for cheats and test utilities.
- There is a test harness `BlackjackHarness` inside the test file to set up deterministic hands for edge cases—read `test/OnChainBlackjack.t.sol` to see how harness functions are used.

---

## Deploying

A simple way to deploy using Foundry scripting:

1. Ensure you have an RPC URL and a private key for broadcasting.

2. Inspect `script/DeployOnChainBlackjack.s.sol` to find the script contract name (script classes are named inside that file). For example, a script could be `DeployOnChainBlackjack`.

3. Run the script with `forge script`:

   - `forge script script/DeployOnChainBlackjack.s.sol:<ScriptContract> --rpc-url <RPC_URL> --private-key <PRIVATE_KEY> --broadcast`

   - Replace `<ScriptContract>` with the script class name declared in the `.s.sol` script file.
   - Example (replace values):
     - `forge script script/DeployOnChainBlackjack.s.sol:DeployOnChainBlackjack --rpc-url https://rpc.ankr.com/goerli --private-key 0xYOURKEY --broadcast`

4. After successful deployment you'll receive the deployed contract address in the command output.

Artifacts:
- Compiled artifacts and ABIs are available under the `out/` directory (generated by `forge build`). Use the JSON ABI file to interact using external tools like `ethers.js`, `web3.js`, or `cast`.

---

## Interacting with a deployed contract

Using `cast` to call or send transactions:

- Call view function:
  - `cast call <CONTRACT_ADDRESS> "getGame(uint256)(address,uint256,...) " <GAME_ID> --rpc-url <RPC_URL>`
  - (Use the correct function signature from the contract; see ABI in `out/`.)

- Send a transaction (example: start game sending 0.1 ETH):
  - `cast send <CONTRACT_ADDRESS> "startGame()" --value 0.1ether --private-key 0xYOURKEY --rpc-url <RPC_URL> --legacy`

- Example: `cast send 0xContractAddr "startGame()" --value 0.1ether --private-key 0xabc... --rpc-url https://rpc.ankr.com/goerli`

Tip:
- For complex calls, use the ABI from `out/OnChainBlackjack.json` and any frontend or script that uses `ethers.js` or `web3.js`. When calling from scripts, ensure your ABI and types match the contract function signatures exactly.

---

## Security considerations

- Ensure the house bankroll is monitored—owner withdrawal should be restricted and audited.
- This implementation contains deterministic on-chain randomness (card draws derived from contract state). This is not secure for high-stakes production use unless randomness is provided by a secure oracle/VRF.
- Carefully review economic and reentrancy safety. Use Foundry tests and fuzzing to explore edge cases.
- Do not use this contract with real funds on mainnet without an independent security audit and stronger randomness.

---

## Contributing

- Run `forge fmt` before submitting PRs.
- Add tests for any bug fixes or new features.
- If you modify logic that affects payouts, update unit tests to reflect numeric expectations.
- Open issues for bugs or feature requests.

---

## License & contact

- Check repository root for `LICENSE` (the project typically inherits the license used by the author).
- For questions, open an issue or contact the repository maintainer via the channel used in the hosting platform.

---

Thank you for checking out this repository. If you need help running tests or deploying, mention which OS and Foundry version you're using and I can provide step-by-step guidance.
