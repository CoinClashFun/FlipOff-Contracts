// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyV2.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyConsumer.sol";

/**
 * @title FlipOff
 * @notice A trustless coin flip betting game using Pyth Entropy for verifiable randomness
 * @dev Part of CoinClash - Onchain, trustless, provably fair games.
 *      Players bet on HEADS or TAILS. Winner takes 95% of pot. Protocol takes 5%.
 *      Anyone can trigger game start and rounds by paying the entropy fee.
 */
contract FlipOff is IEntropyConsumer, ReentrancyGuard, Ownable {
    // ============ Enums ============
    
    enum GameState {
        OPEN,           // Lobby accepting players
        FULL,           // All slots filled, awaiting game start
        IN_PROGRESS,    // Coin flips happening
        FINISHED,       // Winner determined, claims open
        VOID            // Lobby expired/stuck, refunds available
    }

    enum Team {
        NONE,
        HEADS,
        TAILS
    }

    // ============ Structs ============

    struct Player {
        address addr;
        Team team;
        bool hasClaimed;
    }

    struct Round {
        uint256 roundNumber;
        uint64 sequenceNumber;
        Team winner;
        bool resolved;
    }

    struct Lobby {
        uint256 id;
        address creator;
        uint256 teamSize;           // Players per team
        uint256 roundsToWin;        // e.g., 2 for Bo3, 3 for Bo5
        uint256 betAmount;          // Stake per player in wei
        GameState state;
        uint256 createdBlock;
        uint256 headsScore;
        uint256 tailsScore;
        Team winner;
        uint256 currentRound;
        uint64 pendingEntropySeq;   // Pending entropy request sequence
        bool entropyRequested;      // Whether entropy is currently requested
    }

    // ============ Constants ============

    uint256 public constant MAX_FEE_BPS = 500;            // 5% maximum protocol fee
    uint256 public constant MIN_BET = 100 ether;          // Minimum bet amount (100 MON)
    uint256 public constant VOID_BLOCK_THRESHOLD = 1000;  // Blocks until OPEN lobby can be voided
    uint256 public constant STUCK_GAME_THRESHOLD = 3000;  // Blocks until IN_PROGRESS game can be voided
    uint32 public constant CALLBACK_GAS_LIMIT = 1_000_000; // Pyth default for Monad mainnet

    // ============ State Variables ============

    IEntropyV2 public immutable entropy;
    address public treasury;
    uint256 public feeBps;
    
    uint256 public nextGameId;
    uint256 public totalGamesCreated;
    uint256 public totalVolumeStaked;
    
    // gameId => Lobby
    mapping(uint256 => Lobby) public lobbies;
    
    // gameId => players array
    mapping(uint256 => Player[]) public gamePlayers;
    
    // gameId => rounds array
    mapping(uint256 => Round[]) public gameRounds;
    
    // gameId => player address => player index + 1 (0 means not joined)
    mapping(uint256 => mapping(address => uint256)) public playerIndex;
    
    // gameId => team => player count
    mapping(uint256 => mapping(Team => uint256)) public teamPlayerCount;
    
    // entropySeq => gameId (for callback mapping)
    mapping(uint64 => uint256) public entropyToGame;
    
    // House fees accumulator
    uint256 public accumulatedHouseFees;

    // ============ Events ============

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
        Team team,
        uint256 teamCount
    );
    
    event GameStarted(uint256 indexed gameId);
    
    event EntropyRequested(
        uint256 indexed gameId,
        uint64 sequenceNumber,
        uint256 round
    );
    
    event RoundResolved(
        uint256 indexed gameId,
        uint256 round,
        Team roundWinner,
        uint256 headsScore,
        uint256 tailsScore
    );
    
    event GameFinished(
        uint256 indexed gameId,
        Team winner,
        uint256 finalHeadsScore,
        uint256 finalTailsScore
    );
    
    event WinningsClaimed(
        uint256 indexed gameId,
        address indexed player,
        uint256 amount
    );
    
    event LobbyVoided(uint256 indexed gameId);
    
    event RefundClaimed(
        uint256 indexed gameId,
        address indexed player,
        uint256 amount
    );
    
    event HouseFeesWithdrawn(address indexed to, uint256 amount);
    
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    
    event FeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    // ============ Errors ============

    error InvalidTeamSize();
    error InvalidRoundsToWin();
    error BetTooLow();
    error LobbyNotFound();
    error LobbyNotOpen();
    error TeamFull();
    error InvalidTeam();
    error AlreadyJoined();
    error IncorrectPayment();
    error NotInProgress();
    error EntropyAlreadyRequested();
    error EntropyNotRequested();
    error GameNotFinished();
    error NotWinner();
    error AlreadyClaimed();
    error LobbyNotVoid();
    error CannotVoidYet();
    error NoFeesToWithdraw();
    error InvalidEntropySequence();
    error InsufficientEntropyFee();
    error InvalidAddress();
    error FeeTooHigh();
    error NotCreator();
    error OtherPlayersJoined();
    error LobbyNotFull();

    // ============ Constructor ============

    constructor(address _entropy, address _treasury) Ownable(msg.sender) {
        if (_entropy == address(0)) revert InvalidAddress();
        if (_treasury == address(0)) revert InvalidAddress();
        
        entropy = IEntropyV2(_entropy);
        treasury = _treasury;
        feeBps = 500; // Start at 5%
        nextGameId = 1;
    }

    // ============ External Functions ============

    /**
     * @notice Create a new game lobby
     * @param teamSize Number of players per team (1-5)
     * @param roundsToWin Rounds needed to win (1 for Bo1, 2 for Bo3, etc.)
     * @param creatorTeam The team the creator joins (HEADS or TAILS)
     * @return gameId The ID of the created lobby
     */
    function createLobby(
        uint256 teamSize,
        uint256 roundsToWin,
        Team creatorTeam
    ) external payable nonReentrant returns (uint256 gameId) {
        if (teamSize == 0 || teamSize > 5) revert InvalidTeamSize();
        if (roundsToWin == 0 || roundsToWin > 5) revert InvalidRoundsToWin();
        if (creatorTeam != Team.HEADS && creatorTeam != Team.TAILS) revert InvalidTeam();
        if (msg.value < MIN_BET) revert BetTooLow();

        gameId = nextGameId++;
        
        Lobby storage lobby = lobbies[gameId];
        lobby.id = gameId;
        lobby.creator = msg.sender;
        lobby.teamSize = teamSize;
        lobby.roundsToWin = roundsToWin;
        lobby.betAmount = msg.value;
        lobby.state = GameState.OPEN;
        lobby.createdBlock = block.number;
        lobby.currentRound = 1;

        // Creator auto-joins chosen team
        _addPlayer(gameId, msg.sender, creatorTeam);
        
        emit PlayerJoined(gameId, msg.sender, creatorTeam, 1);

        totalGamesCreated++;
        totalVolumeStaked += msg.value;

        emit LobbyCreated(gameId, msg.sender, teamSize, roundsToWin, msg.value);
    }

    /**
     * @notice Join an existing lobby
     * @param gameId The lobby ID to join
     * @param team The team to join (HEADS or TAILS)
     */
    function joinLobby(uint256 gameId, Team team) external payable nonReentrant {
        Lobby storage lobby = lobbies[gameId];
        
        if (lobby.creator == address(0)) revert LobbyNotFound();
        if (lobby.state != GameState.OPEN) revert LobbyNotOpen();
        if (team != Team.HEADS && team != Team.TAILS) revert InvalidTeam();
        if (playerIndex[gameId][msg.sender] != 0) revert AlreadyJoined();
        if (msg.value != lobby.betAmount) revert IncorrectPayment();
        
        uint256 currentTeamCount = teamPlayerCount[gameId][team];
        if (currentTeamCount >= lobby.teamSize) revert TeamFull();

        _addPlayer(gameId, msg.sender, team);
        totalVolumeStaked += msg.value;

        // Check if lobby is now full
        uint256 headsCount = teamPlayerCount[gameId][Team.HEADS];
        uint256 tailsCount = teamPlayerCount[gameId][Team.TAILS];
        
        if (headsCount == lobby.teamSize && tailsCount == lobby.teamSize) {
            lobby.state = GameState.FULL;
        }

        emit PlayerJoined(gameId, msg.sender, team, teamPlayerCount[gameId][team]);
    }

    /**
     * @notice Start the game by requesting entropy (anyone can call once lobby is full)
     * @dev Caller must pay the Pyth Entropy fee (check getEntropyFee())
     * @param gameId The lobby ID to start
     */
    function startGame(uint256 gameId) external payable nonReentrant {
        Lobby storage lobby = lobbies[gameId];
        
        if (lobby.state != GameState.FULL) revert LobbyNotFull();
        
        // Verify caller sent enough for entropy fee
        uint256 fee = entropy.getFeeV2(CALLBACK_GAS_LIMIT);
        if (msg.value < fee) revert InsufficientEntropyFee();
        
        lobby.state = GameState.IN_PROGRESS;
        emit GameStarted(gameId);
        
        _requestEntropyWithFee(gameId, fee);
        
        // Refund excess
        if (msg.value > fee) {
            (bool success, ) = msg.sender.call{value: msg.value - fee}("");
            require(success, "Refund failed");
        }
    }

    /**
     * @notice Request entropy for the next round (if previous round resolved)
     * @dev Caller must pay the Pyth Entropy fee (check getEntropyFee())
     * @param gameId The lobby ID
     */
    function requestNextRound(uint256 gameId) external payable nonReentrant {
        Lobby storage lobby = lobbies[gameId];
        
        if (lobby.state != GameState.IN_PROGRESS) revert NotInProgress();
        if (lobby.entropyRequested) revert EntropyAlreadyRequested();
        
        // Verify caller sent enough for entropy fee
        uint256 fee = entropy.getFeeV2(CALLBACK_GAS_LIMIT);
        if (msg.value < fee) revert InsufficientEntropyFee();
        
        _requestEntropyWithFee(gameId, fee);
        
        // Refund excess
        if (msg.value > fee) {
            (bool success, ) = msg.sender.call{value: msg.value - fee}("");
            require(success, "Refund failed");
        }
    }

    /**
     * @notice Cancel a lobby (only creator, only if no other players joined)
     * @param gameId The lobby ID to cancel
     */
    function cancelLobby(uint256 gameId) external nonReentrant {
        Lobby storage lobby = lobbies[gameId];
        
        if (lobby.creator != msg.sender) revert NotCreator();
        if (lobby.state != GameState.OPEN) revert LobbyNotOpen();
        if (gamePlayers[gameId].length > 1) revert OtherPlayersJoined();
        
        lobby.state = GameState.VOID;
        
        emit LobbyVoided(gameId);
    }

    /**
     * @notice Void an OPEN lobby if it hasn't filled within block threshold
     * @param gameId The lobby ID to void
     */
    function voidLobby(uint256 gameId) external nonReentrant {
        Lobby storage lobby = lobbies[gameId];
        
        if (lobby.state != GameState.OPEN) revert LobbyNotOpen();
        if (block.number <= lobby.createdBlock + VOID_BLOCK_THRESHOLD) revert CannotVoidYet();
        
        lobby.state = GameState.VOID;
        
        emit LobbyVoided(gameId);
    }

    /**
     * @notice Claim winnings after game is finished (for winning team)
     * @param gameId The lobby ID to claim from
     */
    function claimWinnings(uint256 gameId) external nonReentrant {
        Lobby storage lobby = lobbies[gameId];
        
        if (lobby.state != GameState.FINISHED) revert GameNotFinished();
        
        uint256 pIdx = playerIndex[gameId][msg.sender];
        if (pIdx == 0) revert NotWinner();
        
        Player storage player = gamePlayers[gameId][pIdx - 1];
        if (player.team != lobby.winner) revert NotWinner();
        if (player.hasClaimed) revert AlreadyClaimed();
        
        player.hasClaimed = true;
        
        // Calculate payout
        uint256 totalPot = lobby.betAmount * lobby.teamSize * 2;
        uint256 houseFee = (totalPot * feeBps) / 10000;
        uint256 payoutPool = totalPot - houseFee;
        uint256 playerPayout = payoutPool / lobby.teamSize;
        
        (bool success, ) = msg.sender.call{value: playerPayout}("");
        require(success, "Transfer failed");
        
        emit WinningsClaimed(gameId, msg.sender, playerPayout);
    }

    /**
     * @notice Withdraw stake from a voided lobby
     * @param gameId The lobby ID to withdraw from
     */
    function withdrawVoid(uint256 gameId) external nonReentrant {
        Lobby storage lobby = lobbies[gameId];
        
        if (lobby.state != GameState.VOID) revert LobbyNotVoid();
        
        uint256 pIdx = playerIndex[gameId][msg.sender];
        if (pIdx == 0) revert NotWinner();
        
        Player storage player = gamePlayers[gameId][pIdx - 1];
        if (player.hasClaimed) revert AlreadyClaimed();
        
        player.hasClaimed = true;
        
        (bool success, ) = msg.sender.call{value: lobby.betAmount}("");
        require(success, "Transfer failed");
        
        emit RefundClaimed(gameId, msg.sender, lobby.betAmount);
    }

    /**
     * @notice Withdraw accumulated house fees to treasury
     */
    function withdrawHouseFees() external {
        uint256 amount = accumulatedHouseFees;
        if (amount == 0) revert NoFeesToWithdraw();
        
        accumulatedHouseFees = 0;
        
        (bool success, ) = treasury.call{value: amount}("");
        require(success, "Transfer failed");
        
        emit HouseFeesWithdrawn(treasury, amount);
    }

    // ============ Admin Functions ============

    /**
     * @notice Update treasury address
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidAddress();
        
        address oldTreasury = treasury;
        treasury = _treasury;
        
        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    /**
     * @notice Update protocol fee (max 5%)
     * @param _feeBps New fee in basis points (0-500)
     */
    function setFee(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        
        uint256 oldFee = feeBps;
        feeBps = _feeBps;
        
        emit FeeUpdated(oldFee, _feeBps);
    }

    // ============ View Functions ============

    /**
     * @notice Get lobby details
     */
    function getLobby(uint256 gameId) external view returns (Lobby memory) {
        return lobbies[gameId];
    }

    /**
     * @notice Get all players in a lobby
     */
    function getPlayers(uint256 gameId) external view returns (Player[] memory) {
        return gamePlayers[gameId];
    }
    
    /**
     * @notice Get all rounds for a game
     */
    function getGameRounds(uint256 gameId) external view returns (Round[] memory) {
        return gameRounds[gameId];
    }

    /**
     * @notice Get player info
     */
    function getPlayerInfo(uint256 gameId, address player) external view returns (
        bool isPlayer,
        Team team,
        bool hasClaimed
    ) {
        uint256 pIdx = playerIndex[gameId][player];
        if (pIdx == 0) {
            return (false, Team.NONE, false);
        }
        Player storage p = gamePlayers[gameId][pIdx - 1];
        return (true, p.team, p.hasClaimed);
    }

    /**
     * @notice Get estimated entropy fee for starting/continuing a game
     */
    function getEntropyFee() external view returns (uint256) {
        return entropy.getFeeV2(CALLBACK_GAS_LIMIT);
    }

    /**
     * @notice Check if lobby can be voided
     */
    function canVoid(uint256 gameId) external view returns (bool) {
        Lobby storage lobby = lobbies[gameId];
        return lobby.state == GameState.OPEN && 
               block.number > lobby.createdBlock + VOID_BLOCK_THRESHOLD;
    }

    /**
     * @notice Get global stats
     */
    function getLobbyStats() external view returns (
        uint256 totalGames,
        uint256 totalVolume
    ) {
        return (totalGamesCreated, totalVolumeStaked);
    }

    // ============ Entropy Consumer Interface ============

    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }

    function entropyCallback(
        uint64 sequence,
        address /* provider */,
        bytes32 randomNumber
    ) internal override {
        uint256 gameId = entropyToGame[sequence];
        if (gameId == 0 && lobbies[0].pendingEntropySeq != sequence) {
            revert InvalidEntropySequence();
        }
        
        Lobby storage lobby = lobbies[gameId];
        
        if (lobby.state != GameState.IN_PROGRESS) {
            return; // Ignore stale callbacks
        }
        
        lobby.entropyRequested = false;
        
        // Determine round winner based on random number
        // If least significant bit is 0, HEADS wins; if 1, TAILS wins
        Team roundWinner = (uint256(randomNumber) % 2 == 0) ? Team.HEADS : Team.TAILS;
        
        if (roundWinner == Team.HEADS) {
            lobby.headsScore++;
        } else {
            lobby.tailsScore++;
        }
        
        // Update round history
        Round[] storage rounds = gameRounds[gameId];
        if (rounds.length > 0) {
            Round storage r = rounds[rounds.length - 1];
            if (r.sequenceNumber == sequence) {
                r.winner = roundWinner;
                r.resolved = true;
            }
        }
        
        emit RoundResolved(
            gameId,
            lobby.currentRound,
            roundWinner,
            lobby.headsScore,
            lobby.tailsScore
        );
        
        // Check if game is finished
        if (lobby.headsScore >= lobby.roundsToWin) {
            _finishGame(gameId, Team.HEADS);
        } else if (lobby.tailsScore >= lobby.roundsToWin) {
            _finishGame(gameId, Team.TAILS);
        } else {
            // Next round
            lobby.currentRound++;
        }
    }

    // ============ Internal Functions ============

    function _addPlayer(uint256 gameId, address playerAddr, Team team) internal {
        gamePlayers[gameId].push(Player({
            addr: playerAddr,
            team: team,
            hasClaimed: false
        }));
        
        playerIndex[gameId][playerAddr] = gamePlayers[gameId].length;
        teamPlayerCount[gameId][team]++;
    }

    function _requestEntropyWithFee(uint256 gameId, uint256 fee) internal {
        Lobby storage lobby = lobbies[gameId];
        
        // Request entropy with the fee provided by the caller
        uint64 sequenceNumber = entropy.requestV2{value: fee}(CALLBACK_GAS_LIMIT);
        
        lobby.pendingEntropySeq = sequenceNumber;
        lobby.entropyRequested = true;
        entropyToGame[sequenceNumber] = gameId;
        
        // Store pending round info
        gameRounds[gameId].push(Round({
            roundNumber: lobby.currentRound,
            sequenceNumber: sequenceNumber,
            winner: Team.NONE,
            resolved: false
        }));
        
        emit EntropyRequested(gameId, sequenceNumber, lobby.currentRound);
    }

    function _finishGame(uint256 gameId, Team winner) internal {
        Lobby storage lobby = lobbies[gameId];
        
        lobby.state = GameState.FINISHED;
        lobby.winner = winner;
        
        // Accumulate house fees
        uint256 totalPot = lobby.betAmount * lobby.teamSize * 2;
        uint256 houseFee = (totalPot * feeBps) / 10000;
        accumulatedHouseFees += houseFee;
        
        emit GameFinished(
            gameId,
            winner,
            lobby.headsScore,
            lobby.tailsScore
        );
    }
    
    receive() external payable {}
}
