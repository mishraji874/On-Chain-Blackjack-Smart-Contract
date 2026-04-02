// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/**
 * @title OnChainBlackjack
 * @notice A fully on-chain Blackjack game with open hands, weighted RNG,
 *         a public dealerNextMove() function, and a 10-block player move timer.
 * @dev    All hands are visible on-chain. RNG is pseudo-random using block data.
 *         In production, replace RNG with Chainlink VRF for tamper-proof randomness.
 */

contract OnChainBlackjack {
    // ─────────────────────────────────────────────────────────────
    //  CONSTANTS
    // ─────────────────────────────────────────────────────────────

    uint8 public constant DEALER_MIN_STAND = 21; // Dealer hits until reaching 21
    uint256 public constant MOVE_TIMEOUT_BLOCKS = 10; // Players must act within 10 blocks
    uint256 public constant MIN_BET = 0.001 ether;
    uint256 public constant MAX_BET = 1 ether;

    // ─────────────────────────────────────────────────────────────
    //  ENUMS & STRUCTS
    // ─────────────────────────────────────────────────────────────

    enum GameState {
        Inactive, // No game running
        PlayerTurn, // Waiting for player to hit or stand
        DealerTurn, // Dealer is drawing cards
        Finished // Game resolved
    }

    enum GameResult {
        None,
        PlayerWin,
        DealerWin,
        Push // Tie
    }

    struct Card {
        uint8 value; // 2-10 (Ace stored as 11, handled in score logic)
        bool isAce;
    }

    struct Game {
        address payable player;
        uint256 bet;
        Card[] playerHand;
        Card[] dealerHand;
        GameState state;
        GameResult result;
        uint256 lastActionBlock; //block when last player action occured
    }

    // ─────────────────────────────────────────────────────────────
    //  STATE
    // ─────────────────────────────────────────────────────────────

    uint256 public nextGameId;
    mapping(uint256 => Game) public games;
    mapping(address => uint256) public activeGameOf; // player -> current gameId (0 = none)
    uint256 private _nonce; // incrementing nonce for RNG entropy

    // ─────────────────────────────────────────────────────────────
    //  EVENTS
    // ─────────────────────────────────────────────────────────────

    event GameStarted(
        uint256 indexed gameId,
        address indexed player,
        uint256 bet
    );
    event PlayerHit(
        uint256 indexed gameId,
        uint8 cardValue,
        bool isAce,
        uint8 newScore
    );
    event PlayerStood(uint256 indexed gameId, uint8 playerScore);
    event DealerHit(
        uint256 indexed gameId,
        uint8 cardValue,
        bool isAce,
        uint8 newScore
    );
    event GameEnded(uint256 indexed gameId, GameResult result, uint256 payout);
    event PlayerTimedOut(uint256 indexed gameId, address indexed player);

    // ─────────────────────────────────────────────────────────────
    //  ERRORS
    // ─────────────────────────────────────────────────────────────

    error AlreadyInGame();
    error NotInGame();
    error BetOutOfRange();
    error NotPlayerTurn();
    error NotDealerTurn();
    error GameNotActive();
    error NotYourGame();
    error TransferFailed();

    // ─────────────────────────────────────────────────────────────
    //  MODIFIERS
    // ─────────────────────────────────────────────────────────────

    modifier onlyPlayer(uint256 gameId) {
        if (games[gameId].player != msg.sender) revert NotYourGame();
        _;
    }

    modifier inState(uint256 gameId, GameState expected) {
        if (games[gameId].state != expected) {
            if (expected == GameState.PlayerTurn) revert NotPlayerTurn();
            if (expected == GameState.DealerTurn) revert NotDealerTurn();
            revert GameNotActive();
        }
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  CORE GAME FUNCTIONS
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Start a new game by placing a bet.
     * @dev    Deals 2 cards to both player and dealer immediately.
     *         If the player's initial hand is 21 (Blackjack), game resolves instantly.
     */
    function startGame() external payable {
        if (activeGameOf[msg.sender] != 0) revert AlreadyInGame();
        if (msg.value < MIN_BET || msg.value > MAX_BET) revert BetOutOfRange();

        uint256 gameId = ++nextGameId;
        activeGameOf[msg.sender] = gameId;

        Game storage g = games[gameId];
        g.player = payable(msg.sender);
        g.bet = msg.value;
        g.state = GameState.PlayerTurn;
        g.lastActionBlock = block.number;

        // Deal initial 2 cards each
        _dealCard(gameId, true); // player card 1
        _dealCard(gameId, true); // player card 2
        _dealCard(gameId, false); // dealer card 1
        _dealCard(gameId, false); // dealer card 2

        emit GameStarted(gameId, msg.sender, msg.value);

        // check foor natural blackjack
        uint8 playerScore = _bestScore(g.playerHand);
        if (playerScore == 21) {
            _stand(gameId); // instantly move to dealer turn / resolution
        }
    }

    /**
     * @notice Player draws another card
     * @param gameId The ID of the game
     */
    function hit(
        uint256 gameId
    ) external onlyPlayer(gameId) inState(gameId, GameState.PlayerTurn) {
        _enforceTimeout(gameId);

        Game storage g = games[gameId];
        g.lastActionBlock = block.number;

        Card memory c = _drawCard();
        g.playerHand.push(c);

        uint8 score = _bestScore(g.playerHand);
        emit PlayerHit(gameId, c.value, c.isAce, score);

        if (score > 21) {
            // Player busts
            _resolveGame(gameId, GameResult.DealerWin);
        } else if (score == 21) {
            // Auto-stand on 21
            _stand(gameId);
        }
    }

    /**
     * @notice Player stands (stops drawing). Transitions game to dealer turn.
     * @param gameId The ID of the game
     */
    function stand(
        uint256 gameId
    ) external onlyPlayer(gameId) inState(gameId, GameState.PlayerTurn) {
        _enforceTimeout(gameId);
        emit PlayerStood(gameId, _bestScore(games[gameId].playerHand));
        _stand(gameId);
    }

    /**
     * @notice Advances the dealer's turn by one card draw.
     * @dev    Anyone can call this when it is the dealer's turn.
     *         Repeat until the game reaches Finished state.
     * @param  gameId The ID of the game.
     */
    function dealerNextMove(
        uint256 gameId
    ) external inState(gameId, GameState.DealerTurn) {
        Game storage g = games[gameId];
        uint8 dealerScore = _bestScore(g.dealerHand);

        if (dealerScore < DEALER_MIN_STAND) {
            // Dealer must hit
            Card memory c = _drawCard();
            g.dealerHand.push(c);
            dealerScore = _bestScore(g.dealerHand);
            emit DealerHit(gameId, c.value, c.isAce, dealerScore);
        }

        if (dealerScore >= DEALER_MIN_STAND) {
            // Dealer has reached 21 (or bust) — resolve
            uint8 playerScore = _bestScore(g.playerHand);

            if (dealerScore > 21) {
                _resolveGame(gameId, GameResult.PlayerWin);
            } else if (playerScore > dealerScore) {
                _resolveGame(gameId, GameResult.PlayerWin);
            } else if (dealerScore > playerScore) {
                _resolveGame(gameId, GameResult.DealerWin);
            } else {
                _resolveGame(gameId, GameResult.Push);
            }
        }
    }

    /**
     * @notice Anyone can call this to time out a player who has not acted
     *         within MOVE_TIMEOUT_BLOCKS. Forces the player to stand.
     * @param  gameId The ID of the game.
     */
    function timeoutPlayer(
        uint256 gameId
    ) external inState(gameId, GameState.PlayerTurn) {
        Game storage g = games[gameId];
        require(
            block.number > g.lastActionBlock + MOVE_TIMEOUT_BLOCKS,
            "Player still has time"
        );
        emit PlayerTimedOut(gameId, g.player);
        _stand(gameId);
    }

    // ─────────────────────────────────────────────────────────────
    //  VIEW / GETTER FUNCTIONS
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Returns full details of a game.
     */
    function getGame(
        uint256 gameId
    )
        external
        view
        returns (
            address player,
            uint256 bet,
            GameState state,
            GameResult result,
            uint8 playerScore,
            uint8 dealerScore,
            uint256 lastActionBlock
        )
    {
        Game storage g = games[gameId];
        return (
            g.player,
            g.bet,
            g.state,
            g.result,
            _bestScore(g.playerHand),
            _bestScore(g.dealerHand),
            g.lastActionBlock
        );
    }

    /**
     * @notice Returns the player's hand for a game.
     */
    function getPlayerHand(
        uint256 gameId
    ) external view returns (uint8[] memory values, bool[] memory aces) {
        return _handArrays(games[gameId].playerHand);
    }

    /**
     * @notice Returns the dealer's hand for a game.
     */
    function getDealerHand(
        uint256 gameId
    ) external view returns (uint8[] memory values, bool[] memory aces) {
        return _handArrays(games[gameId].dealerHand);
    }

    /**
     * @notice Returns how many blocks a player has left to act.
     *         Returns 0 if already timed out.
     */
    function blocksUntilTimeout(
        uint256 gameId
    ) external view returns (uint256) {
        Game storage g = games[gameId];
        if (g.state != GameState.PlayerTurn) return 0;
        uint256 deadline = g.lastActionBlock + MOVE_TIMEOUT_BLOCKS;
        if (block.number >= deadline) return 0;
        return deadline - block.number;
    }

    // ─────────────────────────────────────────────────────────────
    //  INTERNAL HELPERS
    // ─────────────────────────────────────────────────────────────

    /**
     * @dev Transition the game to DealerTurn and kick off dealer logic inline
     *      if possible (dealer may already be at 21 from initial deal).
     */
    function _stand(uint256 gameId) internal {
        games[gameId].state = GameState.DealerTurn;

        // If dealer already at 21+ on their initial hand, resolve immediately
        uint8 dealerScore = _bestScore(games[gameId].dealerHand);
        if (dealerScore >= DEALER_MIN_STAND) {
            uint8 playerScore = _bestScore(games[gameId].playerHand);
            if (dealerScore > 21) {
                _resolveGame(gameId, GameResult.PlayerWin);
            } else if (playerScore > dealerScore) {
                _resolveGame(gameId, GameResult.PlayerWin);
            } else if (playerScore < dealerScore) {
                _resolveGame(gameId, GameResult.DealerWin);
            } else {
                _resolveGame(gameId, GameResult.Push);
            }
        }
        // Otherwise callers must invoke dealerNextMove() to advance the dealer
    }

    /**
     * @dev Deal a single card directly into the on-chain hand array
     * @param toPlayer true -> player hand, false -> dealer hand
     */
    function _dealCard(uint256 gameId, bool toPlayer) internal {
        Card memory c = _drawCard();
        if (toPlayer) {
            games[gameId].playerHand.push(c);
        } else {
            games[gameId].dealerHand.push(c);
        }
    }

    /**
     * @dev Pseudo-random card draw with weighted probabilities.
     *
     *      A real 52-card deck has 16 cards worth 10 (10,J,Q,K × 4 suits)
     *      and 4 cards each of 2–9 and Ace.
     *
     *      We model this with a roll in [0, 52):
     *        0–3   → Ace  (4/52)
     *        4–7   → 2    (4/52)
     *        8–11  → 3    (4/52)
     *        12–15 → 4    (4/52)
     *        16–19 → 5    (4/52)
     *        20–23 → 6    (4/52)
     *        24–27 → 7    (4/52)
     *        28–31 → 8    (4/52)
     *        32–35 → 9    (4/52)
     *        36–51 → 10   (16/52)  ← 10, J, Q, K all map to 10
     *
     * @notice This RNG is pseudo-random and NOT suitable for high-stakes production use.
     *         Replace with Chainlink VRF for provable fairness.
     */
    function _drawCard() internal returns (Card memory) {
        uint256 rand = uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp,
                    block.prevrandao,
                    msg.sender,
                    _nonce++
                )
            )
        ) % 52;

        Card memory c;

        if (rand < 4) {
            // Ace — stored as 11; score logic adjusts to 1 when needed
            c.value = 11;
            c.isAce = true;
        } else if (rand < 8) {
            c.value = 2;
        } else if (rand < 12) {
            c.value = 3;
        } else if (rand < 16) {
            c.value = 4;
        } else if (rand < 20) {
            c.value = 5;
        } else if (rand < 24) {
            c.value = 6;
        } else if (rand < 28) {
            c.value = 7;
        } else if (rand < 32) {
            c.value = 8;
        } else if (rand < 36) {
            c.value = 9;
        } else {
            // 10, J, Q, K → all worth 10 (slots 36–51, i.e. 16/52)
            c.value = 10;
        }
    }

    /**
     * @dev Computes the best (highest without busting) score for a hand.
     *      Aces are stored as 11. For each Ace, if the total exceeds 21,
     *      we "flip" that Ace from 11 → 1 (subtract 10) until we're ≤ 21
     *      or no more Aces remain.
     */
    function _bestScore(Card[] storage hand) internal view returns (uint8) {
        uint256 total = 0;
        uint256 aces = 0;

        for (uint256 i = 0; i < hand.length; i++) {
            total += hand[i].value;
            if (hand[i].isAce) aces++;
        }

        // Each time we bust, flip one Ace from 11 → 1
        while (total > 21 && aces > 0) {
            total -= 10; // 11 → 1
            aces--;
        }

        return uint8(total);
    }

    /**
     * @dev Resolves the game: pays out, clears active game mapping.
     */
    function _resolveGame(uint256 gameId, GameResult result) internal {
        Game storage g = games[gameId];
        g.state = GameState.Finished;
        g.result = result;

        uint256 payout = 0;

        if (result == GameResult.PlayerWin) {
            // Player wins 2× their bet
            payout = g.bet * 2;
        } else if (result == GameResult.Push) {
            // Tie — return the bet
            payout = g.bet;
        }
        // DealerWin → house keeps the bet, payout = 0

        // Clear active game before external call (reentrancy guard)
        activeGameOf[g.player] = 0;

        emit GameEnded(gameId, result, payout);

        if (payout > 0) {
            (bool sent, ) = g.player.call{value: payout}("");
            if (!sent) revert TransferFailed();
        }
    }

    /**
     * @dev Reverts if the player has exceeded their 10-block window.
     */
    function _enforceTimeout(uint256 gameId) internal view {
        Game storage g = games[gameId];
        require(
            block.number <= g.lastActionBlock + MOVE_TIMEOUT_BLOCKS,
            "Move window expired - call timeoutPlayer()"
        );
    }

    /**
     * @dev Converts a Card[] storage array into parallel value/ace arrays for external view.
     */
    function _handArrays(
        Card[] storage hand
    ) internal view returns (uint8[] memory values, bool[] memory aces) {
        uint256 len = hand.length;
        values = new uint8[](len);
        aces = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            values[i] = hand[i].value;
            aces[i] = hand[i].isAce;
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  HOUSE FUNDING & WITHDRAWAL
    // ─────────────────────────────────────────────────────────────

    /// @notice The contract owner (house) address
    address public immutable owner;

    constructor() {
        owner = msg.sender;
    }

    /// @notice Fund the house bankroll so it can pay out winning players
    receive() external payable {}

    /// @notice Owner can withdraw house profits
    function withdrawHouse(uint256 amount) external {
        require(msg.sender == owner, "Not owner");
        (bool sent, ) = payable(owner).call{value: amount}("");
        if (!sent) revert TransferFailed();
    }

    /// @notice Returns contract balance (house bankroll)
    function houseBankroll() external view returns (uint256) {
        return address(this).balance;
    }
}
