// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SnookFiBase} from "./Base.sol";
import {IRefereeRegistry} from "./Interface/IRefereeRegistry.sol";
import {RefereeRegistry} from "src/RefereeRegistry.sol";


/**
 * @title SnookFiGame/Match
 * @author GubbyLabs
 * @notice A decentralized matchmaking and escrow system for peer-to-peer snooker games.
 * @dev 
 * This contract manages:
 * - Player wallet balances (deposit, withdraw, and in-game escrow)
 * - Matchmaking queues based on stake amounts
 * - Creation and lifecycle of matches between players
 * - Secure winner reporting using EIP-712 signatures verified by a trusted referee
 * - Fee collection and distribution for completed matches
 *
 * Key Features:
 * - Non-custodial player balances with controlled withdrawals
 * - Deterministic matchmaking to ensure fair stake pairing
 * - Replay-protected off-chain signed match results (EIP-712)
 * - Emergency and cancellation mechanisms for unresolved matches
 * - Gas-efficient state tracking for player statistics and match outcomes
 *
 * Security Considerations:
 * - Uses nonReentrant guards to prevent reentrancy attacks
 * - Enforces strict validation on match states and participants
 * - Protects against signature replay via nonce and digest tracking
 * - Validates all critical inputs including addresses and balances
 *
 * @custom:warning This contract assumes a trusted referee for match result validation.
 * @custom:warning Users must approve sufficient ERC20 allowance before interacting.
 */
contract snookerMatch is SnookFiBase, ReentrancyGuard, Ownable, Pausable {
        using SafeERC20 for IERC20;
        using ECDSA for bytes32;

        IERC20 immutable USDT;  // using USDT for all transactions

        // EIP-712 Type Hash
        bytes32 public constant MATCH_RESULT_TYPEHASH = keccak256(
            "MatchResult(uint256 matchId, address player1, address player2, address winner, uint256 nonce, uint256 deadline)");

    // -----------------------------
    //  Player wallets
    // -----------------------------

    struct MatchWallet {
        // ---- stats (safe to add) ----
    uint256 depositedBalance;  // Funds deposited INTO contract for gameplay
    uint256 totalDeposited;  // deposits
    uint256 totalWon;        // total USDT won
    uint256 totalLost;      // total USDT lost
    uint256 totalWagered;    // total USDT wagered (totalstakes in matches)
    uint256 wins;            // total wins
    uint256 losses;          // total losses
    uint256 totalWithdrawn;  // total USDT withdrawn
    uint256 totalRefunded;      // total USDT refunded from emergencyRequest matches
    uint256 gamesPlayed;     // number of matches played
    }


    // -----------------------------
    // Match storage
    // -----------------------------

    enum MatchState {
        Active,
        Completed
    }    

    struct Match {
        address player1;
        address player2;
        address currentPlayer;       // whose turn it is

        uint256 stakeAmount;        // in USDT smallest uint (6 decimals)
        uint256 startTime;          // block.timestamp of match start

        address winner;             // address of the winner
        bool finished;              // if Match has finished
        bool rematchPlayer1;
        bool rematchPlayer2;
        bool player1ApprovesRefund;
        bool player2ApprovesRefund;

        uint256 rematchTimeRequested; // timestamp of when rematch was requested

        MatchState state;           // current state of the match
    }



    // -----------------------------
    // Constants/Variables
    // -----------------------------

    uint256 public constant MATCH_BPS_FEE = 200;         // 2% fee in basis points
    uint256 public constant TIMEOUT_DURATION = 45;      // 45 seconds*
    uint256 public constant EMERGENCY_REFUND_DELAY = 3 days;    // 3 days max match duration to prevent stuck funds
    uint256 public constant REFUND_REQUEST_COOLDOWN = 1 hours; // 1 hour cooldown between refund requests to prevent spam
    uint256 public constant MIN_DEPOSIT = 10e6;         // Minimum stake of 10 USDT (6 decimals)
    uint256 public constant REMATCH_WINDOW = 10;        // 10 seconds window for rematch requests after a match completes
    uint256 public constant REFEREE_FORCE_DELAY = 24 hours; // 24 hours delay after first refund request before referee can force refund
    uint256 public constant REFEREE_THRESHOLD = 3;      // Minimum number of referee signatures required to validate a match result
    uint256 public nextMatchId;                         // incrementing unique ID for each match
    uint256 public collectedFees;
    uint256 public totalLockedInMatches;                // total USDT currently locked in active matches
    uint256 public totalDeposited;               // total USDT deposited into the contract across all players
    uint256 public totalWithdrawn;
    uint256 public totalQueuedFunds;

    mapping (uint256 => Match) public matches;          // matchId => Match
    mapping (address => uint256) public balances;       // EOA => USDT deposited
    mapping (address => uint256) public activeMatch;    // EOA => current matchId
    // mapping (uint256 => bool) public stakedMatch;       // $10, $20, etc.
    mapping (uint256 => bool) public isSupportedStakeAmount; // supported stake amounts
    mapping (address => MatchWallet) public wallets;       // player address => MatchWallet
    mapping (uint256 => address[]) public matchQueue;   // stakeAmount => waiting players
    mapping (uint256 => uint256) public queueIndex;     // stakeAmount => index of next player to match in queue
    mapping(uint256 => bool) private supportedAmounts;  // stakeAmount => isSupported
    mapping(address => bool) public inQueue; 
    mapping(address => uint256) public queuedStake;     // player => stake amount they have queued with     
    mapping(uint256 => mapping(address => uint256)) public lastRefundRequestTime; // matchId => timestamp of last refund request for cooldown
    mapping(uint256 => uint256) public matchNonce;
    mapping(bytes32 => bool) public usedSignatures;
    mapping(uint256 => uint256) public firstRefundRequestTime;       

    // -----------------------------
    // Events
    // -----------------------------
    event WalletCreated(address indexed player);
    event Deposited(address indexed player, uint256 amount, uint256 newBalance);
    event WithdrawnFees(address indexed to, uint256 amount);
    event Withdrawn(address indexed player, uint256 amount, uint256 newBalance);
    event WithdrawnAll(address indexed player, uint256 amount, uint256 newBalance);
    event MatchCreated(uint256 indexed matchId, address indexed player1, address indexed player2, uint256 stakeAmount);
    event MatchJoined(uint256 indexed matchId, address indexed player, address indexed opponent, uint256 stakeAmount);
    event MatchCompleted(uint256 indexed matchId, address indexed winner, uint256 payoutAmount);
    event MatchCancelled(uint256 indexed matchId, address indexed cancelledBy, string reason);
    event MatchCompletedByTimeout(uint256 indexed matchId, address indexed winner);
    event RematchRequested(uint256 indexed matchId, address indexed player);
    event RefereeUpdated(address indexed newReferee);
    event RematchStarted(uint256 indexed matchId, uint256 indexed newMatchId, address indexed player1, address player2);
    event StakeAdjusted(address indexed player, uint256 oldStake, uint256 newStake);
    event JoinRequestCancelled(address indexed player, uint256 stakeAmount);
    event EmergencyRefundRequested(uint256 indexed matchId, address indexed player);
    event EmergencyRefundExecuted(uint256 indexed matchId, address indexed player1, address indexed player2, uint256 stakeAmount);
    event EmergencyRefundCancelled(uint256 indexed matchId, address indexed player);
    event MatchWinnerReported(uint256 indexed matchId, address indexed winner, uint256 nonce);
    event PlayerQueued(address indexed player, uint256 stakeAmount, uint256 positionInQueue);

    error InsufficientDepositBalance();

    constructor(address _usdt, address _referee) SnookFiBase("SnookFiMatch", "1", _referee) Ownable(msg.sender)  {
    require(_usdt != address(0), "Invalid USDT address");
    USDT = IERC20(_usdt);

    nextMatchId = 1;

    // Initialize supported stake amounts mapping
    supportedAmounts[10e6] = true;
    supportedAmounts[20e6] = true;
    supportedAmounts[50e6] = true;
    supportedAmounts[100e6] = true;
    supportedAmounts[200e6] = true;
    supportedAmounts[500e6] = true;
    supportedAmounts[800e6] = true;
    supportedAmounts[1000e6] = true;
    supportedAmounts[1500e6] = true;
    supportedAmounts[2000e6] = true;
    supportedAmounts[2500e6] = true;
    supportedAmounts[3000e6] = true;
    supportedAmounts[5000e6] = true;
    supportedAmounts[7500e6] = true;
    supportedAmounts[10000e6] = true;
    supportedAmounts[15000e6] = true;
    supportedAmounts[20000e6] = true;
    supportedAmounts[25000e6] = true;
    supportedAmounts[30000e6] = true;
    supportedAmounts[50000e6] = true;
    supportedAmounts[75000e6] = true;
    supportedAmounts[100000e6] = true;

}

    modifier onlyPlayer(uint256 matchId){
        _onlyPlayer(matchId);
        _;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function deposit(uint256 amount) external nonReentrant {
        require (amount > 0, "Deposit amount must be greater than 0");
        require (amount >= MIN_DEPOSIT, "Deposited amount too low");

        // Transfer USDT from user to contract
        IERC20(USDT).safeTransferFrom(msg.sender, address(this), amount);

        MatchWallet storage w = wallets[msg.sender];

        w.depositedBalance += amount;
        w.totalDeposited += amount;
        totalDeposited += amount;

        emit Deposited(msg.sender, amount, w.depositedBalance);
    }


    function joinMatch(uint256 stakeAmount) external nonReentrant {
        require (activeMatch[msg.sender] == 0, "Already in an active Match");
        require(!inQueue[msg.sender], "Already waiting in queue");  
        require (_isSupportedStakeAmount(stakeAmount), "Unsupported Stake Amount");
        
        MatchWallet storage w = wallets[msg.sender];
        require (wallets[msg.sender].depositedBalance >= stakeAmount, "Insufficient deposit balance");

        // Deduct the stake amount from the player's deposited balance
        w.depositedBalance -= stakeAmount;
        w.totalWagered += stakeAmount; // track total wagered for the player

        // Check if player has an active match
        matchQueue[stakeAmount].push(msg.sender);
        inQueue[msg.sender] = true;
        queuedStake[msg.sender] = stakeAmount;
        totalQueuedFunds += stakeAmount;
        emit PlayerQueued(msg.sender, stakeAmount, matchQueue[stakeAmount].length - queueIndex[stakeAmount]);

        uint256 queueHead = queueIndex[stakeAmount];
        uint256 activeQueueLength = matchQueue[stakeAmount].length - queueHead;

        if (activeQueueLength >= 2){
            address player1 = matchQueue[stakeAmount][queueHead];
            address player2 = matchQueue[stakeAmount][queueHead + 1];

            queueIndex[stakeAmount] = queueHead + 2;

            inQueue[player1] = false;
            inQueue[player2] = false;

            delete queuedStake[player1];
            delete queuedStake[player2];

            totalQueuedFunds -= stakeAmount * 2;
            totalLockedInMatches += stakeAmount * 2; // increase total locked amount as these funds are now in an active match
            
            // Create the Match
            uint256 matchId = _createMatch(player1, player2, stakeAmount);

            emit MatchJoined(matchId, player1, player2, stakeAmount);

            // remove the first two players from the queue after they have been matched, and clean up old entries for gas refunds
            _removeFirstTwoFromQueue(stakeAmount, queueHead);
        }         
     }

    function restartMatch(uint256 matchId) external nonReentrant onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        require (_isSupportedStakeAmount(m.stakeAmount), "Unsupported Stake Amount");
        require(m.finished, "Match not completed");
        require(m.state == MatchState.Completed, "Invalid state");
        require(wallets[msg.sender].depositedBalance >= m.stakeAmount, "Insufficient balance");

    // Check if rematch window expired
    if (m.rematchTimeRequested > 0) {
        require(
            block.timestamp <= m.rematchTimeRequested + REMATCH_WINDOW,
            "Rematch window expired"
        );
    }
  
    // Record player's rematch request
    if (msg.sender == m.player1) {
        require(!m.rematchPlayer1, "Already requested rematch");
        m.rematchPlayer1 = true;
    } else {
        require(!m.rematchPlayer2, "Already requested rematch");
        m.rematchPlayer2 = true;
    }

    // Start 10s timer on first request
    if (m.rematchTimeRequested == 0) {
        m.rematchTimeRequested = block.timestamp;
        emit RematchRequested(matchId, msg.sender);
    }

    // If both players want rematch within 10s window
    if (m.rematchPlayer1 && m.rematchPlayer2) {
        // Deduct stakes from both players
        wallets[m.player1].depositedBalance -= m.stakeAmount;
        wallets[m.player2].depositedBalance -= m.stakeAmount;

        totalLockedInMatches += m.stakeAmount * 2;
        
        // Reset rematch   for this match
        m.rematchPlayer1 = false;
        m.rematchPlayer2 = false;
        m.rematchTimeRequested = 0;
        
        // Create new match with SAME players
        uint256 newMatchId =_createMatch(m.player1, m.player2, m.stakeAmount);

        emit RematchStarted(matchId, newMatchId, m.player1, m.player2);
        }
    }


    function setSupportedAmount(uint256 amount, bool status) external onlyOwner {
    supportedAmounts[amount] = status;
    }

    function adjustStake(uint256 newStake) external nonReentrant {
        require(inQueue[msg.sender], "Not in queue");
        require(activeMatch[msg.sender] == 0, "Cannot adjust stake while in active match");
        require(_isSupportedStakeAmount(newStake), "Unsupported Stake Amount");

        uint256 oldStake = queuedStake[msg.sender];
        require(oldStake != newStake, "Same stake");

        MatchWallet storage w = wallets[msg.sender];
        _removePlayerFromQueue(msg.sender, oldStake);

        totalQueuedFunds -= oldStake;

        // Refund old stake to player's deposited balance
        w.depositedBalance += oldStake;
        w.totalWagered -= oldStake;

        // Deduct new Stake from players deposited Balance
        require(w.depositedBalance >= newStake, "Insufficient Balance");
        w.depositedBalance -= newStake;
        w.totalWagered += newStake;

        // Add player to new queue
        matchQueue[newStake].push(msg.sender);
        queuedStake[msg.sender] = newStake;
        inQueue[msg.sender] = true;
        totalQueuedFunds += newStake;
        emit StakeAdjusted(msg.sender, oldStake, newStake);

    } 


    function cancelMatch(uint256 matchId) external nonReentrant onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        require(!m.finished, "Match already completed");
        require(m.state == MatchState.Active, "Match not active");
        require(msg.sender == m.player1 || msg.sender == m.player2, "Not a player in this match");

        // The caller forfiets there stake, the other player gets their stake back
        address winner = msg.sender == m.player1 ? m.player2 : m.player1;

        _finalizeMatch(matchId, winner);

        emit MatchCancelled(matchId, msg.sender, "Match cancelled, opponent wins by forfeit");
    }

    function cancelJoinRequest() external nonReentrant {
        require(inQueue[msg.sender], "Not in queue");
        require(activeMatch[msg.sender] == 0, "Cannot cancel while in active match");

        uint256 stakeAmount = queuedStake[msg.sender];
        require(stakeAmount > 0, "No stake found");
        _removePlayerFromQueue(msg.sender, stakeAmount);
        totalQueuedFunds -= stakeAmount;
        // Refund the stake back to players deposited balance 
        wallets[msg.sender].depositedBalance += stakeAmount;

        emit JoinRequestCancelled(msg.sender, stakeAmount);
    }

    function requestEmergencyRefund(uint256 matchId) external nonReentrant onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        require(!m.finished, "Match already completed");
        require(m.state == MatchState.Active, "Match not active");
        require(block.timestamp >= m.startTime + EMERGENCY_REFUND_DELAY, "Match not expired - wait 3 days");
        require(block.timestamp > lastRefundRequestTime[matchId][msg.sender] + REFUND_REQUEST_COOLDOWN,"Please wait 1 hour before requesting again");

         lastRefundRequestTime[matchId][msg.sender] = block.timestamp;

        // Record player's refund approval
        if(msg.sender == m.player1) {
            require(!m.player1ApprovesRefund, "Already approved refund");
            m.player1ApprovesRefund = true;   
        }  else {
            require(!m.player2ApprovesRefund, "Already approved refund");
            m.player2ApprovesRefund = true;
        }

            emit EmergencyRefundRequested(matchId, msg.sender);
        // If both players approve refund - Execute refund immediately.
        if(m.player1ApprovesRefund && m.player2ApprovesRefund) {
            _executeEmergencyRefund(matchId);
        }
    }

    function cancelEmergencyRefund(uint256 matchId) external nonReentrant onlyPlayer(matchId) {
        Match storage m = matches[matchId];
        require(m.state == MatchState.Active, "Match not active");
        require(!m.finished, "Match already completed");
        require(m.player1ApprovesRefund || m.player2ApprovesRefund, "No refund request to cancel");

        // Either player can cancel refund request
        if(msg.sender == m.player1) {
            require(m.player1ApprovesRefund, "No refund request to cancel");
            m.player1ApprovesRefund = false;
        } else {
            require(m.player2ApprovesRefund, "No refund request to cancel");
            m.player2ApprovesRefund = false;
        }

        emit EmergencyRefundCancelled(matchId, msg.sender);
    }

    function forceEmergencyRefund(uint256 matchId) external nonReentrant {
        // Only the trusted referee/backend can call this
        require(refereeRegistry.isReferee(msg.sender), "Not referee");

        Match storage m = matches[matchId];

        // Match must still be active
        require(m.state == MatchState.Active, "Match not active");

        // Match must not already be finished
        require(!m.finished, "Match already completed");

        // Emergency refund only becomes possible after 3 days
        require(
            block.timestamp >= m.startTime + EMERGENCY_REFUND_DELAY,
            "Match not expired"
        );

        // At least one player must have requested emergency refund
        require(
                m.player1ApprovesRefund || m.player2ApprovesRefund,
            "No refund requested"
        );

        if(firstRefundRequestTime[matchId] == 0){
        firstRefundRequestTime[matchId] = block.timestamp;
        }

        // Optional safety delay after first request
        require(
            block.timestamp >= firstRefundRequestTime[matchId] + REFEREE_FORCE_DELAY,
            "Force refund delay not passed"
        );

        // Execute refund logic internally
        _executeEmergencyRefund(matchId);

        emit EmergencyRefundExecuted(
            matchId,
            m.player1,
            m.player2,
            m.stakeAmount
        );

    }
    

     // -----------------------------
    // Internal function to bets
    // -----------------------------

    function _onlyPlayer(uint256 matchId) internal view {
    require(
        msg.sender == matches[matchId].player1 || msg.sender == matches[matchId].player2, 
        "Not a player in this match"
        );
}

    function _isSupportedStakeAmount(uint256 stakeAmount) internal view returns (bool){
        return supportedAmounts[stakeAmount];
    }

    function _createMatch(address player1, address player2, uint256 stakeAmounts) internal returns(uint256) {
        uint256 matchId = nextMatchId++;

        matches[matchId] = Match({
            player1: player1,
            player2: player2,
            currentPlayer: player1, 
            stakeAmount: stakeAmounts,
            startTime: block.timestamp,
            winner: address(0),
            finished: false,
            rematchPlayer1: false,
            rematchPlayer2: false,
            player1ApprovesRefund: false,
            player2ApprovesRefund: false,
            rematchTimeRequested: 0,
            state: MatchState.Active
        });

        // Update active matches for players
        activeMatch[player1] = matchId;
        activeMatch[player2] = matchId;

        emit MatchCreated(matchId, player1, player2, stakeAmounts);
        return matchId;
    }

    function _removePlayerFromQueue(address player, uint256 stakeAmount) internal {
        address[] storage queue = matchQueue[stakeAmount];
        uint256 startIndex = queueIndex[stakeAmount];
        uint256 queueLen   = queue.length;

        require(queueLen > startIndex, "No active players in queue");

        bool found = false;
        // Find player in active portion of the queue
        for (uint256 i = startIndex; i < queueLen; i++) {
            if (queue[i] == player) {
                found = true;
                // swap with last element
                uint256 lastIndex = queueLen - 1;
                if (i != lastIndex) {
                    queue[i] = queue[lastIndex];
                }
                queue.pop(); // remove last element
                break;
            }
        }
        require(found, "Player not found in queue");
                inQueue[player] = false;
                delete queuedStake[player];
    }

        // FIFO remove first two players from the queue after they have been matched, and clean up old entries for gas refunds
        function _removeFirstTwoFromQueue(uint256 stakeAmount, uint256 queueHead) internal {
            // Clean up old entries to get gas refunds
            delete matchQueue[stakeAmount][queueHead];
            delete matchQueue[stakeAmount][queueHead + 1];

            // Prevent infinite storage growth
            if (queueIndex[stakeAmount] >= matchQueue[stakeAmount].length) {
            delete matchQueue[stakeAmount];
            queueIndex[stakeAmount] = 0;
        }

    }

    // -----------------------------
    // Internal: Finalize match & payout
    // -----------------------------
    function _finalizeMatch(uint256 matchId, address winner) internal {
        Match storage m = matches[matchId];
        require(!m.finished, "Match already completed");
        require(m.state == MatchState.Active, "Match not active");
        require(winner != address(0), "Winner cannot be zero address");
        require(
        winner == m.player1 || winner == m.player2,
        "Winner must be a player in this match"
        );

        address loser = winner == m.player1 ? m.player2 : m.player1;

        // Update Match State
        m.finished = true;
        m.state = MatchState.Completed;
        m.winner = winner;

        // Clear Active Match
        activeMatch[m.player1] = 0;
        activeMatch[m.player2] = 0;

        // Calculate payout and fee
        uint256 totalStake = m.stakeAmount * 2;
        totalLockedInMatches -= totalStake; // decrease locked amount as match is now completed
        uint256 feeAmount = (totalStake * MATCH_BPS_FEE) / 10_000; // fees in basis points
        uint256 payoutAmount = totalStake - feeAmount;

        // Add fee to the vault instead of sending to winner
        collectedFees += feeAmount;
        
        wallets[winner].depositedBalance += payoutAmount; // add payout to winner's deposited balance

        // Stats
        MatchWallet storage wWinner = wallets[winner];
        MatchWallet storage wLoser = wallets[loser];

        wWinner.wins += 1;
        wLoser.losses += 1;

        // Update games played for both players
        wWinner.gamesPlayed++;
        wLoser.gamesPlayed++;

        uint256 totalProfit = payoutAmount - m.stakeAmount; // profit is payout minus original stake

        // Update total won/lost for both players
        wWinner.totalWon += totalProfit;     // winner's profit is payout minus their original stake 
        wLoser.totalLost += m.stakeAmount;  // loser's loss is their original stake


        emit MatchCompleted(matchId, winner, payoutAmount);
    }

    function _executeEmergencyRefund(uint256 matchId) internal {
        Match storage m = matches[matchId];
        require(!m.finished, "Match already completed");
        require(m.state == MatchState.Active, "Match not active");

        // Update Match State
        m.finished = true;
        m.state = MatchState.Completed;

        // Clear Active Match
        activeMatch[m.player1] = 0;
        activeMatch[m.player2] = 0;

        // Refund stakes to both players
        MatchWallet storage w1 = wallets[m.player1];
        MatchWallet storage w2 = wallets[m.player2];
        
        w1.depositedBalance += m.stakeAmount;
        w2.depositedBalance += m.stakeAmount;

        // Update total refunded for both players
        w1.totalRefunded += m.stakeAmount;
        w2.totalRefunded += m.stakeAmount;

        // Unlock funds
        totalLockedInMatches -= m.stakeAmount * 2;
    
        // Update games played (no win/loss for refund)
        w1.gamesPlayed++;
        w2.gamesPlayed++;

        m.player1ApprovesRefund = false;
        m.player2ApprovesRefund = false;

        emit EmergencyRefundExecuted(matchId, m.player1, m.player2, m.stakeAmount);
    }

    function _verifyRefereeSignature(
        bytes32 digest, 
        bytes[] memory signatures
        ) internal view returns (bool) {
            require(signatures.length >= REFEREE_THRESHOLD, "Not enough signatures");
            uint256 validSignatures;
            address[] memory usedSigners = new address[](signatures.length);
            
            for (uint256 i = 0; i < signatures.length; i++) {
                address signer = digest.recover(signatures[i]);

                // Check if signer is a valid referee and hasn't already signed
                require (refereeRegistry.isReferee(signer), "Invalid referee");
                // Check for duplicate signatures
                for (uint256 j = 0; j < i; j++) {
                    require(usedSigners[j] != signer, "Duplicate signature");
                }
                usedSigners[i] = signer;
                validSignatures++;
            }
            return validSignatures >= REFEREE_THRESHOLD;
        }

    // -----------------------------
    // Withdraw to EOA wallet
    // -----------------------------

    function withdraw(uint256 amount) external nonReentrant {
        require (activeMatch[msg.sender] == 0, "cannot withdraw while in active match");
        require(!inQueue[msg.sender], "Cannot withdraw while in queue");
        require (amount > 0, "withdraw amount must be greater than 0");

        MatchWallet storage w = wallets[msg.sender];

        require (w.depositedBalance >= amount, "Insufficient withdraw balance");

        uint256 contractBalance = IERC20(USDT).balanceOf(address(this));
        require(contractBalance >= totalLockedInMatches, "Cannot Withdraw At This Time");

        uint256 available = contractBalance - totalLockedInMatches;
        require(available >= amount, "Insufficient Withdrawal Liquidity");
        
        // require (totalDeposited - totalLockedInMatches >= amount, "cannot withdraw funds locked in active Match");

        w.depositedBalance -= amount;
        w.totalWithdrawn += amount;
        totalWithdrawn += amount;
        IERC20(USDT).safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, wallets[msg.sender].depositedBalance);
    }

    function withdrawAll() external nonReentrant {
        require (activeMatch[msg.sender] == 0, "cannot withdraw while in active match");
        require(!inQueue[msg.sender], "Cannot withdrawAll while in queue");

        MatchWallet storage w = wallets[msg.sender];

        uint256 balance = w.depositedBalance;
        require (balance > 0, "no balance to withdraw");

        uint256 contractBalance = IERC20(USDT).balanceOf(address(this));
        require(contractBalance >= totalLockedInMatches, "Cannot Withdraw At This Time");

        uint256 available = contractBalance - totalLockedInMatches;
        require(available >= balance, "Insufficient full withdrawal balance");

        w.depositedBalance = 0;
        w.totalWithdrawn += balance;
        totalWithdrawn += balance;
        IERC20(USDT).safeTransfer(msg.sender, balance);

        emit WithdrawnAll(msg.sender, balance, 0);
    }

    function withdrawFees(address to) external onlyOwner nonReentrant{
        require(to != address(0), "Invalid recipient address");
        uint256 amount = collectedFees;
        require(amount > 0, "No fees to withdraw");
        uint256 contractBalance = IERC20(USDT).balanceOf(address(this));
        require(contractBalance >= amount, "Insufficient contract balance for fees");

        // Reset the vault before transfer to prevent reentrancy
        collectedFees = 0;

        // Transfer fees
        IERC20(USDT).safeTransfer(to, amount);
        emit WithdrawnFees(to, amount);
}

    function reportMatchWinner(
        uint256 matchId,
        address winner,
        uint256 nonce,
        uint256 deadline,
        bytes[] memory signature
    ) external nonReentrant {
        Match storage m = matches[matchId];
        require(!m.finished, "Match Already Completed");
        require(m.state == MatchState.Active, "Match Not Active");
        require(winner == m.player1 || winner == m.player2, "Invalid winner");
        require(block.timestamp <= deadline, "Signature expired");
        
        // Nonce check
        require(nonce == matchNonce[matchId] + 1, "Invalid nonce");
        
        
        // EIP-712 Structured Hash
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 structHash = keccak256(
            abi.encode(
                MATCH_RESULT_TYPEHASH,
                matchId,
                m.player1,
                m.player2,
                winner,
                nonce,
                deadline
            )
        );
        
        
        bytes32 digest = _hashTypedDataV4(structHash);  // EIP-712 magic
        
        // Prevent signature replay
        require(!usedSignatures[digest], "Signature already used");
        usedSignatures[digest] = true;
        
        // Verify signature
        require(
            _verifyRefereeSignature(digest, signature), "Invalid referee signature"
        );
        
        matchNonce[matchId] = nonce;
        _finalizeMatch(matchId, winner);
        
        emit MatchWinnerReported(matchId, winner, nonce);
    }

    function getPlayerWallet(address player) external view returns (
        uint256 depositedBalance,
        uint256 totalDeposited,
        uint256 totalWon,
        uint256 totalLost,
        uint256 totalWagered,
        uint256 wins,
        uint256 losses,
        uint256 totalWithdrawn,
        uint256 totalRefunded,
        uint256 gamesPlayed
        ) {
        MatchWallet storage w = wallets[player];
        return (
            w.depositedBalance,
            w.totalDeposited,
            w.totalWon,
            w.totalLost,
            w.totalWagered,
            w.wins,
            w.losses,
            w.totalWithdrawn,
            w.totalRefunded,
            w.gamesPlayed
        );
    }

    function getMatchStats(uint256 matchId) external view returns (
        address player1,
        address player2,
        address currentPlayer,
        uint256 stakeAmount,
        uint256 startTime,
        address winner,
        bool finished,
        bool rematchPlayer1,
        bool rematchPlayer2,
        bool player1ApprovesRefund,
        bool player2ApprovesRefund,
        uint256 rematchTimeRequested,
        MatchState state
        ) {
        Match storage m = matches[matchId];
        return (
            m.player1,
            m.player2,
            m.currentPlayer,
            m.stakeAmount,
            m.startTime,
            m.winner,
            m.finished,
            m.rematchPlayer1,
            m.rematchPlayer2,
            m.player1ApprovesRefund,
            m.player2ApprovesRefund,
            m.rematchTimeRequested,
            m.state
        );
    }

    function getQueueLength(uint256 stakeAmount) public view returns (uint256) {
        require(queueIndex[stakeAmount] <= matchQueue[stakeAmount].length, "Invalid queue state");
        return matchQueue[stakeAmount].length - queueIndex[stakeAmount];
    }

    function getPlayerBalance(address player) external view returns (uint256) {
    return  wallets[player].depositedBalance;
    }

    function getQueuePlayers(uint256 stakeAmount) external view returns (address[] memory) {
    return matchQueue[stakeAmount];
    }

    function getQueueArrayLength(uint256 stakeAmount) external view returns (uint256) {
    return matchQueue[stakeAmount].length;
    }

    // Test helper - exposes internal EIP712 hash
    function hashTypedDataV4(bytes32 structHash) external view returns (bytes32) {
    return _hashTypedDataV4(structHash);
    }

}