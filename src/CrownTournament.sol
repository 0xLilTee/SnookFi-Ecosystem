// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SnookFiBase} from "./Base.sol";
// import {snookerMatch} from "./Match.sol";

/**
 * @title SnookFiGame/SnookFi Crown Tournament Contract
 * @author GubbyLabs
 * @notice A decentralized matchmaking and escrow system for peer-to-peer snooker games. 
 */
contract snookerCrownTournament is SnookFiBase, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    IERC20 immutable USDT;  // using USDT for all transactions

    bytes32 public constant TOURNAMENT_RESULT_TYPEHASH =
    keccak256(
        "TournamentResult(uint256 tournamentId,address winner,uint256 nonce,uint256 deadline)"
    );

    enum TournamentType {
        Crown, 
        DualCrown
    }

    enum TournamentState {
        Active,
        Completed
    }

    struct Tournament {
        uint256 id;
        TournamentType tType;

        address[] players;
        uint256[] matchIds;

        uint8 maxPlayers;
        uint8 currentRound;

        uint256 entryFee;
        uint256 prizePool;

        address winner;
        address secondPlace;        // Unused for Crown Tournament, but will be used in Dual Crown Tournament
        TournamentState state;
    }

    // ---- stats ----
    struct TournamentWallet {
        uint256 balance;

        uint256 totalDeposited;
        uint256 totalWithdrawn;

        uint256 totalWon;
        uint256 totalLost;

        uint256 totalWagered;
        uint256 totalRefunded;

        uint256 wins;
        uint256 losses;

        uint256 tournamentsPlayed;
    }

    // -----------------------------
    // Constants/Variables
    // -----------------------------

    // 5% fee on entry fees and prize pool, represented in basis points (bps)
    uint256 public constant TOURNAMENT_BPS_FEE = 500;
    // Maximum players allowed in Crown Tournament       
    uint8 public constant MAX_CROWN_PLAYERS = 4;
    // Maximum players allowed in Dual Crown Tournament   
    uint8 public constant MAX_DUAL_CROWN_PLAYERS = 8;
    // Minimum deposit of 10 USDT                
    uint256 public constant MIN_DEPOSIT = 10 * 1e6;
    // Time after which players can claim refunds if tournament is stuck         
    uint256 public constant EMERGENCY_REFUND_DELAY = 3 days;
    // Time between refund requests for the same tournament  
    uint256 public constant REFUND_REQUEST_COOLDOWN = 1 hours; 

    uint256 public nextTournamentId;
    uint256 public totalFeesCollected;
    uint256 public totalPrizePool;
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;


    // -----------------------------
    // Mappings
    // -----------------------------

    // tournamentId => Tournament data
    mapping(uint256 => Tournament) public tournaments;

    // player => tournament wallet statistics and balances
    mapping(address => TournamentWallet) public tournamentWallets;

    // player => currently active tournament ID (0 if none)
    mapping(address => uint256) public activeTournamentId;

    // tournamentId => player index position inside queue
    mapping(uint256 => uint256) public queueIndex;

    // stakeAmount => players waiting for a tournament at that stake
    mapping(uint256 => address[]) public tournamentQueue;

    // stakeAmount => whether this stake amount is supported
    mapping(uint256 => bool) public isSupportedStakeAmount;

    // player => whether player is currently queued
    mapping(address => bool) public inQueue;

    // player => stake amount the player queued with
    mapping(address => uint256) public queuedStakeAmount;

    // tournamentId => timestamp of latest refund request
    mapping(uint256 => uint256) public lastRefundRequest;

    // tournamentId => whether emergency refund was processed
    mapping(uint256 => bool) public emergencyRefundProcessed;

    // tournamentId => whether tournament entry was cancelled by player (used for refunds)
    mapping(address => bool) public cancelTournamentEntry;

    // tournamentId => whether a signature has been used to report results 
    mapping(uint256 => uint256) public tournamentNonce;

    // prevents replay of signed tournament results
    mapping(bytes32 => bool) public usedSignatures;

    // -----------------------------
    // Events
    // -----------------------------
    event Deposited(address indexed player, uint256 amount, uint256 newBalance);
    event TournamentCreated(uint256 indexed tournamentId, TournamentType tType, uint256 entryFee, uint256 prizePool);
    event JoinTournamentCancelled(address indexed player, uint256 stakeAmount);
    event TournamentCompleted(uint256 indexed tournamentId, address indexed winner, uint256 payoutAmount, uint256 feeAmount);
    event TournamentWinnerReported(uint256 indexed tournamentId, address indexed winner, uint256 nonce);

    constructor(address _usdt, address _referee) SnookFiBase("SnookFiCrownTournament", "1", _referee) Ownable(msg.sender) {
        require(_usdt != address(0), "Invalid USDT address");
        USDT = IERC20(_usdt);

        nextTournamentId = 1; // Start tournament IDs from 1 for better UX
        // Initialize supported stake amounts (can be updated by owner)
        isSupportedStakeAmount[10 * 1e6] = true; 
        isSupportedStakeAmount[20 * 1e6] = true;
        isSupportedStakeAmount[50 * 1e6] = true;
        isSupportedStakeAmount[100 * 1e6] = true;
        isSupportedStakeAmount[200 * 1e6] = true;
        isSupportedStakeAmount[500 * 1e6] = true;
        isSupportedStakeAmount[1000 * 1e6] = true;
        isSupportedStakeAmount[1500 * 1e6] = true;
        isSupportedStakeAmount[2000 * 1e6] = true;
        isSupportedStakeAmount[5000 * 1e6] = true;
        isSupportedStakeAmount[7500 * 1e6] = true;
        isSupportedStakeAmount[10000 * 1e6] = true;
    }

    modifier onlyTournamentPlayer(uint256 tournamentId) {
        _onlyTournamentPlayer(tournamentId);
        _;
    }

    function _onlyTournamentPlayer(uint256 tournamentId) internal view {
        address[] storage players = tournaments[tournamentId].players;

        for(uint256 i = 0; i < players.length; i++) {
            if(players[i] == msg.sender) {
                return;
            }
        }
        revert("Not a player in this tournament");
    }

    function deposit(uint256 amount) external nonReentrant {
        require(amount >= MIN_DEPOSIT, "Deposit must be at least 10 USDT");

        IERC20(USDT).safeTransferFrom(msg.sender, address(this), amount);

        TournamentWallet storage w = tournamentWallets[msg.sender];

        w.balance += amount;
        w.totalDeposited += amount;

        totalDeposited += amount;

        emit Deposited(msg.sender, amount, w.balance);
    }

    function joinTournament(uint256 stakeAmount) external nonReentrant {
        require(activeTournamentId[msg.sender] == 0, "Already in an active tournament");
        require(isSupportedStakeAmount[stakeAmount], "Unsupported stake amount");
        require(!inQueue[msg.sender], "Already in queue");
        require(tournamentWallets[msg.sender].balance >= stakeAmount, "Insufficient balance to join tournament");

        TournamentWallet storage w = tournamentWallets[msg.sender];
        w.balance -= stakeAmount;
        // w.totalWagered += stakeAmount;
        tournamentQueue[stakeAmount].push(msg.sender);
        inQueue[msg.sender] = true;
        queuedStakeAmount[msg.sender] = stakeAmount;

        uint256 queueLength = _getTournamentQueueLength(stakeAmount);
        if(queueLength >= MAX_CROWN_PLAYERS) {
            uint256 validPlayers;
            address[MAX_CROWN_PLAYERS] memory players;
            while(validPlayers < MAX_CROWN_PLAYERS) {
                address player = tournamentQueue[stakeAmount][queueIndex[stakeAmount]];
                queueIndex[stakeAmount]++;

                // Skip Players who cancelled there join tournament request 
                if(cancelTournamentEntry[player]) {
                    cancelTournamentEntry[player] = false;
                    continue;
                }
                //skip invalid queue state safety check
                if(!inQueue[player]) {
                    continue;
                }
                players[validPlayers] = player;
                
                inQueue[player] = false;
                delete queuedStakeAmount[player];
                
                validPlayers++;
            }
            _createTournament(players, stakeAmount);
        }

    }

    function _createTournament(address[MAX_CROWN_PLAYERS] memory players, uint256 stakeAmount) internal {
        Tournament storage t = tournaments[nextTournamentId];
        t.id = nextTournamentId;
        t.tType = TournamentType.Crown;
        t.maxPlayers = MAX_CROWN_PLAYERS;
        t.currentRound = 1;
        t.entryFee = stakeAmount;
        t.prizePool = stakeAmount * MAX_CROWN_PLAYERS;
        t.state = TournamentState.Active;

        for(uint256 i = 0; i < MAX_CROWN_PLAYERS; i++) {
            t.players.push(players[i]);

            activeTournamentId[players[i]] = nextTournamentId;

            tournamentWallets[players[i]].tournamentsPlayed += 1;
            tournamentWallets[players[i]].totalWagered += stakeAmount;

        }
        emit TournamentCreated(nextTournamentId, TournamentType.Crown, stakeAmount, t.prizePool);
        nextTournamentId++;
    }

    function _getTournamentQueueLength(uint256 stakeAmount) internal view returns (uint256) {
        return tournamentQueue[stakeAmount].length - queueIndex[stakeAmount];
    }

    function setSupportedStakeAmount(uint256 stakeAmount, bool status) external onlyOwner {
        isSupportedStakeAmount[stakeAmount] = status;
    }

    function cancelJoinTournamentRequest() external nonReentrant {
       require(inQueue[msg.sender], "Not in queue");

       uint256 stakeAmount = queuedStakeAmount[msg.sender];

       tournamentWallets[msg.sender].balance += stakeAmount;

       inQueue[msg.sender] = false;
       cancelTournamentEntry[msg.sender] = true;

       delete queuedStakeAmount[msg.sender];

       emit JoinTournamentCancelled(msg.sender, stakeAmount);
    }

    function _finalizeCrownTournament(uint256 tournamentId, address winner) internal {
        Tournament storage t = tournaments[tournamentId];

        require(t.state == TournamentState.Active, "Tournament not active");
        require(t.winner == address(0), "Tournament already finalized");
        require(winner != address(0), "Invalid winner");

        bool validWinner;

        // validate winner is part of tournament
        for (uint256 i = 0; i < t.players.length; i++) {
            if (t.players[i] == winner) {
                validWinner = true;
            }

            // clear active tournament for all players
            activeTournamentId[t.players[i]] = 0;
        }

        require(validWinner, "Winner not in tournament");

        // update tournament state
        t.winner = winner;
        t.state = TournamentState.Completed;

        // calculate fee and payout
        uint256 feeAmount =
            (t.prizePool * TOURNAMENT_BPS_FEE) / 10_000;

        uint256 payoutAmount = t.prizePool - feeAmount;

        // protocol accounting
        totalFeesCollected += feeAmount;

        // winner payout
        tournamentWallets[winner].balance += payoutAmount;

        // winner profit = payout minus original entry
        uint256 winnerProfit = payoutAmount - t.entryFee;

        tournamentWallets[winner].totalWon += winnerProfit;

        tournamentWallets[winner].wins += 1;

        tournamentWallets[winner].tournamentsPlayed += 1;

        // update loser stats
        for (uint256 i = 0; i < t.players.length; i++) {
            address player = t.players[i];

            if (player == winner) continue;

            tournamentWallets[player].losses += 1;

            tournamentWallets[player].tournamentsPlayed += 1;

            tournamentWallets[player].totalLost += t.entryFee;
        }

        emit TournamentCompleted(
            tournamentId,
            winner,
            payoutAmount,
            feeAmount
        );
    }

    function reportTournamentWinner(
        uint256 tournamentId,
        address winner,
        uint256 nonce,
        uint256 deadline,
        bytes memory signature
    ) external nonReentrant onlyTournamentPlayer(tournamentId) {
        Tournament storage t = tournaments[tournamentId];

        require(t.state == TournamentState.Active, "Tournament not active");
        require(winner != address(0), "Invalid winner");

        bool validWinner;

        // validate winner belongs to tournament
        for (uint256 i = 0; i < t.players.length; i++) {
            if (t.players[i] == winner) {
                validWinner = true;
                break;
            }
        }

        require(validWinner, "Winner not in tournament");

        // nonce validation
        require(
            nonce == tournamentNonce[tournamentId] + 1,
            "Invalid nonce"
        );

        tournamentNonce[tournamentId] = nonce;

        // EIP-712 struct hash
        bytes32 structHash = keccak256(
            abi.encode(
                TOURNAMENT_RESULT_TYPEHASH,
                tournamentId,
                winner,
                nonce,
                deadline
            )
        );

        // signature expiry
        require(block.timestamp <= deadline, "Signature expired");

        bytes32 digest = _hashTypedDataV4(structHash);

        // replay protection
        require(!usedSignatures[digest], "Signature already used");

        usedSignatures[digest] = true;

        // verify signer
        address signer = digest.recover(signature);

        require(refereeRegistry.isReferee(signer), "Invalid signature");

        _finalizeCrownTournament(tournamentId, winner);

        emit TournamentWinnerReported(
            tournamentId,
            winner,
            nonce
        );
    }

}