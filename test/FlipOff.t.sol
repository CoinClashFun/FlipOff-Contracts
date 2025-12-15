// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FlipOff.sol";
import "@pythnetwork/entropy-sdk-solidity/MockEntropy.sol";

contract FlipOffTest is Test {
    FlipOff public flipOff;
    MockEntropy public mockEntropy;
    
    address public owner = address(this);
    address public treasury = address(0x1234567890123456789012345678901234567890);
    
    address public player1 = address(0x1);
    address public player2 = address(0x2);
    address public player3 = address(0x3);
    address public player4 = address(0x4);
    
    uint256 constant BET_AMOUNT = 100 ether; // Match mainnet MIN_BET
    
    event LobbyCreated(
        uint256 indexed gameId,
        address indexed creator,
        uint256 teamSize,
        uint256 roundsToWin,
        uint256 betAmount
    );
    
    event PlayerJoined(
        uint256 indexed gameId,
        address indexed player,
        FlipOff.Team team,
        uint256 teamCount
    );
    
    event GameStarted(uint256 indexed gameId);
    event RoundResolved(
        uint256 indexed gameId,
        uint256 round,
        FlipOff.Team roundWinner,
        uint256 headsScore,
        uint256 tailsScore
    );
    event GameFinished(
        uint256 indexed gameId,
        FlipOff.Team winner,
        uint256 finalHeadsScore,
        uint256 finalTailsScore
    );
    
    function setUp() public {
        // Deploy mock entropy with default provider
        address defaultProvider = address(0xDEADBEEF);
        mockEntropy = new MockEntropy(defaultProvider);
        
        // Deploy FlipOff
        flipOff = new FlipOff(address(mockEntropy), treasury);
        
        // Fund test accounts (with enough for mainnet bets)
        vm.deal(player1, 10000 ether);
        vm.deal(player2, 10000 ether);
        vm.deal(player3, 10000 ether);
        vm.deal(player4, 10000 ether);
        vm.deal(address(flipOff), 100 ether);
    }
    
    // ============ Lobby Creation Tests ============
    
    function test_CreateLobby() public {
        vm.prank(player1);
        
        vm.expectEmit(true, true, false, true);
        emit LobbyCreated(1, player1, 1, 1, BET_AMOUNT);
        
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        assertEq(gameId, 1);
        
        FlipOff.Lobby memory lobby = flipOff.getLobby(gameId);
        assertEq(lobby.creator, player1);
        assertEq(lobby.teamSize, 1);
        assertEq(lobby.roundsToWin, 1);
        assertEq(lobby.betAmount, BET_AMOUNT);
        assertEq(uint256(lobby.state), uint256(FlipOff.GameState.OPEN));
    }
    
    function test_CreateLobby_WithTeamSize5() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(5, 3, FlipOff.Team.HEADS);
        
        FlipOff.Lobby memory lobby = flipOff.getLobby(gameId);
        assertEq(lobby.teamSize, 5);
        assertEq(lobby.roundsToWin, 3);
    }
    
    function test_RevertIf_BetTooLow() public {
        vm.prank(player1);
        vm.expectRevert(FlipOff.BetTooLow.selector);
        flipOff.createLobby{value: 0.001 ether}(1, 1, FlipOff.Team.HEADS);
    }
    
    function test_RevertIf_InvalidTeamSize() public {
        vm.prank(player1);
        vm.expectRevert(FlipOff.InvalidTeamSize.selector);
        flipOff.createLobby{value: BET_AMOUNT}(0, 1, FlipOff.Team.HEADS);
        
        vm.prank(player1);
        vm.expectRevert(FlipOff.InvalidTeamSize.selector);
        flipOff.createLobby{value: BET_AMOUNT}(6, 1, FlipOff.Team.HEADS);
    }
    
    function test_RevertIf_InvalidRoundsToWin() public {
        vm.prank(player1);
        vm.expectRevert(FlipOff.InvalidRoundsToWin.selector);
        flipOff.createLobby{value: BET_AMOUNT}(1, 0, FlipOff.Team.HEADS);
        
        vm.prank(player1);
        vm.expectRevert(FlipOff.InvalidRoundsToWin.selector);
        flipOff.createLobby{value: BET_AMOUNT}(1, 6, FlipOff.Team.HEADS);
    }
    
    // ============ Join Lobby Tests ============
    
    function test_JoinLobby() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        vm.prank(player2);
        vm.expectEmit(true, true, false, true);
        emit PlayerJoined(gameId, player2, FlipOff.Team.TAILS, 1);
        flipOff.joinLobby{value: BET_AMOUNT}(gameId, FlipOff.Team.TAILS);
        
        FlipOff.Lobby memory lobby = flipOff.getLobby(gameId);
        assertEq(uint256(lobby.state), uint256(FlipOff.GameState.FULL));
    }
    
    function test_JoinLobby_SameTeam() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(2, 1, FlipOff.Team.HEADS);
        
        vm.prank(player2);
        flipOff.joinLobby{value: BET_AMOUNT}(gameId, FlipOff.Team.HEADS);
        
        FlipOff.Lobby memory lobby = flipOff.getLobby(gameId);
        assertEq(uint256(lobby.state), uint256(FlipOff.GameState.OPEN));
        
        vm.prank(player3);
        flipOff.joinLobby{value: BET_AMOUNT}(gameId, FlipOff.Team.TAILS);
        
        vm.prank(player4);
        flipOff.joinLobby{value: BET_AMOUNT}(gameId, FlipOff.Team.TAILS);
        
        lobby = flipOff.getLobby(gameId);
        assertEq(uint256(lobby.state), uint256(FlipOff.GameState.FULL));
    }
    
    function test_RevertIf_TeamFull() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        vm.prank(player2);
        vm.expectRevert(FlipOff.TeamFull.selector);
        flipOff.joinLobby{value: BET_AMOUNT}(gameId, FlipOff.Team.HEADS);
    }
    
    function test_RevertIf_AlreadyJoined() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(2, 1, FlipOff.Team.HEADS);
        
        vm.prank(player1);
        vm.expectRevert(FlipOff.AlreadyJoined.selector);
        flipOff.joinLobby{value: BET_AMOUNT}(gameId, FlipOff.Team.HEADS);
    }
    
    function test_RevertIf_IncorrectPayment() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        vm.prank(player2);
        vm.expectRevert(FlipOff.IncorrectPayment.selector);
        flipOff.joinLobby{value: BET_AMOUNT + 1 ether}(gameId, FlipOff.Team.TAILS);
    }
    
    // ============ Game Flow Tests ============
    
    function test_StartGame() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        vm.prank(player2);
        flipOff.joinLobby{value: BET_AMOUNT}(gameId, FlipOff.Team.TAILS);
        
        vm.expectEmit(true, false, false, true);
        emit GameStarted(gameId);
        flipOff.startGame{value: 0}(gameId);
        
        FlipOff.Lobby memory lobby = flipOff.getLobby(gameId);
        assertEq(uint256(lobby.state), uint256(FlipOff.GameState.IN_PROGRESS));
        assertTrue(lobby.entropyRequested);
    }
    
    function test_FullGameFlow_Bo1_HeadsWins() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        vm.prank(player2);
        flipOff.joinLobby{value: BET_AMOUNT}(gameId, FlipOff.Team.TAILS);
        
        flipOff.startGame{value: 0}(gameId);
        
        FlipOff.Lobby memory lobby = flipOff.getLobby(gameId);
        uint64 seqNum = lobby.pendingEntropySeq;
        
        bytes32 randomNumber = bytes32(uint256(0)); // Even = HEADS
        mockEntropy.mockReveal(address(0xDEADBEEF), seqNum, randomNumber);
        
        lobby = flipOff.getLobby(gameId);
        assertEq(uint256(lobby.state), uint256(FlipOff.GameState.FINISHED));
        assertEq(uint256(lobby.winner), uint256(FlipOff.Team.HEADS));
        assertEq(lobby.headsScore, 1);
        assertEq(lobby.tailsScore, 0);
    }
    
    function test_FullGameFlow_Bo1_TailsWins() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        vm.prank(player2);
        flipOff.joinLobby{value: BET_AMOUNT}(gameId, FlipOff.Team.TAILS);
        
        flipOff.startGame{value: 0}(gameId);
        
        FlipOff.Lobby memory lobby = flipOff.getLobby(gameId);
        uint64 seqNum = lobby.pendingEntropySeq;
        
        bytes32 randomNumber = bytes32(uint256(1)); // Odd = TAILS
        mockEntropy.mockReveal(address(0xDEADBEEF), seqNum, randomNumber);
        
        lobby = flipOff.getLobby(gameId);
        assertEq(uint256(lobby.state), uint256(FlipOff.GameState.FINISHED));
        assertEq(uint256(lobby.winner), uint256(FlipOff.Team.TAILS));
        assertEq(lobby.headsScore, 0);
        assertEq(lobby.tailsScore, 1);
    }
    
    function test_FullGameFlow_Bo3() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 2, FlipOff.Team.HEADS);
        
        vm.prank(player2);
        flipOff.joinLobby{value: BET_AMOUNT}(gameId, FlipOff.Team.TAILS);
        
        flipOff.startGame{value: 0}(gameId);
        
        // Round 1: HEADS wins (even)
        FlipOff.Lobby memory lobby = flipOff.getLobby(gameId);
        mockEntropy.mockReveal(address(0xDEADBEEF), lobby.pendingEntropySeq, bytes32(uint256(0)));
        
        lobby = flipOff.getLobby(gameId);
        assertEq(lobby.headsScore, 1);
        assertEq(lobby.tailsScore, 0);
        assertEq(uint256(lobby.state), uint256(FlipOff.GameState.IN_PROGRESS));
        
        // Request next round
        flipOff.requestNextRound{value: 0}(gameId);
        
        // Round 2: TAILS wins (odd)
        lobby = flipOff.getLobby(gameId);
        mockEntropy.mockReveal(address(0xDEADBEEF), lobby.pendingEntropySeq, bytes32(uint256(1)));
        
        lobby = flipOff.getLobby(gameId);
        assertEq(lobby.headsScore, 1);
        assertEq(lobby.tailsScore, 1);
        assertEq(uint256(lobby.state), uint256(FlipOff.GameState.IN_PROGRESS));
        
        // Request next round
        flipOff.requestNextRound{value: 0}(gameId);
        
        // Round 3: HEADS wins (even)
        lobby = flipOff.getLobby(gameId);
        mockEntropy.mockReveal(address(0xDEADBEEF), lobby.pendingEntropySeq, bytes32(uint256(2)));
        
        lobby = flipOff.getLobby(gameId);
        assertEq(lobby.headsScore, 2);
        assertEq(lobby.tailsScore, 1);
        assertEq(uint256(lobby.state), uint256(FlipOff.GameState.FINISHED));
        assertEq(uint256(lobby.winner), uint256(FlipOff.Team.HEADS));
    }
    
    // ============ Claim Tests ============
    
    function test_ClaimWinnings() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        vm.prank(player2);
        flipOff.joinLobby{value: BET_AMOUNT}(gameId, FlipOff.Team.TAILS);
        
        flipOff.startGame{value: 0}(gameId);
        
        FlipOff.Lobby memory lobby = flipOff.getLobby(gameId);
        mockEntropy.mockReveal(address(0xDEADBEEF), lobby.pendingEntropySeq, bytes32(uint256(0)));
        
        // Calculate expected payout (95% of pot with 5% fee)
        uint256 totalPot = BET_AMOUNT * 2;
        uint256 houseFee = (totalPot * 500) / 10000; // 5%
        uint256 expectedPayout = totalPot - houseFee;
        
        uint256 balanceBefore = player1.balance;
        
        vm.prank(player1);
        flipOff.claimWinnings(gameId);
        
        uint256 balanceAfter = player1.balance;
        assertEq(balanceAfter - balanceBefore, expectedPayout);
    }
    
    function test_RevertIf_NotWinner_Claims() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        vm.prank(player2);
        flipOff.joinLobby{value: BET_AMOUNT}(gameId, FlipOff.Team.TAILS);
        
        flipOff.startGame{value: 0}(gameId);
        
        FlipOff.Lobby memory lobby = flipOff.getLobby(gameId);
        mockEntropy.mockReveal(address(0xDEADBEEF), lobby.pendingEntropySeq, bytes32(uint256(0)));
        
        vm.prank(player2);
        vm.expectRevert(FlipOff.NotWinner.selector);
        flipOff.claimWinnings(gameId);
    }
    
    function test_RevertIf_DoubleClaim() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        vm.prank(player2);
        flipOff.joinLobby{value: BET_AMOUNT}(gameId, FlipOff.Team.TAILS);
        
        flipOff.startGame{value: 0}(gameId);
        
        FlipOff.Lobby memory lobby = flipOff.getLobby(gameId);
        mockEntropy.mockReveal(address(0xDEADBEEF), lobby.pendingEntropySeq, bytes32(uint256(0)));
        
        vm.prank(player1);
        flipOff.claimWinnings(gameId);
        
        vm.prank(player1);
        vm.expectRevert(FlipOff.AlreadyClaimed.selector);
        flipOff.claimWinnings(gameId);
    }
    
    // ============ Void Tests ============
    
    function test_VoidLobby() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        vm.roll(block.number + 1001);
        
        flipOff.voidLobby(gameId);
        
        FlipOff.Lobby memory lobby = flipOff.getLobby(gameId);
        assertEq(uint256(lobby.state), uint256(FlipOff.GameState.VOID));
    }
    
    function test_CancelLobby_ByCreator() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        vm.prank(player1);
        flipOff.cancelLobby(gameId);
        
        FlipOff.Lobby memory lobby = flipOff.getLobby(gameId);
        assertEq(uint256(lobby.state), uint256(FlipOff.GameState.VOID));
    }
    
    function test_RevertIf_CancelLobby_NotCreator() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        vm.prank(player2);
        vm.expectRevert(FlipOff.NotCreator.selector);
        flipOff.cancelLobby(gameId);
    }
    
    function test_RevertIf_VoidTooEarly() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        vm.expectRevert(FlipOff.CannotVoidYet.selector);
        flipOff.voidLobby(gameId);
    }
    
    function test_WithdrawVoid() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        vm.roll(block.number + 1001);
        flipOff.voidLobby(gameId);
        
        uint256 balanceBefore = player1.balance;
        
        vm.prank(player1);
        flipOff.withdrawVoid(gameId);
        
        uint256 balanceAfter = player1.balance;
        assertEq(balanceAfter - balanceBefore, BET_AMOUNT);
    }
    
    // ============ Admin Tests ============
    
    function test_SetFee() public {
        uint256 newFee = 300; // 3%
        flipOff.setFee(newFee);
        assertEq(flipOff.feeBps(), newFee);
    }
    
    function test_RevertIf_SetFeeTooHigh() public {
        vm.expectRevert(FlipOff.FeeTooHigh.selector);
        flipOff.setFee(600); // 6% > 5% max
    }
    
    function test_SetTreasury() public {
        address newTreasury = address(0x9999);
        flipOff.setTreasury(newTreasury);
        assertEq(flipOff.treasury(), newTreasury);
    }
    
    function test_RevertIf_SetTreasuryZero() public {
        vm.expectRevert(FlipOff.InvalidAddress.selector);
        flipOff.setTreasury(address(0));
    }
    
    // ============ View Function Tests ============
    
    function test_GetPlayerInfo() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        (bool isPlayer, FlipOff.Team team, bool hasClaimed) = flipOff.getPlayerInfo(gameId, player1);
        assertTrue(isPlayer);
        assertEq(uint256(team), uint256(FlipOff.Team.HEADS));
        assertFalse(hasClaimed);
        
        (isPlayer, team, hasClaimed) = flipOff.getPlayerInfo(gameId, player2);
        assertFalse(isPlayer);
    }
    
    function test_CanVoid() public {
        vm.prank(player1);
        uint256 gameId = flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        assertFalse(flipOff.canVoid(gameId));
        
        vm.roll(block.number + 1001);
        assertTrue(flipOff.canVoid(gameId));
    }
    
    function test_GetLobbyStats() public {
        vm.prank(player1);
        flipOff.createLobby{value: BET_AMOUNT}(1, 1, FlipOff.Team.HEADS);
        
        vm.prank(player2);
        flipOff.createLobby{value: BET_AMOUNT * 2}(1, 1, FlipOff.Team.HEADS);
        
        (uint256 totalGames, uint256 totalVolume) = flipOff.getLobbyStats();
        assertEq(totalGames, 2);
        assertEq(totalVolume, BET_AMOUNT * 3);
    }
}
