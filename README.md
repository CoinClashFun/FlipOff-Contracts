# FlipOff Smart Contract

> **Part of CoinClash** — Decentralized, trustless, provably fair games on Monad.

FlipOff is a decentralized, trustless, peer-to-peer coin flip betting game built on the Monad testnet. It utilizes **Pyth Entropy** to ensure verifiable, tamper-proof randomness for every round.

## 📍 Deployed Contract

| Network | Address |
|---------|---------|
| Monad Testnet | `0xcd892212d9f93f00869c931dcc9b052dfafdf5d1` |

---

## 🛡️ Trustless & Decentralized

The core philosophy of FlipOff is that **code is law**.

- **No Admin Control**: Once a game starts, the contract owner cannot influence the outcome, pause the game, or drain the funds locked in active lobbies.
- **Automated Payouts**: Winnings are calculated automatically by the smart contract and can be claimed immediately after the game ends.
- **Open Source**: The full contract source code is available in `src/FlipOff.sol` for verification.

---

## 🎲 Verifiable Randomness (Pyth Entropy)

FlipOff uses [Pyth Entropy](https://pyth.network/entropy), a secure distributed random number generation protocol that guarantees **provably fair, cryptographically secure randomness** that **nobody can manipulate** — not players, not the house, not even the developers.

### How Pyth Entropy Works

1. **Request Phase**: When a coin flip is triggered, the contract calls `entropy.requestV2()` which sends a request to Pyth's decentralized entropy provider network.

2. **Sequence Number**: Pyth assigns a unique sequence number to track this specific randomness request. This is stored on-chain in the `Round` struct for verification.

3. **Off-Chain Generation**: The Pyth provider generates randomness using secure cryptographic methods (ECDSA signatures over the sequence number), which is computationally infeasible to predict or reverse-engineer.

4. **Callback & Verification**: The provider calls the contract's `entropyCallback` function with:
   - The random number (bytes32)
   - Cryptographic proof of authenticity
   - The sequence number for verification

5. **Outcome Determination**: The contract uses the random number to determine the winner:
   ```
   If randomNumber % 2 == 0 → HEADS wins
   If randomNumber % 2 == 1 → TAILS wins
   ```

### Why It's Truly 50/50

The random number from Pyth is a 256-bit value derived from cryptographic operations. When we check `randomNumber % 2`:
- **Bit 0** (least significant bit) determines the outcome
- Cryptographically random bits have **exactly 50% probability** of being 0 or 1
- This is mathematically proven by the properties of secure hash functions and signatures
- Over millions of flips, results converge to **exactly 50% HEADS, 50% TAILS**

### Why It Cannot Be Gamed

| Attack Vector | Why It Fails |
|---------------|--------------|
| **House Manipulation** | The contract has NO way to influence the random number. It only reads the callback result. Even the contract owner cannot predict or change outcomes. |
| **Player Front-Running** | The random number is generated AFTER the request is made. Players cannot see the result before committing their bet. |
| **Miner/Validator MEV** | The randomness is generated off-chain by Pyth's secure signers. Block producers cannot manipulate it. |
| **Provider Collusion** | Pyth uses multiple independent providers with economic incentives (staking) to remain honest. Manipulation would require compromising the cryptographic keys. |
| **Delayed Reveal Attacks** | Once entropy is requested, the callback WILL be called. The contract cannot selectively ignore unfavorable results. |
| **Replay Attacks** | Each sequence number is unique and can only be used once. The contract validates the sequence matches. |

### Verifying Fairness Yourself

Every coin flip result is recorded on the blockchain and can be independently verified:

1. **EntropyRequested Event**: Shows when randomness was requested and the Pyth sequence number
2. **RoundResolved Event**: Shows the resulting winner and updated scores
3. **getGameRounds(gameId)**: Returns all rounds with their sequence numbers, winners, and resolution status

You can cross-reference the sequence numbers with Pyth's entropy explorer to verify authenticity.

---

## 💰 Fee Structure

A small fee is taken from the total pot **only upon a win** to maintain the platform.

| Item | Value |
|------|-------|
| **Protocol Fee** | 5% (max, adjustable by admin) |
| **Winner Payout** | 95% of Total Pot |
| **Entropy Costs** | Paid by FlipOff Bot or can be manually triggered |

### Example: 1v1 Game with 100 MON Bet

| Step | Amount |
|------|--------|
| Total Pot | 200 MON |
| Protocol Fee (5%) | 10 MON |
| **Winner Receives** | **190 MON** |

---

## 🔄 Game Lifecycle

### 1. OPEN
- Creator makes a lobby, choosing team size (1-3 players per team), rounds to win (Best of 1-3), and bet amount
- Players can join either HEADS or TAILS team by matching the bet
- Creator can cancel if no other players have joined or auto expire in 1000 blocks.

### 2. FULL
- Both teams have reached the target size
- Anyone can call `startGame()` (paying the entropy fee) to begin

### 3. IN_PROGRESS
- FlipOff Bot (or anyone) triggers coin flips by paying entropy fees
- Pyth Entropy callback determines each round's winner
- Scores update automatically
- Game continues until one team reaches the `roundsToWin` target

### 4. FINISHED
- A winner is determined
- Winners can call `claimWinnings()` to receive the pot

### 5. VOID (Safety Mechanism)
- OPEN lobbies can be voided after 1000 blocks if they don't fill
- Stuck games can be voided after 3000 blocks if entropy callbacks fail
- Players can withdraw their original bet from voided games

---

## 📊 Data Storage & History

All game data is stored on-chain and queryable:

### Lobby Data
- Game ID, creator, team size, rounds to win, bet amount
- Current state, scores, winner
- Pending entropy sequence number

### Round History
```
Round {
    roundNumber    // Which round (1, 2, 3...)
    sequenceNumber // Pyth VRF sequence for verification
    winner         // HEADS or TAILS
    resolved       // Whether callback was received
}
```

Use `getGameRounds(gameId)` to fetch all round history with VRF sequence numbers for any game.

### Player Data
- Address, team choice, claim status
- Use `getPlayers(gameId)` to see all participants

---

## 🔐 Security

### Smart Contract Security
- **ReentrancyGuard**: All critical functions protected against reentrancy attacks
- **Checks-Effects-Interactions**: State updates happen before external calls
- **Input Validation**: All user inputs validated with custom errors
- **Access Control**: Admin functions restricted to owner with reasonable limits

### Economic Security
- Minimum bet: 100 MON (prevents dust attacks and allows pyth fee to be paid by FlipOff Bot)
- Maximum fee: 5% (hardcoded cap)
- Maximum team size: 3
- Maximum rounds: 3

### Void Mechanism
Protects user funds if:
- A lobby never fills (void after 1000 blocks)
- Entropy provider fails (void after 3000 blocks)

---

## 🛠️ Contract Functions

### Player Functions
| Function | Description |
|----------|-------------|
| `createLobby(teamSize, roundsToWin, team)` | Create a new game lobby |
| `joinLobby(gameId, team)` | Join an existing lobby |
| `cancelLobby(gameId)` | Cancel your own lobby (if alone) |
| `claimWinnings(gameId)` | Claim your winnings after game ends |
| `withdrawVoid(gameId)` | Withdraw bet from a voided game |

### FlipOff Bot/Trigger Functions
| Function | Description |
|----------|-------------|
| `startGame(gameId)` | Start a full lobby (pays entropy fee) |
| `requestNextRound(gameId)` | Trigger the next coin flip (pays entropy fee) |
| `voidLobby(gameId)` | Void an expired lobby |

### View Functions
| Function | Description |
|----------|-------------|
| `getLobby(gameId)` | Get lobby details |
| `getPlayers(gameId)` | Get all players in a game |
| `getGameRounds(gameId)` | Get all rounds with VRF sequences |
| `getPlayerInfo(gameId, address)` | Get specific player info |
| `getEntropyFee()` | Get current Pyth entropy fee |
| `getLobbyStats()` | Get total games and volume |

---

## 🤖 FlipOff Bot

FlipOff Bot automates the game flow:
1. Monitors for FULL lobbies → calls `startGame()`
2. Monitors for resolved rounds → calls `requestNextRound()`
3. Monitors for expired lobbies → calls `voidLobby()`

---

## 📜 Events

All state changes emit events for frontend tracking:

```
LobbyCreated(gameId, creator, teamSize, roundsToWin, betAmount)
PlayerJoined(gameId, player, team, teamCount)
GameStarted(gameId)
EntropyRequested(gameId, sequenceNumber, round)
RoundResolved(gameId, round, roundWinner, headsScore, tailsScore)
GameFinished(gameId, winner, finalHeadsScore, finalTailsScore)
WinningsClaimed(gameId, player, amount)
LobbyVoided(gameId)
RefundClaimed(gameId, player, amount)
```

---

Built with ❤️ on Monad • Part of [CoinClash.fun](https://coinclash.fun)
