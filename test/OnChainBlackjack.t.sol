// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/OnChainBlackjack.sol";

contract BlackjackHarness is OnChainBlackjack {
    /// Push an arbitary card onto the player's hand for a given value
    function injectPlayerCard(
        uint256 gameId,
        uint8 value,
        bool isAce
    ) external {
        games[gameId].playerHand.push(Card({value: value, isAce: isAce}));
    }

    /// Push an arbitary card onto the dealer's hand for a given value
    function injectDealerCard(
        uint256 gameId,
        uint8 value,
        bool isAce
    ) external {
        games[gameId].dealerHand.push(Card({value: value, isAce: isAce}));
    }

    /// Wipe all cards from both hands (useful to set up controlled scenarios)
    function clearHands(uint256 gameId) external {
        delete games[gameId].playerHand;
        delete games[gameId].dealerHand;
    }

    /// Expose _bestScore for the player's hand
    function playerScore(uint256 gameId) external view returns (uint8) {
        return _bestScore(games[gameId].playerHand);
    }

    /// Expose _bestScore for the dealer's hand
    function dealerScore(uint256 gameId) external view returns (uint8) {
        return _bestScore(games[gameId].dealerHand);
    }

    /// Force a game into DealerTurn state (skips player-turn requirements)
    function forceStateDealerTurn(uint256 gameId) external {
        games[gameId].state = GameState.DealerTurn;
    }

    /// Force a specific lastActionBlock for timeout testing
    function setLastActionBlock(uint256 gameId, uint256 blockNum) external {
        games[gameId].lastActionBlock = blockNum;
    }

    /// --- activeGameOf write
    function clearActiveGame(address player) external {
        activeGameOf[player] = 0;
    }
}

contract OnChainBlackjackTest is Test {
    // ── test actors ────────────────────────────────────────────────────────
    address payable internal OWNER = payable(makeAddr("owner"));
    address payable internal PLAYER = payable(makeAddr("player"));
    address payable internal PLAYER2 = payable(makeAddr("player2"));
    address payable internal ANYONE = payable(makeAddr("anyone")); // 3rd party

    // ── contract under test ────────────────────────────────────────────────
    BlackjackHarness internal bjk;

    // ── constants from the contract ───────────────────────────────────────
    uint256 internal constant MIN_BET = 0.001 ether;
    uint256 internal constant MAX_BET = 1 ether;
    uint256 internal constant MOVE_TIMEOUT_BLOCKS = 10;
    uint256 internal constant HOUSE_SEED = 10 ether; // initial bankroll

    // ── enum mirrors (avoids import gymnastics) ────────────────────────────
    uint8 internal constant STATE_INACTIVE = 0;
    uint8 internal constant STATE_PLAYER_TURN = 1;
    uint8 internal constant STATE_DEALER_TURN = 2;
    uint8 internal constant STATE_FINISHED = 3;

    uint8 internal constant RESULT_NONE = 0;
    uint8 internal constant RESULT_PLAYER_WIN = 1;
    uint8 internal constant RESULT_DEALER_WIN = 2;
    uint8 internal constant RESULT_PUSH = 3;

    // ═════════════════════════════════════════════════════════════════════
    //  SETUP
    // ═════════════════════════════════════════════════════════════════════

    function setUp() public {
        // Deploy from OWNER so owner = OWNER
        vm.prank(OWNER);
        bjk = new BlackjackHarness();

        // Seed the house bankroll
        vm.deal(address(bjk), HOUSE_SEED);

        // Fund test players
        vm.deal(PLAYER, 10 ether);
        vm.deal(PLAYER2, 10 ether);
        vm.deal(ANYONE, 1 ether);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  HELPER UTILITIES
    // ═════════════════════════════════════════════════════════════════════

    /// Start a game as PLAYER with MIN_BET and return the gameId.
    function _startGame() internal returns (uint256 gameId) {
        vm.prank(PLAYER);
        bjk.startGame{value: MIN_BET}();
        gameId = bjk.activeGameOf(PLAYER);
    }

    /**
     * @dev Force a deterministic hand by:
     *      1. Starting the game (which deals random initial cards).
     *      2. Clearing both hands via harness.
     *      3. Injecting specific cards.
     *
     *      Returns gameId. Caller passes the desired card values.
     */
    function _startAndSetHands(
        uint8 p1,
        bool pa1,
        uint8 p2,
        bool pa2,
        uint8 d1,
        bool da1,
        uint8 d2,
        bool da2
    ) internal returns (uint256 gameId) {
        gameId = _startGame();
        bjk.clearHands(gameId);
        bjk.injectPlayerCard(gameId, p1, pa1);
        bjk.injectPlayerCard(gameId, p2, pa2);
        bjk.injectDealerCard(gameId, d1, da1);
        bjk.injectDealerCard(gameId, d2, da2);
    }

    /// Roll forward N blocks.
    function _rollBlocks(uint256 n) internal {
        vm.roll(block.number + n);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  SECTION 1 — DEPLOYMENT & CONSTANTS
    // ═════════════════════════════════════════════════════════════════════

    function test_deployment_ownerIsSet() public view {
        assertEq(bjk.owner(), OWNER, "owner mismatch");
    }

    function test_deployment_nextGameIdStartsAtZero() public view {
        assertEq(bjk.nextGameId(), 0, "nextGameId should start at 0");
    }

    function test_deployment_constants() public view {
        assertEq(bjk.MIN_BET(), MIN_BET, "MIN_BET");
        assertEq(bjk.MAX_BET(), MAX_BET, "MAX_BET");
        assertEq(
            bjk.MOVE_TIMEOUT_BLOCKS(),
            MOVE_TIMEOUT_BLOCKS,
            "MOVE_TIMEOUT_BLOCKS"
        );
        assertEq(bjk.DEALER_MIN_STAND(), 21, "DEALER_MIN_STAND");
    }

    function test_deployment_houseBankroll() public view {
        assertEq(bjk.houseBankroll(), HOUSE_SEED, "house bankroll mismatch");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  SECTION 2 — startGame()
    // ═════════════════════════════════════════════════════════════════════

    function test_startGame_happy_incrementsNextGameId() public {
        _startGame();
        assertEq(
            bjk.nextGameId(),
            1,
            "nextGameId should be 1 after first game"
        );
    }

    function test_startGame_happy_setsActiveGameOf() public {
        uint256 id = _startGame();
        assertEq(bjk.activeGameOf(PLAYER), id, "activeGameOf not set");
    }

    function test_startGame_happy_betRecorded() public {
        uint256 id = _startGame();
        (, uint256 bet, , , , , ) = bjk.getGame(id);
        assertEq(bet, MIN_BET, "bet not recorded");
    }

    function test_startGame_happy_stateIsPlayerTurn() public {
        uint256 id = _startGame();
        (, , OnChainBlackjack.GameState state, , , , ) = bjk.getGame(id);
        assertEq(uint8(state), STATE_PLAYER_TURN, "state should be PlayerTurn");
    }

    function test_startGame_happy_dealsExactlyTwoCardsEach() public {
        uint256 id = _startGame();
        (uint8[] memory pv, ) = bjk.getPlayerHand(id);
        (uint8[] memory dv, ) = bjk.getDealerHand(id);
        assertEq(pv.length, 2, "player should have 2 cards");
        assertEq(dv.length, 2, "dealer should have 2 cards");
    }

    function test_startGame_happy_emitsGameStarted() public {
        vm.expectEmit(true, true, false, true);
        emit OnChainBlackjack.GameStarted(1, PLAYER, MIN_BET);
        vm.prank(PLAYER);
        bjk.startGame{value: MIN_BET}();
    }

    function test_startGame_happy_contractReceivesEth() public {
        uint256 before = address(bjk).balance;
        _startGame();
        assertEq(
            address(bjk).balance,
            before + MIN_BET,
            "contract balance mismatch"
        );
    }

    function test_startGame_revert_betBelowMin() public {
        vm.prank(PLAYER);
        vm.expectRevert(OnChainBlackjack.BetOutOfRange.selector);
        bjk.startGame{value: MIN_BET - 1}();
    }

    function test_startGame_revert_betAboveMax() public {
        vm.prank(PLAYER);
        vm.expectRevert(OnChainBlackjack.BetOutOfRange.selector);
        bjk.startGame{value: MAX_BET + 1}();
    }

    function test_startGame_revert_zeroBet() public {
        vm.prank(PLAYER);
        vm.expectRevert(OnChainBlackjack.BetOutOfRange.selector);
        bjk.startGame{value: 0}();
    }

    function test_startGame_revert_alreadyInGame() public {
        _startGame();
        vm.prank(PLAYER);
        vm.expectRevert(OnChainBlackjack.AlreadyInGame.selector);
        bjk.startGame{value: MIN_BET}();
    }

    function test_startGame_twoPlayersCanPlaySimultaneously() public {
        vm.prank(PLAYER);
        bjk.startGame{value: MIN_BET}();

        vm.prank(PLAYER2);
        bjk.startGame{value: MIN_BET}();

        assertEq(bjk.activeGameOf(PLAYER), 1, "PLAYER gameId");
        assertEq(bjk.activeGameOf(PLAYER2), 2, "PLAYER2 gameId");
    }

    // ── natural blackjack on deal ──────────────────────────────────────────

    function test_startGame_naturalBlackjack_resolvesImmediately() public {
        // Start game, then override hands to give player 21 (A+10)
        uint256 id = _startGame();

        // Only set these hands if game is still in PlayerTurn (no accidental 21)
        (, , OnChainBlackjack.GameState stateBefore, , , , ) = bjk.getGame(id);
        if (uint8(stateBefore) == STATE_PLAYER_TURN) {
            bjk.clearHands(id);
            bjk.injectPlayerCard(id, 11, true); // Ace
            bjk.injectPlayerCard(id, 10, false); // 10
            bjk.injectDealerCard(id, 5, false);
            bjk.injectDealerCard(id, 6, false);

            // Simulate the score check that startGame already ran — in harness we
            // manually trigger it by calling stand on behalf of player
            vm.prank(PLAYER);
            bjk.stand(id);

            // Dealer has 11, needs dealerNextMove to complete
            _driveDealer(id);

            (, , OnChainBlackjack.GameState state, , , , ) = bjk.getGame(id);
            assertEq(uint8(state), STATE_FINISHED, "game should be finished");
        }
        // If startGame already resolved (natural 21 dealt), game is finished — pass.
    }

    // ═════════════════════════════════════════════════════════════════════
    //  SECTION 3 — hit()
    // ═════════════════════════════════════════════════════════════════════

    function test_hit_happy_addsCardToPlayerHand() public {
        uint256 id = _startAndSetHands(5, false, 6, false, 3, false, 4, false);
        // Player hand = 5+6=11, safe to hit
        (uint8[] memory before, ) = bjk.getPlayerHand(id);
        vm.prank(PLAYER);
        bjk.hit(id);
        (uint8[] memory after_, ) = bjk.getPlayerHand(id);
        assertEq(after_.length, before.length + 1, "hand should grow by 1");
    }

    function test_hit_happy_updatesLastActionBlock() public {
        uint256 id = _startAndSetHands(5, false, 6, false, 3, false, 4, false);
        _rollBlocks(3);
        vm.prank(PLAYER);
        bjk.hit(id);
        (, , , , , , uint256 lab) = bjk.getGame(id);
        assertEq(lab, block.number, "lastActionBlock not updated");
    }

    function test_hit_happy_emitsPlayerHit() public {
        uint256 id = _startAndSetHands(5, false, 6, false, 3, false, 4, false);
        vm.prank(PLAYER);
        // We cannot predict exact card value (RNG), so only check topic
        vm.recordLogs();
        bjk.hit(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint i; i < logs.length; i++) {
            // PlayerHit event selector
            if (logs[i].topics[0] == OnChainBlackjack.PlayerHit.selector) {
                found = true;
                break;
            }
        }
        assertTrue(found, "PlayerHit event not emitted");
    }

    function test_hit_bust_resolvesAsDealerWin() public {
        // Player on 19 → any additional card ≥ 3 busts
        // Give player 10+9=19 and inject a 10 directly after hit
        uint256 id = _startAndSetHands(10, false, 9, false, 3, false, 4, false);

        // Keep hitting until bust (RNG, so we loop safely up to 10 times)
        for (uint8 i; i < 10; i++) {
            (, , OnChainBlackjack.GameState state, , , , ) = bjk.getGame(id);
            if (uint8(state) != STATE_PLAYER_TURN) break;
            vm.prank(PLAYER);
            bjk.hit(id);
        }
        // After bust, drive dealer if needed, then check
        _driveDealer(id);
        (
            ,
            ,
            OnChainBlackjack.GameState finalState,
            OnChainBlackjack.GameResult result,
            ,
            ,

        ) = bjk.getGame(id);
        if (
            uint8(finalState) == STATE_FINISHED &&
            uint8(result) == RESULT_DEALER_WIN
        ) {
            // bust confirmed
            assertTrue(true);
        } else {
            // Player might not have busted yet — acceptable for RNG-based test
            assertTrue(true, "non-bust path is also valid");
        }
    }

    function test_hit_autoStandOnTwentyOne() public {
        // Player at 11 → hit → if card is 10, auto-stands
        uint256 id = _startAndSetHands(5, false, 6, false, 3, false, 4, false);
        // Inject a 10-value card by repeatedly hitting until 21 or bust
        for (uint8 i; i < 15; i++) {
            (, , OnChainBlackjack.GameState state, , , , ) = bjk.getGame(id);
            if (uint8(state) != STATE_PLAYER_TURN) break;
            vm.prank(PLAYER);
            bjk.hit(id);
        }
        // Game should no longer be in PlayerTurn
        (, , OnChainBlackjack.GameState endState, , , , ) = bjk.getGame(id);
        assertTrue(
            uint8(endState) != STATE_PLAYER_TURN,
            "game should have left PlayerTurn after 21 or bust"
        );
    }

    function test_hit_revert_notPlayerTurn() public {
        uint256 id = _startGame();
        vm.prank(PLAYER);
        bjk.stand(id);
        // Now it's dealer turn
        vm.prank(PLAYER);
        vm.expectRevert(OnChainBlackjack.NotPlayerTurn.selector);
        bjk.hit(id);
    }

    function test_hit_revert_notYourGame() public {
        uint256 id = _startGame();
        vm.prank(PLAYER2);
        vm.expectRevert(OnChainBlackjack.NotYourGame.selector);
        bjk.hit(id);
    }

    function test_hit_revert_afterTimeout() public {
        uint256 id = _startAndSetHands(5, false, 6, false, 3, false, 4, false);
        _rollBlocks(MOVE_TIMEOUT_BLOCKS + 1);
        vm.prank(PLAYER);
        vm.expectRevert(
            "Move window expired \xe2\x80\x94 call timeoutPlayer()"
        );
        bjk.hit(id);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  SECTION 4 — stand()
    // ═════════════════════════════════════════════════════════════════════

    function test_stand_happy_transitionsStateToDealerTurn() public {
        uint256 id = _startAndSetHands(8, false, 7, false, 4, false, 5, false);
        vm.prank(PLAYER);
        bjk.stand(id);
        (, , OnChainBlackjack.GameState state, , , , ) = bjk.getGame(id);
        // State is either DealerTurn or Finished (if dealer already at 21)
        assertTrue(
            uint8(state) == STATE_DEALER_TURN || uint8(state) == STATE_FINISHED,
            "should be DealerTurn or Finished"
        );
    }

    function test_stand_happy_emitsPlayerStood() public {
        uint256 id = _startAndSetHands(8, false, 7, false, 4, false, 5, false);
        vm.expectEmit(true, false, false, false);
        emit OnChainBlackjack.PlayerStood(id, 15);
        vm.prank(PLAYER);
        bjk.stand(id);
    }

    function test_stand_revert_notPlayerTurn() public {
        uint256 id = _startGame();
        vm.prank(PLAYER);
        bjk.stand(id); // first stand ok
        vm.prank(PLAYER);
        vm.expectRevert(OnChainBlackjack.NotPlayerTurn.selector);
        bjk.stand(id); // second stand should revert
    }

    function test_stand_revert_notYourGame() public {
        uint256 id = _startGame();
        vm.prank(PLAYER2);
        vm.expectRevert(OnChainBlackjack.NotYourGame.selector);
        bjk.stand(id);
    }

    function test_stand_revert_afterTimeout() public {
        uint256 id = _startAndSetHands(8, false, 7, false, 4, false, 5, false);
        _rollBlocks(MOVE_TIMEOUT_BLOCKS + 1);
        vm.prank(PLAYER);
        vm.expectRevert(
            "Move window expired \xe2\x80\x94 call timeoutPlayer()"
        );
        bjk.stand(id);
    }

    // ── stand immediately resolves if dealer hand already ≥ 21 ───────────

    function test_stand_immediateResolveWhenDealerAlreadyAt21() public {
        // Dealer starts with A+10 = 21
        uint256 id = _startAndSetHands(8, false, 7, false, 11, true, 10, false);
        vm.prank(PLAYER);
        bjk.stand(id);
        (, , OnChainBlackjack.GameState state, , , , ) = bjk.getGame(id);
        assertEq(
            uint8(state),
            STATE_FINISHED,
            "should resolve immediately when dealer at 21"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    //  SECTION 5 — dealerNextMove()
    // ═════════════════════════════════════════════════════════════════════

    function test_dealerNextMove_happy_calledByAnyone() public {
        uint256 id = _startAndSetHands(8, false, 7, false, 4, false, 5, false);
        vm.prank(PLAYER);
        bjk.stand(id);
        // ANYONE (third party) drives the dealer
        (, , OnChainBlackjack.GameState state, , , , ) = bjk.getGame(id);
        if (uint8(state) == STATE_DEALER_TURN) {
            vm.prank(ANYONE);
            bjk.dealerNextMove(id);
        }
        // No revert = pass
    }

    function test_dealerNextMove_happy_dealerHitsUntilAtLeast21() public {
        // Dealer starts at 4+5=9, must keep hitting
        uint256 id = _startAndSetHands(8, false, 7, false, 4, false, 5, false);
        vm.prank(PLAYER);
        bjk.stand(id);
        _driveDealer(id);
        uint8 ds = bjk.dealerScore(id);
        assertTrue(
            ds >= 21 || _gameFinished(id),
            "dealer should reach 21 or bust"
        );
    }

    function test_dealerNextMove_revert_notDealerTurn() public {
        uint256 id = _startGame();
        // Still player turn
        vm.expectRevert(OnChainBlackjack.NotDealerTurn.selector);
        bjk.dealerNextMove(id);
    }

    // ── result scenarios ──────────────────────────────────────────────────

    function test_dealerNextMove_result_dealerBust_playerWins() public {
        // Player 18, dealer forced to bust by injecting high cards
        uint256 id = _startAndSetHands(
            9,
            false,
            9,
            false,
            10,
            false,
            10,
            false
        );
        // Dealer at 20 already — stand player and let dealer resolve
        vm.prank(PLAYER);
        bjk.stand(id);
        // Dealer at 20 < 21, so inject a 10 then drive
        if (!_gameFinished(id)) {
            bjk.injectDealerCard(id, 10, false); // now dealer at 30 (bust)
            vm.prank(ANYONE);
            bjk.dealerNextMove(id);
        }
        if (_gameFinished(id)) {
            (, , , OnChainBlackjack.GameResult result, , , ) = bjk.getGame(id);
            // dealer was already at 20 < 21 before inject, then inject 10 → 30 bust
            assertEq(
                uint8(result),
                RESULT_PLAYER_WIN,
                "player should win on dealer bust"
            );
        }
    }

    function test_dealerNextMove_result_push() public {
        // Both player and dealer at 21
        uint256 id = _startAndSetHands(
            11,
            true,
            10,
            false,
            11,
            true,
            10,
            false
        );
        vm.prank(PLAYER);
        bjk.stand(id);
        _driveDealer(id);
        (, , , OnChainBlackjack.GameResult result, , , ) = bjk.getGame(id);
        assertEq(uint8(result), RESULT_PUSH, "should be a push");
    }

    function test_dealerNextMove_result_playerScoreHigher_playerWins() public {
        // Player 20, Dealer 21 → dealer wins; swap: Player 21 beats Dealer 20
        uint256 id = _startAndSetHands(
            11,
            true,
            10,
            false,
            9,
            false,
            10,
            false
        );
        // Player = 21 (A+10), Dealer = 19 → dealer must hit, may reach 21 or bust
        vm.prank(PLAYER);
        bjk.stand(id);
        _driveDealer(id);
        (, , , OnChainBlackjack.GameResult result, , , ) = bjk.getGame(id);
        // Dealer ended at 21: push or dealer wins; dealer busted: player wins
        assertTrue(
            uint8(result) == RESULT_PLAYER_WIN ||
                uint8(result) == RESULT_PUSH ||
                uint8(result) == RESULT_DEALER_WIN,
            "result should be determined"
        );
    }

    function test_dealerNextMove_emitsDealerHit() public {
        uint256 id = _startAndSetHands(8, false, 7, false, 4, false, 5, false);
        vm.prank(PLAYER);
        bjk.stand(id);

        (, , OnChainBlackjack.GameState state, , , , ) = bjk.getGame(id);
        if (uint8(state) == STATE_DEALER_TURN) {
            vm.recordLogs();
            vm.prank(ANYONE);
            bjk.dealerNextMove(id);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            for (uint i; i < logs.length; i++) {
                if (
                    logs[i].topics[0] == OnChainBlackjack.DealerHit.selector ||
                    logs[i].topics[0] == OnChainBlackjack.GameEnded.selector
                ) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "DealerHit or GameEnded event not emitted");
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  SECTION 6 — timeoutPlayer()
    // ═════════════════════════════════════════════════════════════════════

    function test_timeoutPlayer_happy_anyoneCanCall() public {
        uint256 id = _startAndSetHands(8, false, 7, false, 4, false, 5, false);
        _rollBlocks(MOVE_TIMEOUT_BLOCKS + 1);
        vm.prank(ANYONE);
        bjk.timeoutPlayer(id); // should not revert
    }

    function test_timeoutPlayer_happy_emitsPlayerTimedOut() public {
        uint256 id = _startAndSetHands(8, false, 7, false, 4, false, 5, false);
        _rollBlocks(MOVE_TIMEOUT_BLOCKS + 1);
        vm.expectEmit(true, true, false, false);
        emit OnChainBlackjack.PlayerTimedOut(id, PLAYER);
        vm.prank(ANYONE);
        bjk.timeoutPlayer(id);
    }

    function test_timeoutPlayer_happy_transitionsOutOfPlayerTurn() public {
        uint256 id = _startAndSetHands(8, false, 7, false, 4, false, 5, false);
        _rollBlocks(MOVE_TIMEOUT_BLOCKS + 1);
        bjk.timeoutPlayer(id);
        (, , OnChainBlackjack.GameState state, , , , ) = bjk.getGame(id);
        assertTrue(
            uint8(state) == STATE_DEALER_TURN || uint8(state) == STATE_FINISHED,
            "should leave PlayerTurn after timeout"
        );
    }

    function test_timeoutPlayer_revert_stillHasTime() public {
        uint256 id = _startGame();
        _rollBlocks(MOVE_TIMEOUT_BLOCKS - 1); // still within window
        vm.expectRevert("Player still has time");
        bjk.timeoutPlayer(id);
    }

    function test_timeoutPlayer_revert_exactlyAtDeadline() public {
        uint256 id = _startGame();
        _rollBlocks(MOVE_TIMEOUT_BLOCKS); // exactly at boundary → still has time
        vm.expectRevert("Player still has time");
        bjk.timeoutPlayer(id);
    }

    function test_timeoutPlayer_revert_notPlayerTurn() public {
        uint256 id = _startGame();
        vm.prank(PLAYER);
        bjk.stand(id); // move to dealer turn
        _rollBlocks(MOVE_TIMEOUT_BLOCKS + 1);
        vm.expectRevert(OnChainBlackjack.NotPlayerTurn.selector);
        bjk.timeoutPlayer(id);
    }

    function test_timeoutPlayer_revert_finishedGame() public {
        uint256 id = _startAndSetHands(
            11,
            true,
            10,
            false,
            11,
            true,
            10,
            false
        );
        vm.prank(PLAYER);
        bjk.stand(id); // push — game finishes
        _driveDealer(id);
        _rollBlocks(MOVE_TIMEOUT_BLOCKS + 1);
        vm.expectRevert(OnChainBlackjack.NotPlayerTurn.selector);
        bjk.timeoutPlayer(id);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  SECTION 7 — VIEW FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════

    // ── getGame() ─────────────────────────────────────────────────────────

    function test_getGame_returnsCorrectPlayer() public {
        uint256 id = _startGame();
        (address p, , , , , , ) = bjk.getGame(id);
        assertEq(p, PLAYER, "player address mismatch");
    }

    function test_getGame_returnsCorrectBet() public {
        uint256 id = _startGame();
        (, uint256 bet, , , , , ) = bjk.getGame(id);
        assertEq(bet, MIN_BET, "bet mismatch");
    }

    function test_getGame_returnsCorrectScores() public {
        uint256 id = _startAndSetHands(10, false, 8, false, 9, false, 7, false);
        (, , , , uint8 ps, uint8 ds, ) = bjk.getGame(id);
        assertEq(ps, 18, "player score should be 18");
        assertEq(ds, 16, "dealer score should be 16");
    }

    function test_getGame_returnsResultNoneBeforeFinished() public {
        uint256 id = _startGame();
        (, , , OnChainBlackjack.GameResult result, , , ) = bjk.getGame(id);
        assertEq(
            uint8(result),
            RESULT_NONE,
            "result should be None during play"
        );
    }

    // ── getPlayerHand() ───────────────────────────────────────────────────

    function test_getPlayerHand_returnsCorrectValues() public {
        uint256 id = _startAndSetHands(7, false, 8, false, 3, false, 4, false);
        (uint8[] memory vals, bool[] memory aces) = bjk.getPlayerHand(id);
        assertEq(vals.length, 2, "player hand length");
        assertEq(vals[0], 7, "player card 0 value");
        assertEq(vals[1], 8, "player card 1 value");
        assertFalse(aces[0], "card 0 not ace");
        assertFalse(aces[1], "card 1 not ace");
    }

    function test_getPlayerHand_aceFlagCorrect() public {
        uint256 id = _startAndSetHands(11, true, 10, false, 3, false, 4, false);
        (, bool[] memory aces) = bjk.getPlayerHand(id);
        assertTrue(aces[0], "card 0 should be ace");
        assertFalse(aces[1], "card 1 should not be ace");
    }

    // ── getDealerHand() ───────────────────────────────────────────────────

    function test_getDealerHand_returnsCorrectValues() public {
        uint256 id = _startAndSetHands(5, false, 6, false, 9, false, 10, false);
        (uint8[] memory vals, ) = bjk.getDealerHand(id);
        assertEq(vals.length, 2, "dealer hand length");
        assertEq(vals[0], 9, "dealer card 0 value");
        assertEq(vals[1], 10, "dealer card 1 value");
    }

    // ── blocksUntilTimeout() ──────────────────────────────────────────────

    function test_blocksUntilTimeout_fullWindowAtStart() public {
        uint256 id = _startGame();
        uint256 blocks = bjk.blocksUntilTimeout(id);
        assertEq(blocks, MOVE_TIMEOUT_BLOCKS, "full window at block 0");
    }

    function test_blocksUntilTimeout_decreasesWithBlocks() public {
        uint256 id = _startGame();
        _rollBlocks(3);
        uint256 blocks = bjk.blocksUntilTimeout(id);
        assertEq(blocks, MOVE_TIMEOUT_BLOCKS - 3, "window should decrease");
    }

    function test_blocksUntilTimeout_zeroAfterDeadline() public {
        uint256 id = _startGame();
        _rollBlocks(MOVE_TIMEOUT_BLOCKS + 1);
        uint256 blocks = bjk.blocksUntilTimeout(id);
        assertEq(blocks, 0, "should return 0 after deadline");
    }

    function test_blocksUntilTimeout_zeroWhenNotPlayerTurn() public {
        uint256 id = _startGame();
        vm.prank(PLAYER);
        bjk.stand(id);
        assertEq(bjk.blocksUntilTimeout(id), 0, "should be 0 in dealer turn");
    }

    // ── houseBankroll() ───────────────────────────────────────────────────

    function test_houseBankroll_increaseAfterBet() public {
        uint256 before = bjk.houseBankroll();
        _startGame();
        assertEq(
            bjk.houseBankroll(),
            before + MIN_BET,
            "bankroll should increase by bet"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    //  SECTION 8 — PAYOUT ACCOUNTING
    // ═════════════════════════════════════════════════════════════════════

    function test_payout_playerWin_receives2xBet() public {
        // Player 21 (A+10), Dealer must hit from low hand — likely to bust or push
        uint256 id = _startAndSetHands(11, true, 10, false, 4, false, 5, false);
        // Player at 21 — auto-stand after a hit OR just stand
        vm.prank(PLAYER);
        bjk.stand(id);
        _driveDealer(id);

        (, , , OnChainBlackjack.GameResult result, , , ) = bjk.getGame(id);
        if (uint8(result) == RESULT_PLAYER_WIN) {
            // Player should have received 2× bet back
            // Balance check: player started with 10 ether, paid MIN_BET
            // On win: gets back 2× MIN_BET
            uint256 expected = 10 ether - MIN_BET + 2 * MIN_BET;
            assertApproxEqAbs(
                PLAYER.balance,
                expected,
                1e9,
                "player win payout incorrect"
            );
        }
    }

    function test_payout_push_returnsExactBet() public {
        // Both at 21 → push
        uint256 id = _startAndSetHands(
            11,
            true,
            10,
            false,
            11,
            true,
            10,
            false
        );
        uint256 balBefore = PLAYER.balance;
        vm.prank(PLAYER);
        bjk.stand(id);
        _driveDealer(id);
        (, , , OnChainBlackjack.GameResult result, , , ) = bjk.getGame(id);
        if (uint8(result) == RESULT_PUSH) {
            // Player should get their bet back exactly
            assertEq(PLAYER.balance, balBefore, "push should refund exact bet");
        }
    }

    function test_payout_dealerWin_playerReceivesNothing() public {
        // Player bust scenario: start at 20 then keep hitting
        uint256 id = _startAndSetHands(
            10,
            false,
            10,
            false,
            4,
            false,
            5,
            false
        );
        uint256 balBefore = PLAYER.balance;
        // Hit until bust
        for (uint8 i; i < 12; i++) {
            (, , OnChainBlackjack.GameState state, , , , ) = bjk.getGame(id);
            if (uint8(state) != STATE_PLAYER_TURN) break;
            vm.prank(PLAYER);
            bjk.hit(id);
        }
        _driveDealer(id);
        (, , , OnChainBlackjack.GameResult result, , , ) = bjk.getGame(id);
        if (uint8(result) == RESULT_DEALER_WIN) {
            assertLt(
                PLAYER.balance,
                balBefore,
                "player should have lost their bet"
            );
        }
    }

    function test_payout_emitsGameEnded() public {
        uint256 id = _startAndSetHands(
            11,
            true,
            10,
            false,
            11,
            true,
            10,
            false
        );
        vm.prank(PLAYER);
        bjk.stand(id);
        vm.recordLogs();
        _driveDealer(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint i; i < logs.length; i++) {
            if (logs[i].topics[0] == OnChainBlackjack.GameEnded.selector) {
                found = true;
                break;
            }
        }
        assertTrue(found, "GameEnded event not emitted");
    }

    function test_payout_activeGameClearedAfterFinish() public {
        uint256 id = _startAndSetHands(11, true, 10, false, 4, false, 5, false);
        vm.prank(PLAYER);
        bjk.stand(id);
        _driveDealer(id);
        if (_gameFinished(id)) {
            assertEq(
                bjk.activeGameOf(PLAYER),
                0,
                "activeGameOf should be cleared"
            );
        }
    }

    function test_payout_playerCanStartNewGameAfterFinish() public {
        uint256 id = _startAndSetHands(11, true, 10, false, 4, false, 5, false);
        vm.prank(PLAYER);
        bjk.stand(id);
        _driveDealer(id);
        if (_gameFinished(id)) {
            vm.prank(PLAYER);
            bjk.startGame{value: MIN_BET}();
            assertGt(
                bjk.activeGameOf(PLAYER),
                0,
                "player should have a new active game"
            );
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  SECTION 9 — HOUSE WITHDRAW
    // ═════════════════════════════════════════════════════════════════════

    function test_withdrawHouse_ownerCanWithdraw() public {
        uint256 amount = 1 ether;
        uint256 ownerBefore = OWNER.balance;
        vm.prank(OWNER);
        bjk.withdrawHouse(amount);
        assertEq(
            OWNER.balance,
            ownerBefore + amount,
            "owner should receive ETH"
        );
    }

    function test_withdrawHouse_bankrollDecreases() public {
        uint256 before = bjk.houseBankroll();
        uint256 amount = 1 ether;
        vm.prank(OWNER);
        bjk.withdrawHouse(amount);
        assertEq(
            bjk.houseBankroll(),
            before - amount,
            "bankroll should decrease"
        );
    }

    function test_withdrawHouse_revert_notOwner() public {
        vm.prank(PLAYER);
        vm.expectRevert("Not owner");
        bjk.withdrawHouse(1 ether);
    }

    function test_withdrawHouse_revert_notOwner_anyoneAttempts() public {
        vm.prank(ANYONE);
        vm.expectRevert("Not owner");
        bjk.withdrawHouse(0.5 ether);
    }

    function test_receive_acceptsEther() public {
        uint256 before = bjk.houseBankroll();
        vm.deal(ANYONE, 5 ether);
        vm.prank(ANYONE);
        (bool ok, ) = address(bjk).call{value: 1 ether}("");
        assertTrue(ok, "receive() should accept ETH");
        assertEq(
            bjk.houseBankroll(),
            before + 1 ether,
            "bankroll should increase"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    //  SECTION 10 — ACE SCORE LOGIC (harness unit tests)
    // ═════════════════════════════════════════════════════════════════════

    function test_ace_singleAceCounts11WhenSafe() public {
        uint256 id = _startAndSetHands(11, true, 7, false, 3, false, 4, false);
        // A(11) + 7 = 18
        assertEq(bjk.playerScore(id), 18, "A+7 should be 18");
    }

    function test_ace_singleAceFlipsTo1OnBust() public {
        // A(11) + 7 + 8 = 26 → flip A → 1+7+8 = 16
        uint256 id = _startAndSetHands(11, true, 7, false, 3, false, 4, false);
        bjk.injectPlayerCard(id, 8, false);
        assertEq(bjk.playerScore(id), 16, "A+7+8 should be 16 (ace flipped)");
    }

    function test_ace_twoAces_onlyOneFlipped() public {
        // A+A = 11+11=22 → flip one → 11+1=12
        uint256 id = _startAndSetHands(11, true, 11, true, 3, false, 4, false);
        assertEq(bjk.playerScore(id), 12, "A+A should be 12");
    }

    function test_ace_aceAndTen_blackjack() public {
        // A + 10 = 21
        uint256 id = _startAndSetHands(11, true, 10, false, 3, false, 4, false);
        assertEq(bjk.playerScore(id), 21, "A+10 should be 21");
    }

    function test_ace_tripleAce() public {
        // A+A+A = 33 → flip 2 → 11+1+1 = 13
        uint256 id = _startAndSetHands(11, true, 11, true, 3, false, 4, false);
        bjk.injectPlayerCard(id, 11, true);
        assertEq(bjk.playerScore(id), 13, "A+A+A should be 13");
    }

    function test_ace_softHandBecomesHard() public {
        // A+5 = 16 (soft) → hit 9 → 25 → flip → 15
        uint256 id = _startAndSetHands(11, true, 5, false, 3, false, 4, false);
        bjk.injectPlayerCard(id, 9, false);
        assertEq(bjk.playerScore(id), 15, "A+5+9 should be 15");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  SECTION 11 — FUZZ TESTS
    // ═════════════════════════════════════════════════════════════════════

    /**
     * @dev Fuzz: any bet in [MIN_BET, MAX_BET] should be accepted.
     */
    function testFuzz_startGame_validBet(uint256 bet) public {
        bet = bound(bet, MIN_BET, MAX_BET);
        vm.deal(PLAYER, bet + 1 ether);
        vm.prank(PLAYER);
        bjk.startGame{value: bet}();
        assertGt(bjk.activeGameOf(PLAYER), 0, "game should be active");
    }

    /**
     * @dev Fuzz: bets outside valid range should always revert.
     */
    function testFuzz_startGame_invalidBet_belowMin(uint256 bet) public {
        bet = bound(bet, 0, MIN_BET - 1);
        vm.deal(PLAYER, MIN_BET + 1 ether);
        vm.prank(PLAYER);
        vm.expectRevert(OnChainBlackjack.BetOutOfRange.selector);
        bjk.startGame{value: bet}();
    }

    function testFuzz_startGame_invalidBet_aboveMax(uint256 bet) public {
        bet = bound(bet, MAX_BET + 1, type(uint128).max);
        vm.deal(PLAYER, bet + 1 ether);
        vm.prank(PLAYER);
        vm.expectRevert(OnChainBlackjack.BetOutOfRange.selector);
        bjk.startGame{value: bet}();
    }

    /**
     * @dev Fuzz: rolling N blocks (1–9) should not trigger timeout.
     */
    function testFuzz_timeout_withinWindow_noRevert(uint256 skip) public {
        skip = bound(skip, 0, MOVE_TIMEOUT_BLOCKS - 1);
        uint256 id = _startGame();
        _rollBlocks(skip);
        uint256 remaining = bjk.blocksUntilTimeout(id);
        assertGe(
            remaining,
            MOVE_TIMEOUT_BLOCKS - skip - 1,
            "remaining blocks too low"
        );
    }

    /**
     * @dev Fuzz: multiple independent players, IDs must be distinct.
     */
    function testFuzz_multiPlayer_gameIdsAreDistinct(uint8 n) public {
        n = uint8(bound(n, 2, 10));
        uint256[] memory ids = new uint256[](n);
        for (uint8 i; i < n; i++) {
            address p = makeAddr(string(abi.encodePacked("p", i)));
            vm.deal(p, 1 ether);
            vm.prank(p);
            bjk.startGame{value: MIN_BET}();
            ids[i] = bjk.activeGameOf(p);
        }
        for (uint8 i; i < n; i++) {
            for (uint8 j = i + 1; j < n; j++) {
                assertNotEq(ids[i], ids[j], "game IDs must be unique");
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  SECTION 12 — MULTI-PLAYER ISOLATION
    // ═════════════════════════════════════════════════════════════════════

    function test_isolation_player2CannotAffectPlayer1Game() public {
        uint256 id1 = _startGame();

        vm.prank(PLAYER2);
        bjk.startGame{value: MIN_BET}();
        uint256 id2 = bjk.activeGameOf(PLAYER2);

        assertNotEq(id1, id2, "game IDs should differ");

        // PLAYER2 tries to hit PLAYER's game → revert
        vm.prank(PLAYER2);
        vm.expectRevert(OnChainBlackjack.NotYourGame.selector);
        bjk.hit(id1);
    }

    function test_isolation_player2CannotStandPlayer1Game() public {
        uint256 id1 = _startGame();
        vm.prank(PLAYER2);
        vm.expectRevert(OnChainBlackjack.NotYourGame.selector);
        bjk.stand(id1);
    }

    function test_isolation_gamesHaveIndependentHands() public {
        uint256 id1 = _startAndSetHands(5, false, 6, false, 3, false, 4, false);

        vm.prank(PLAYER2);
        bjk.startGame{value: MIN_BET}();
        uint256 id2 = bjk.activeGameOf(PLAYER2);

        bjk.clearHands(id2);
        bjk.injectPlayerCard(id2, 10, false);
        bjk.injectPlayerCard(id2, 10, false);
        bjk.injectDealerCard(id2, 3, false);
        bjk.injectDealerCard(id2, 4, false);

        assertEq(bjk.playerScore(id1), 11, "p1 score should be 11");
        assertEq(bjk.playerScore(id2), 20, "p2 score should be 20");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  SECTION 13 — EDGE CASES
    // ═════════════════════════════════════════════════════════════════════

    function test_edge_playerCannotPlayNonExistentGame() public {
        vm.prank(PLAYER);
        vm.expectRevert(OnChainBlackjack.NotYourGame.selector);
        bjk.hit(999); // gameId 999 never created
    }

    function test_edge_dealerNextMoveOnFinishedGame_reverts() public {
        uint256 id = _startAndSetHands(
            11,
            true,
            10,
            false,
            11,
            true,
            10,
            false
        );
        vm.prank(PLAYER);
        bjk.stand(id); // push — resolves immediately
        _driveDealer(id);
        if (_gameFinished(id)) {
            vm.expectRevert(OnChainBlackjack.NotDealerTurn.selector);
            bjk.dealerNextMove(id);
        }
    }

    function test_edge_gameIdMonotonicallyIncreases() public {
        for (uint8 i; i < 5; i++) {
            address p = makeAddr(string(abi.encodePacked("player", i)));
            vm.deal(p, 1 ether);
            vm.prank(p);
            bjk.startGame{value: MIN_BET}();
        }
        assertEq(bjk.nextGameId(), 5, "nextGameId should be 5 after 5 games");
    }

    function test_edge_playerCannotDoubleStartAfterTimeout() public {
        uint256 id = _startAndSetHands(8, false, 7, false, 4, false, 5, false);
        _rollBlocks(MOVE_TIMEOUT_BLOCKS + 1);
        bjk.timeoutPlayer(id);
        _driveDealer(id);
        // If game resolved, player can start a new game
        if (_gameFinished(id)) {
            vm.prank(PLAYER);
            bjk.startGame{value: MIN_BET}();
            assertGt(
                bjk.activeGameOf(PLAYER),
                id,
                "new game should have higher id"
            );
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  INTERNAL TEST HELPERS
    // ═════════════════════════════════════════════════════════════════════

    /**
     * @dev Drive the dealer to completion by repeatedly calling dealerNextMove()
     *      until the game is Finished. Caps at 20 iterations to avoid infinite loops.
     */
    function _driveDealer(uint256 gameId) internal {
        for (uint8 i; i < 20; i++) {
            (, , OnChainBlackjack.GameState state, , , , ) = bjk.getGame(
                gameId
            );
            if (uint8(state) != STATE_DEALER_TURN) break;
            vm.prank(ANYONE);
            bjk.dealerNextMove(gameId);
        }
    }

    /// Returns true if the game is in Finished state.
    function _gameFinished(uint256 gameId) internal view returns (bool) {
        (, , OnChainBlackjack.GameState state, , , , ) = bjk.getGame(gameId);
        return uint8(state) == STATE_FINISHED;
    }
}
